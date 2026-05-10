#!/usr/bin/env bash
# download-image.sh — fetch a filamind-iotbox release, verify, and reassemble
#
# Usage:
#   ./download-image.sh                # latest release
#   ./download-image.sh v1.2.0         # specific tag
#   ./download-image.sh latest ./out   # custom output dir
#
# Requirements:
#   gh (GitHub CLI) authenticated, OR curl + jq for unauthenticated access.
#   zstd
#
set -euo pipefail

REPO="${REPO:-filamind-app/filamind-iotbox}"
VERSION="${1:-latest}"
OUT_DIR="${2:-./iotbox-image}"

log()  { printf '\033[1;34m▶\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

command -v zstd >/dev/null || fail "missing: zstd (apt install zstd / brew install zstd)"

mkdir -p "${OUT_DIR}"
cd "${OUT_DIR}"

if command -v gh >/dev/null 2>&1; then
    log "Fetching ${VERSION} from ${REPO} via gh CLI"
    if [[ "${VERSION}" == "latest" ]]; then
        gh release download --repo "${REPO}" \
           --pattern '*.part' --pattern 'MANIFEST.sha256' --clobber
    else
        gh release download "${VERSION}" --repo "${REPO}" \
           --pattern '*.part' --pattern 'MANIFEST.sha256' --clobber
    fi
else
    command -v curl >/dev/null || fail "need either gh or curl"
    command -v jq   >/dev/null || fail "need either gh or curl + jq"
    log "gh not found — falling back to curl"
    if [[ "${VERSION}" == "latest" ]]; then
        API="https://api.github.com/repos/${REPO}/releases/latest"
    else
        API="https://api.github.com/repos/${REPO}/releases/tags/${VERSION}"
    fi
    URLS=$(curl -fsSL "${API}" | jq -r '.assets[] | select(.name | test("\\.part$|MANIFEST.sha256$")) | .browser_download_url')
    [[ -n "${URLS}" ]] || fail "no matching assets found for ${VERSION}"
    while IFS= read -r u; do
        log "  ↓ $(basename "${u}")"
        curl -fsSL -o "$(basename "${u}")" "${u}"
    done <<<"${URLS}"
fi

[[ -f MANIFEST.sha256 ]] || fail "MANIFEST.sha256 missing from release"

log "Verifying parts against MANIFEST.sha256"
grep '\.part$' MANIFEST.sha256 | sha256sum -c -

PARTS=( *.part )
[[ ${#PARTS[@]} -gt 0 ]] || fail "no .part files downloaded"
BASE="${PARTS[0]%.*.part}"

log "Concatenating ${#PARTS[@]} part(s) → ${BASE}"
cat "${PARTS[@]}" > "${BASE}"

log "Verifying compressed image"
grep "${BASE}\$" MANIFEST.sha256 | sha256sum -c -

log "Decompressing"
FINAL="${BASE%.zst}"
zstd -d --long=27 -f "${BASE}" -o "${FINAL}"

log "Verifying final .img"
grep "${FINAL}\$" MANIFEST.sha256 | sha256sum -c -

log "Cleaning up intermediate artifacts"
rm -f "${PARTS[@]}" "${BASE}"

log "Done."
ls -lh "${FINAL}"
echo
log "Flash with:    sudo dd if=${FINAL} of=/dev/sdX bs=4M status=progress conv=fsync"
log "or use:        Raspberry Pi Imager → 'Use custom' → ${FINAL}"
