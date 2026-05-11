#!/usr/bin/env bash
# build-image.sh — apply filamind patches to an upstream Odoo IoT Box .img
# Output: build/iotbox-filamind-<version>.img
#
# Requirements (Linux / WSL2):
#   sudo apt-get install -y zstd parted kpartx mount
#
# Usage:
#   ./scripts/build-image.sh /path/to/upstream-iotbox.img
#   ./scripts/build-image.sh                       # auto-download latest from nightly.odoo.com
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
WORK_DIR="${BUILD_DIR}/work"
VERSION="${VERSION:-$(date +%Y.%m.%d)}"
INPUT_IMG="${1:-}"

log()  { printf '\033[1;34m▶\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "Run as root: sudo $0 $*"

command -v zstd     >/dev/null || fail "missing: zstd"
command -v parted   >/dev/null || fail "missing: parted"
command -v losetup  >/dev/null || fail "missing: losetup"

mkdir -p "${BUILD_DIR}" "${WORK_DIR}"

if [[ -z "${INPUT_IMG}" ]]; then
    UPSTREAM_URL="https://nightly.odoo.com/master/iotbox/"
    log "No image given — checking ${UPSTREAM_URL}"
    LATEST=$(curl -fsSL "${UPSTREAM_URL}" | grep -oE 'iotbox_[0-9.]+\.img\.zip' | sort -u | tail -1)
    [[ -n "${LATEST}" ]] || fail "Could not locate latest upstream image"
    INPUT_IMG="${BUILD_DIR}/${LATEST%.zip}"
    if [[ ! -f "${INPUT_IMG}" ]]; then
        log "Downloading ${LATEST}"
        curl -fsSL "${UPSTREAM_URL}${LATEST}" -o "${BUILD_DIR}/${LATEST}"
        unzip -d "${BUILD_DIR}" "${BUILD_DIR}/${LATEST}"
    fi
fi

[[ -f "${INPUT_IMG}" ]] || fail "Image not found: ${INPUT_IMG}"
OUTPUT_IMG="${BUILD_DIR}/iotbox-filamind-${VERSION}.img"

log "Copying upstream image → ${OUTPUT_IMG}"
cp --reflink=auto "${INPUT_IMG}" "${OUTPUT_IMG}"

log "Attaching loop device (with partition scan)"
LOOP=$(losetup -fP --show "${OUTPUT_IMG}")
log "  loop = ${LOOP}"

cleanup() {
    log "Cleanup: unmounting and detaching"
    umount "${WORK_DIR}/root" 2>/dev/null || true
    umount "${WORK_DIR}/boot" 2>/dev/null || true
    losetup -d "${LOOP}" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "${WORK_DIR}/boot" "${WORK_DIR}/root"
mount "${LOOP}p1" "${WORK_DIR}/boot"
mount "${LOOP}p2" "${WORK_DIR}/root"

ROOT="${WORK_DIR}/root"
ODOO_DIR="${ROOT}/home/pi/odoo"

log "Sanity check: confirming this is an Odoo IoT Box image"
if [[ ! -f "${ROOT}/etc/hostname" ]] || ! grep -q iotbox "${ROOT}/etc/hostname"; then
    fail "Not an Odoo IoT Box image (hostname mismatch)"
fi
if [[ ! -d "${ODOO_DIR}/addons/iot_drivers" ]]; then
    fail "iot_drivers addon not found in image"
fi

log "Applying patch 001 (helpers.py)"
patch -p1 -d "${ODOO_DIR}" < "${REPO_ROOT}/patches/001-helpers-optional-args.patch"

log "Applying patch 002 (homepage.py)"
patch -p1 -d "${ODOO_DIR}" < "${REPO_ROOT}/patches/002-homepage-add-url-endpoint.patch"

log "Replacing ServerDialog.js (full-file replacement)"
install -m 0644 \
    "${REPO_ROOT}/src/iot_drivers/static/src/app/components/dialog/ServerDialog.js" \
    "${ODOO_DIR}/addons/iot_drivers/static/src/app/components/dialog/ServerDialog.js"

log "Installing transport.py (multi-transport selector)"
install -m 0644 \
    "${REPO_ROOT}/src/iot_drivers/tools/transport.py" \
    "${ODOO_DIR}/addons/iot_drivers/tools/transport.py"

log "Applying patch 005 (main.py uses Transport.create)"
patch -p1 -d "${ODOO_DIR}" < "${REPO_ROOT}/patches/005-main-py-transport-selector.patch"

log "Applying patch 006 (homepage.py /iot_drivers/diagnose JSON)"
patch -p1 -d "${ODOO_DIR}" < "${REPO_ROOT}/patches/006-homepage-add-diagnose.patch"

log "Applying patch 007 (homepage.py /iot_drivers/diagnose.html)"
patch -p1 -d "${ODOO_DIR}" < "${REPO_ROOT}/patches/007-homepage-diagnose-html.patch"

log "Applying patch 008 (homepage.py /iot_drivers/proxy_connect + proxy_poll)"
patch -p1 -d "${ODOO_DIR}" < "${REPO_ROOT}/patches/008-homepage-add-proxy-pair.patch"

log "Installing filamind helper scripts into /usr/local/bin"
for helper in filamind-status filamind-make-self-signed-cert filamind-proxy-init; do
    src="${REPO_ROOT}/src/usr/local/bin/${helper}"
    if [[ -f "$src" ]]; then
        install -m 0755 "$src" "${ROOT}/usr/local/bin/${helper}"
        log "  installed ${helper}"
    fi
done

log "Replacing /etc/rc.local"
install -m 0755 "${REPO_ROOT}/src/etc/rc.local" "${ROOT}/etc/rc.local"

log "Installing filamind vendor drivers (Six, Worldline, Adam, EG fiscal)"
mkdir -p "${ODOO_DIR}/addons/iot_drivers/drivers"
driver_count=0
for d in "${REPO_ROOT}"/src/iot_drivers/drivers/filamind_*.py; do
    [[ -f "$d" ]] || continue
    install -m 0644 "$d" \
        "${ODOO_DIR}/addons/iot_drivers/drivers/$(basename "$d")"
    driver_count=$((driver_count + 1))
done
log "  installed ${driver_count} vendor drivers"

log "Recording filamind version stamp"
mkdir -p "${ROOT}/etc/filamind"
patch_count=$(find "${REPO_ROOT}/patches/" -maxdepth 1 -name '*.patch' -type f | wc -l)
cat > "${ROOT}/etc/filamind/version" <<EOF
filamind-iotbox ${VERSION}
built $(date -Iseconds)
patches ${patch_count}
vendor_drivers ${driver_count}
EOF

log "Syncing filesystem"
sync

log "Done. Output: ${OUTPUT_IMG}"
ls -lh "${OUTPUT_IMG}"
