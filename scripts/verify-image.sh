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

WORK="$(mktemp -d)"

log()  { printf '\033[1;34m▶\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
    umount "${WORK}/root" 2>/dev/null || true
    if [[ -n "${LOOP:-}" ]]; then
        losetup -d "${LOOP}" 2>/dev/null || true
    fi
    rm -rf "${WORK}"
}
trap cleanup EXIT

log "Verifying partition table"
parts=$(fdisk -l "${IMG}")
if ! grep -q 'W95 FAT32' <<<"${parts}"; then
    fail "missing FAT32 boot partition"
fi
if ! grep -q 'Linux' <<<"${parts}"; then
    fail "missing Linux root partition"
fi
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

# Patch 2 — homepage.py: connect_to_odoo_server should accept url + code,
# and the body should reference /filamind_iot/pair for the new pairing flow.
homepage="${ROOT}/home/pi/odoo/addons/iot_drivers/controllers/homepage.py"
grep -q 'connect_to_odoo_server(self, token=None, url=None, code=None)' "${homepage}" \
    || fail "patch 2 not applied (homepage.py: signature)"
grep -q '/filamind_iot/pair' "${homepage}" \
    || fail "patch 2 not applied (homepage.py: pairing endpoint missing)"
ok "Patch 2 (homepage.py) applied"

# Patch 3 — ServerDialog.js: tabbed UI with URL+code form fields.
dialog="${ROOT}/home/pi/odoo/addons/iot_drivers/static/src/app/components/dialog/ServerDialog.js"
grep -q "state.mode === 'url'" "${dialog}" \
    || fail "patch 3 not applied (ServerDialog.js: tabs)"
grep -q 'form.code' "${dialog}" \
    || fail "patch 3 not applied (ServerDialog.js: pairing-code field)"
ok "Patch 3 (ServerDialog.js) applied"

# Patch 4 — rc.local: autoupdate block should be commented
if grep -E '^[[:space:]]*sudo -u odoo git fetch' "${ROOT}/etc/rc.local" | grep -qv '^[[:space:]]*#'; then
    fail "patch 4 not applied (rc.local still auto-updates)"
fi
ok "Patch 4 (rc.local) applied"

# Version stamp
if [[ -f "${ROOT}/etc/filamind/version" ]]; then
    log "Version stamp:"
    sed 's/^/  /' "${ROOT}/etc/filamind/version"
fi

ok "All checks passed."
