#!/usr/bin/env bash
# split-image.sh — compress, split, and checksum an .img for GitHub Releases
# Output: build/release/<basename>.img.zst.NN.part + MANIFEST.sha256
#
# Usage:
#   ./scripts/split-image.sh build/iotbox-filamind-2026.05.10.img
#
set -euo pipefail

INPUT="${1:?usage: $0 <image.img>}"
[[ -f "${INPUT}" ]] || { echo "not found: ${INPUT}" >&2; exit 1; }
# Resolve to an absolute path because we cd into the output dir below.
INPUT="$(readlink -f "${INPUT}")"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${REPO_ROOT}/build/release"
BASE="$(basename "${INPUT}" .img)"
CHUNK_SIZE="${CHUNK_SIZE:-1900M}"
ZSTD_LEVEL="${ZSTD_LEVEL:-19}"

log() { printf '\033[1;34m▶\033[0m %s\n' "$*"; }

mkdir -p "${OUT_DIR}"
cd "${OUT_DIR}"

log "Hashing original image"
ORIG_SHA=$(sha256sum "${INPUT}" | awk '{print $1}')

log "Compressing with zstd -${ZSTD_LEVEL} --long=27 (this may take a while)"
zstd -T0 -"${ZSTD_LEVEL}" --long=27 -f "${INPUT}" -o "${BASE}.img.zst"

log "Splitting into ${CHUNK_SIZE} chunks"
rm -f "${BASE}.img.zst."*.part
split -b "${CHUNK_SIZE}" -d -a 2 \
      --additional-suffix=.part \
      "${BASE}.img.zst" "${BASE}.img.zst."

log "Generating MANIFEST.sha256"
{
    printf '# filamind-iotbox release manifest\n'
    printf '# generated %s\n' "$(date -Iseconds)"
    printf '# original image\n'
    printf '%s  %s\n' "${ORIG_SHA}" "${BASE}.img"
    printf '# compressed image (after cat *.part)\n'
    sha256sum "${BASE}.img.zst"
    printf '# split parts (verify before joining)\n'
    sha256sum "${BASE}.img.zst."*.part
} > MANIFEST.sha256

log "Removing intermediate compressed file (keep only parts + manifest)"
rm -f "${BASE}.img.zst"

log "Done. Release artifacts:"
ls -lh "${OUT_DIR}"
echo
log "Total parts size:"
du -ch "${OUT_DIR}"/*.part | tail -1
