#!/usr/bin/env bash
# verify-image.sh — sanity-check a built filamind-iotbox .img
# Confirms partitions, OS identity, and that all four patches are reflected.
#
# Usage:
#   sudo ./scripts/verify-image.sh build/iotbox-filamind-2026.05.10.img
#
set -euo pipefail

IMG="${1:?usage: sudo $0 <image.img>}"
[[ -f "${IMG}" ]] || { echo "not found: ${IMG}" >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"

log()  { printf '\033[1;34m▶\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
    umount "${WORK}/root" 2>/dev/null || true
    [[ -n "${LOOP:-}" ]] && losetup -d "${LOOP}" 2>/dev/null || true
    rm -rf "${WORK}"
}
trap cleanup EXIT

log "Verifying partition table"
fdisk -l "${IMG}" | grep -q 'W95 FAT32' || fail "missing FAT32 boot partition"
fdisk -l "${IMG}" | grep -q 'Linux'     || fail "missing Linux root partition"
ok "Partitions OK"

log "Mounting root partition read-only"
LOOP=$(losetup -fP --show "${IMG}")
mkdir -p "${WORK}/root"
mount -o ro "${LOOP}p2" "${WORK}/root"

ROOT="${WORK}/root"

log "Checking OS identity"
grep -q 'Raspbian' "${ROOT}/etc/os-release" || fail "not Raspbian"
grep -q '^iotbox$' "${ROOT}/etc/hostname"   || fail "wrong hostname"
ok "Raspbian IoT Box confirmed"

log "Checking that patches are reflected"

# Patch 1 — helpers.py: save_conf_server should have default args
grep -q "def save_conf_server(url, token=''" \
    "${ROOT}/home/pi/odoo/addons/iot_drivers/tools/helpers.py" \
    || fail "patch 1 not applied (helpers.py)"
ok "Patch 1 (helpers.py) applied"

# Patch 2 — homepage.py: connect_to_odoo_server should accept url=None
grep -q 'connect_to_odoo_server(self, token=None, url=None)' \
    "${ROOT}/home/pi/odoo/addons/iot_drivers/controllers/homepage.py" \
    || fail "patch 2 not applied (homepage.py)"
ok "Patch 2 (homepage.py) applied"

# Patch 3 — ServerDialog.js: should reference state.mode === 'url'
grep -q "state.mode === 'url'" \
    "${ROOT}/home/pi/odoo/addons/iot_drivers/static/src/app/components/dialog/ServerDialog.js" \
    || fail "patch 3 not applied (ServerDialog.js)"
ok "Patch 3 (ServerDialog.js) applied"

# Patch 4 — rc.local: autoupdate block should be commented
if grep -E '^[[:space:]]*sudo -u odoo git fetch' "${ROOT}/etc/rc.local" | grep -qv '^[[:space:]]*#'; then
    fail "patch 4 not applied (rc.local still auto-updates)"
fi
ok "Patch 4 (rc.local) applied"

# Version stamp
if [[ -f "${ROOT}/etc/filamind/version" ]]; then
    log "Version stamp:"
    cat "${ROOT}/etc/filamind/version" | sed 's/^/  /'
fi

ok "All checks passed."
