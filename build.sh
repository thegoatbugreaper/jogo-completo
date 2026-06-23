#!/usr/bin/env bash
#
# build.sh  ——  PHASE 2, run OFFLINE on the target host (repeatable).
#
# Compiles the source repo ($SRC_DIR) inside the toolchain container with the network
# disabled, extracts the binaries, and packages them into the slim runtime image.
# Edit files in $SRC_DIR/ with your own tools, then re-run this — rebuilds are
# incremental (only changed modules recompile), still fully offline.
#
# Usage:   ./build.sh [cabal-target ...]
#          (default targets: simplex-chat, smp-server, xftp-server)
#
set -euo pipefail
cd "$(dirname "$0")"

# shellcheck disable=SC1091
[ -f .env ] && . ./.env

TOOLCHAIN_IMAGE="${TOOLCHAIN_IMAGE:-simplex-offline-toolchain:latest}"
OUTPUT_IMAGE="${OUTPUT_IMAGE:-simplex-offline:latest}"
SRC_DIR="${SRC_DIR:-simplex-chat}"
SIMPLEXMQ_DIR="${SIMPLEXMQ_DIR:-simplexmq}"
CONTAINER_SRC="${CONTAINER_SRC:-/src/simplex-chat}"
CONTAINER_SIMPLEXMQ="${CONTAINER_SIMPLEXMQ:-/src/simplexmq}"

# The three deliverables — always packaged into the runtime image so it stays complete.
DELIVERABLES=(simplex-chat:exe:simplex-chat simplexmq:exe:smp-server simplexmq:exe:xftp-server)

# Targets to (re)compile. Passing specific targets only narrows what is recompiled for
# a faster edit loop; the packaged image still contains all three deliverables (the
# others are taken from cache, already built in dist-newstyle).
TARGETS=("$@")
if [ ${#TARGETS[@]} -eq 0 ]; then
    TARGETS=("${DELIVERABLES[@]}")
fi

[ -d "${SRC_DIR}" ]      || { echo "ERROR: ${SRC_DIR}/ not found — run ./setup-offline.sh first"; exit 1; }
[ -d "${SIMPLEXMQ_DIR}" ] || { echo "ERROR: ${SIMPLEXMQ_DIR}/ not found — run ./setup-offline.sh first"; exit 1; }

run_in_toolchain() {
    # Mount BOTH repos at their fixed container paths so the sibling relationship
    # (simplex-chat <-> ../simplexmq) and the shipped dist-newstyle (created at these
    # paths online) stay valid. --network=none guarantees no internet.
    docker run --rm --network=none \
        -v "$PWD/${SRC_DIR}:${CONTAINER_SRC}" \
        -v "$PWD/${SIMPLEXMQ_DIR}:${CONTAINER_SIMPLEXMQ}" \
        -w "${CONTAINER_SRC}" \
        "${TOOLCHAIN_IMAGE}" "$@"
}

echo "==> [1/3] Building offline (no network): ${TARGETS[*]}"
run_in_toolchain cabal build --offline "${TARGETS[@]}"

echo "==> [2/3] Extracting binaries -> ./bin"
rm -rf bin && mkdir -p bin
# Mount both repos + ./bin at /out and copy ALL deliverable binaries (not just
# recompiled targets), so the packaged image is always complete.
docker run --rm --network=none \
    -v "$PWD/${SRC_DIR}:${CONTAINER_SRC}" \
    -v "$PWD/${SIMPLEXMQ_DIR}:${CONTAINER_SIMPLEXMQ}" \
    -v "$PWD/bin:/out" \
    -w "${CONTAINER_SRC}" \
    "${TOOLCHAIN_IMAGE}" \
    sh -ec 'for t in "$@"; do cp "$(cabal list-bin --offline "$t")" /out/; done' _ "${DELIVERABLES[@]}"
ls -l bin/

echo "==> [3/3] Packaging runtime image (no network): ${OUTPUT_IMAGE}"
docker build --network=none -f Dockerfile.runtime -t "${OUTPUT_IMAGE}" .

echo
echo "==> Smoke test"
docker run --rm --entrypoint simplex-chat "${OUTPUT_IMAGE}" -v        || true
docker run --rm --entrypoint smp-server   "${OUTPUT_IMAGE}" --version || true
docker run --rm --entrypoint xftp-server  "${OUTPUT_IMAGE}" --version || true

echo
echo "Done. Built offline image: ${OUTPUT_IMAGE}"
