#!/usr/bin/env bash
#
# prefetch.sh  ——  PHASE 1, run ONLINE on the prep host.
#
# Produces the artifacts you copy to the offline host:
#   * $IMAGES_BUNDLE  — docker save of the toolchain + runtime-base images
#   * $SRC_BUNDLE     — the source tree (source + vendor/ + cabal.project + dist-newstyle)
#
# Usage:   ./prefetch.sh
#
set -euo pipefail
cd "$(dirname "$0")"

# shellcheck disable=SC1091
[ -f .env ] && . ./.env

SIMPLEX_CHAT_REF="${SIMPLEX_CHAT_REF:-stable}"
SIMPLEX_CHAT_REPO="${SIMPLEX_CHAT_REPO:-https://github.com/simplex-chat/simplex-chat.git}"
HASKELL_IMAGE="${HASKELL_IMAGE:-haskell:9.6.7-bullseye}"
SEED_IMAGE="${SEED_IMAGE:-simplex-offline-builder:seed}"
TOOLCHAIN_IMAGE="${TOOLCHAIN_IMAGE:-simplex-offline-toolchain:latest}"
RUNTIME_BASE_IMAGE="${RUNTIME_BASE_IMAGE:-simplex-offline-runtime-base:latest}"
IMAGES_BUNDLE="${IMAGES_BUNDLE:-simplex-offline-images.tar.gz}"
SRC_BUNDLE="${SRC_BUNDLE:-simplex-chat-offline-src.tar.gz}"

echo "==> [1/5] Building runtime base image: ${RUNTIME_BASE_IMAGE}"
docker build -f Dockerfile.runtime-base -t "${RUNTIME_BASE_IMAGE}" .

echo "==> [2/5] Building seed (internal cache-warming builder): ${SEED_IMAGE}"
echo "          simplex-chat ref: ${SIMPLEX_CHAT_REF}"
echo "          (clones + vendors + compiles everything; first run 30-60 min, several GB)"
docker build \
    -f Dockerfile.seed \
    --build-arg "HASKELL_IMAGE=${HASKELL_IMAGE}" \
    --build-arg "SIMPLEX_CHAT_REF=${SIMPLEX_CHAT_REF}" \
    --build-arg "SIMPLEX_CHAT_REPO=${SIMPLEX_CHAT_REPO}" \
    -t "${SEED_IMAGE}" \
    .

echo "==> [3/5] Building shippable toolchain image (toolchain + cache, no source): ${TOOLCHAIN_IMAGE}"
docker build \
    -f Dockerfile.toolchain \
    --build-arg "HASKELL_IMAGE=${HASKELL_IMAGE}" \
    --build-arg "SEED_IMAGE=${SEED_IMAGE}" \
    -t "${TOOLCHAIN_IMAGE}" \
    .

echo "==> [4/5] Exporting source repo bundle -> ${SRC_BUNDLE}"
echo "          (simplex-chat + sibling simplexmq, with vendor/, cabal.project, dist-newstyle; upstream .git dropped)"
# Stream both /src/simplex-chat and the sibling /src/simplexmq out of the seed image.
# Drop the large upstream git history (setup-offline.sh re-inits clean repos) but KEEP
# dist-newstyle (under simplex-chat) so the first offline build is incremental.
docker run --rm "${SEED_IMAGE}" \
    tar -C /src --exclude='simplex-chat/.git' --exclude='simplexmq/.git' \
        -cf - simplex-chat simplexmq \
    | gzip > "${SRC_BUNDLE}"

echo "==> [5/5] Saving images -> ${IMAGES_BUNDLE}"
docker save "${TOOLCHAIN_IMAGE}" "${RUNTIME_BASE_IMAGE}" | gzip > "${IMAGES_BUNDLE}"

echo
echo "Done. Copy these to the offline host:"
echo "    ${IMAGES_BUNDLE}    ($(du -h "${IMAGES_BUNDLE}" | cut -f1))"
echo "    ${SRC_BUNDLE}       ($(du -h "${SRC_BUNDLE}" | cut -f1))"
echo "    .env  setup-offline.sh  build.sh  Dockerfile.runtime"
echo
echo "Then on the offline host: ./setup-offline.sh  &&  ./build.sh"
