#!/usr/bin/env bash
#
# setup-offline.sh  ——  PHASE 2, run ONCE on the offline host.
#
# Loads the toolchain + runtime-base images and extracts the source bundle into a
# normal git repo you can edit ($SRC_DIR).
#
# Usage:   ./setup-offline.sh
#
set -euo pipefail
cd "$(dirname "$0")"

# shellcheck disable=SC1091
[ -f .env ] && . ./.env

TOOLCHAIN_IMAGE="${TOOLCHAIN_IMAGE:-simplex-offline-toolchain:latest}"
IMAGES_BUNDLE="${IMAGES_BUNDLE:-simplex-offline-images.tar.gz}"
SRC_BUNDLE="${SRC_BUNDLE:-simplex-chat-offline-src.tar.gz}"
SRC_DIR="${SRC_DIR:-simplex-chat}"
SIMPLEXMQ_DIR="${SIMPLEXMQ_DIR:-simplexmq}"

# 1. Load images (skip if already present)
if ! docker image inspect "${TOOLCHAIN_IMAGE}" >/dev/null 2>&1; then
    echo "==> Loading images from ${IMAGES_BUNDLE}"
    [ -f "${IMAGES_BUNDLE}" ] || { echo "ERROR: ${IMAGES_BUNDLE} not found"; exit 1; }
    gunzip -c "${IMAGES_BUNDLE}" | docker load
else
    echo "==> ${TOOLCHAIN_IMAGE} already loaded"
fi

# 2. Extract the source repos (simplex-chat + sibling simplexmq)
if [ -d "${SRC_DIR}" ] || [ -d "${SIMPLEXMQ_DIR}" ]; then
    echo "==> ${SRC_DIR}/ or ${SIMPLEXMQ_DIR}/ already exists — leaving them untouched"
else
    echo "==> Extracting ${SRC_BUNDLE} -> ${SRC_DIR}/ and ${SIMPLEXMQ_DIR}/"
    [ -f "${SRC_BUNDLE}" ] || { echo "ERROR: ${SRC_BUNDLE} not found"; exit 1; }
    tar -xzf "${SRC_BUNDLE}"   # creates ./${SRC_DIR} and ./${SIMPLEXMQ_DIR}
fi

# 3. Make each a clean, independently-editable git repo. Build artifacts (dist-newstyle,
#    under simplex-chat) stay on disk for fast builds but are not tracked.
init_repo() {
    dir="$1"
    [ -d "${dir}/.git" ] && return 0
    echo "==> Initialising git repo in ${dir}/"
    printf 'dist-newstyle/\n*.o\n*.hi\n' > "${dir}/.gitignore"
    git -C "${dir}" init -q
    git -C "${dir}" add -A
    git -C "${dir}" \
        -c user.email=offline@local -c user.name="offline build" \
        commit -qm "vendored offline source"
}
init_repo "${SRC_DIR}"
init_repo "${SIMPLEXMQ_DIR}"

echo
echo "Ready. Two editable git repos:"
echo "    ${SRC_DIR}/        (simplex-chat; builds against ../${SIMPLEXMQ_DIR})"
echo "    ${SIMPLEXMQ_DIR}/        (simplexmq — edit freely, simplex-chat builds against it)"
echo "Build offline with:  ./build.sh"
