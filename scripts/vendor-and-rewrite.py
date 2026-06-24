#!/usr/bin/env python3
"""
vendor-and-rewrite.py

Make a cabal project buildable fully offline.

cabal's `source-repository-package` stanzas make cabal `git clone` dependencies at
build time. That is impossible without a network. This script:

  1. Parses every `source-repository-package` stanza from one or more cabal.project
     files (simplex-chat's, and simplexmq's so server-only deps are covered too).
  2. `git clone`s each repo and checks out its pinned tag/commit into <vendor>/<name>.
  3. Rewrites the *primary* cabal.project in place: removes all
     `source-repository-package` stanzas and adds each vendored directory (honouring
     `subdir`) to the `packages:` field as a local path.

After this runs, the only network access cabal needs is the Hackage index + tarballs,
which are warmed separately with `cabal update` / `cabal build`. The offline build
itself touches no git and no network.

Run online (it clones). Idempotent-ish: re-running re-clones missing vendor dirs and
rewrites again from a backup of the original cabal.project (cabal.project.orig).
"""

import argparse
import os
import re
import subprocess
import sys


def log(msg):
    print(f"[vendor] {msg}", flush=True)


def parse_srp_stanzas(text):
    """Return a list of dicts with keys: location, tag, subdir (subdir may be None)."""
    stanzas = []
    lines = text.splitlines()
    i = 0
    n = len(lines)
    while i < n:
        if lines[i].strip() == "source-repository-package":
            i += 1
            fields = {}
            # consume indented (continuation) lines belonging to this stanza
            while i < n and (lines[i].strip() == "" or lines[i][:1] in (" ", "\t")):
                stripped = lines[i].strip()
                if stripped and ":" in stripped and not stripped.startswith("--"):
                    key, val = stripped.split(":", 1)
                    fields[key.strip().lower()] = val.strip()
                i += 1
            if fields.get("location"):
                stanzas.append(
                    {
                        "location": fields["location"],
                        "tag": fields.get("tag"),
                        "subdir": fields.get("subdir"),
                    }
                )
        else:
            i += 1
    return stanzas


def vendor_name(stanza):
    """Stable, collision-free directory name for a stanza.

    Two different repos are both named `wai` (yesodweb/wai -> warp-tls,
    simplex-chat/wai -> warp); disambiguate by appending the subdir."""
    repo = stanza["location"].rstrip("/")
    repo = re.sub(r"\.git$", "", repo).split("/")[-1]
    sub = stanza["subdir"]
    if sub:
        return f"{repo}-{sub.strip('/').replace('/', '-')}"
    return repo


def package_path(stanza, vendor_dirname, vendor_reldir):
    """Relative path (from the cabal.project dir) to the buildable package."""
    base = f"{vendor_reldir}/{vendor_dirname}"
    sub = stanza["subdir"]
    return f"{base}/{sub.strip('/')}" if sub else base


def clone(stanza, dest):
    # Already vendored? (We delete .git after cloning, so test for a non-empty dir.)
    if os.path.isdir(dest) and os.listdir(dest):
        log(f"already present, skipping clone: {dest}")
        return
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    loc, tag = stanza["location"], stanza["tag"]
    log(f"cloning {loc} @ {tag} -> {dest}")
    # Full clone + checkout: works for both branch tags and bare commit hashes
    # (a pinned commit is often not reachable with --depth 1).
    subprocess.run(["git", "clone", "--quiet", loc, dest], check=True)
    if tag:
        subprocess.run(["git", "-C", dest, "checkout", "--quiet", tag], check=True)
    # Initialise submodules — e.g. simplexmq bundles the blst C crypto library as a
    # submodule under cbits/blst; without this the build fails on missing C sources.
    subprocess.run(
        ["git", "-C", dest, "submodule", "update", "--init", "--recursive", "--quiet"],
        check=True,
    )
    # Drop .git dirs to keep the vendored tree (and image) lean; cabal treats these
    # as plain local packages and never needs the history. The checked-out submodule
    # files remain on disk, which is all the build needs.
    subprocess.run(
        ["find", dest, "-name", ".git", "-exec", "rm", "-rf", "{}", "+"], check=False
    )


def rewrite_cabal_project(text, vendor_paths):
    """Remove SRP stanzas; append vendor_paths to the `packages:` field."""
    lines = text.splitlines()
    out = []
    i = 0
    n = len(lines)
    packages_done = False
    while i < n:
        line = lines[i]
        if line.strip() == "source-repository-package":
            # skip the whole stanza (keyword + indented/blank continuation lines)
            i += 1
            while i < n and (lines[i].strip() == "" or lines[i][:1] in (" ", "\t")):
                i += 1
            continue
        # the real `packages:` field sits at column 0 (commented `-- packages:` is left alone)
        if line.startswith("packages:") and not packages_done:
            entries = line.split(":", 1)[1].split()
            i += 1
            while (
                i < n
                and lines[i][:1] in (" ", "\t")
                and lines[i].strip()
                and not lines[i].strip().startswith("--")
            ):
                entries += lines[i].split()
                i += 1
            out.append(f"packages: {entries[0] if entries else '.'}")
            for e in entries[1:]:
                out.append(f"          {e}")
            for vp in vendor_paths:
                out.append(f"          {vp}")
            packages_done = True
            continue
        out.append(line)
        i += 1
    if not packages_done:
        # no packages: field existed (unusual) — synthesise one
        block = ["packages: ."] + [f"          {vp}" for vp in vendor_paths]
        out = block + out
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--project-cabal",
        required=True,
        help="primary cabal.project to rewrite (simplex-chat's)",
    )
    ap.add_argument(
        "--extra-cabal",
        action="append",
        default=[],
        help="additional cabal.project files to harvest SRP stanzas from "
        "(e.g. simplexmq's); not rewritten",
    )
    ap.add_argument(
        "--vendor-dir",
        default="vendor",
        help="vendor directory, relative to the primary cabal.project (default: vendor)",
    )
    ap.add_argument(
        "--sibling",
        action="append",
        default=[],
        help="dependency repo name(s) to place as a SIBLING of the project (../<name>) "
        "and reference as ../<name>, instead of nesting under the vendor dir. Use for "
        "deps you want to manage as their own top-level repo (e.g. simplexmq).",
    )
    args = ap.parse_args()
    siblings = set(args.sibling)

    proj = os.path.abspath(args.project_cabal)
    proj_dir = os.path.dirname(proj)
    vendor_abs = os.path.join(proj_dir, args.vendor_dir)

    # Always harvest + rewrite from a pristine copy of the original cabal.project, so
    # re-running (e.g. a second pass with --extra-cabal) never loses stanzas that were
    # already stripped from the working file on a previous pass.
    orig = proj + ".orig"
    if os.path.exists(orig):
        primary_text = open(orig, encoding="utf-8").read()
    else:
        primary_text = open(proj, encoding="utf-8").read()
        with open(orig, "w", encoding="utf-8") as f:
            f.write(primary_text)

    # Harvest stanzas from the primary + extra cabal.project files, dedup by (location, subdir)
    all_texts = [primary_text]
    for extra in args.extra_cabal:
        if os.path.isfile(extra):
            with open(extra, encoding="utf-8") as f:
                all_texts.append(f.read())
        else:
            log(f"WARNING: extra cabal.project not found, skipping: {extra}")

    seen = set()
    stanzas = []
    for text in all_texts:
        for s in parse_srp_stanzas(text):
            key = (s["location"], s["subdir"])
            if key not in seen:
                seen.add(key)
                stanzas.append(s)

    if not stanzas:
        log("no source-repository-package stanzas found — nothing to vendor")
        return

    log(f"found {len(stanzas)} unique git source-dependencies to vendor")

    vendor_paths = []
    for s in stanzas:
        name = vendor_name(s)
        if name in siblings:
            # Place outside the project as ../<name>, referenced relative to cabal.project.
            dest = os.path.normpath(os.path.join(proj_dir, os.pardir, name))
            rel = f"../{name}"
            if s["subdir"]:
                rel += "/" + s["subdir"].strip("/")
        else:
            dest = os.path.join(vendor_abs, name)
            rel = package_path(s, name, args.vendor_dir)
        clone(s, dest)
        vendor_paths.append(rel)

    new_text = rewrite_cabal_project(primary_text, vendor_paths)
    with open(proj, "w", encoding="utf-8") as f:
        f.write(new_text)

    log(f"rewrote {proj}")
    log("vendored packages added to packages::")
    for vp in vendor_paths:
        log(f"    {vp}")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as e:
        log(f"command failed: {e}")
        sys.exit(1)
