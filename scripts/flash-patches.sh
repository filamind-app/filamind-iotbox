#!/usr/bin/env bash
# flash-patches.sh — apply filamind patches to an already-running IoT Box via SSH
# Use this when re-flashing the SD card is not practical.
#
# Usage:
#   ./scripts/flash-patches.sh pi@<iot-box-ip>
#
set -euo pipefail

TARGET="${1:?usage: $0 user@host}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { printf '\033[1;34m▶\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

command -v ssh >/dev/null || fail "missing: ssh"
command -v scp >/dev/null || fail "missing: scp"

log "Testing SSH to ${TARGET}"
ssh -o BatchMode=no -o ConnectTimeout=5 "${TARGET}" 'echo ok' >/dev/null \
    || fail "cannot SSH to ${TARGET}"

log "Remounting root rw on target"
ssh "${TARGET}" 'sudo mount -o remount,rw /'

log "Uploading patches and modified files"
scp -q "${REPO_ROOT}"/patches/001-helpers-optional-args.patch "${TARGET}:/tmp/"
scp -q "${REPO_ROOT}"/patches/002-homepage-add-url-endpoint.patch "${TARGET}:/tmp/"
scp -q "${REPO_ROOT}"/src/iot_drivers/static/src/app/components/dialog/ServerDialog.js "${TARGET}:/tmp/"
scp -q "${REPO_ROOT}"/src/etc/rc.local "${TARGET}:/tmp/rc.local.filamind"

log "Backing up originals (keeps a .filamind-backup copy)"
ssh "${TARGET}" 'bash -se' <<'REMOTE'
set -euo pipefail
ODOO=/home/pi/odoo

backup() {
    local f="$1"
    [[ -f "${f}.filamind-backup" ]] || sudo cp -p "$f" "$f.filamind-backup"
}
backup "${ODOO}/addons/iot_drivers/tools/helpers.py"
backup "${ODOO}/addons/iot_drivers/controllers/homepage.py"
backup "${ODOO}/addons/iot_drivers/static/src/app/components/dialog/ServerDialog.js"
backup /etc/rc.local

echo OK
REMOTE

log "Applying patches and replacing files on target"
ssh "${TARGET}" 'bash -se' <<'REMOTE'
set -euo pipefail
ODOO=/home/pi/odoo

sudo patch -p1 -d "${ODOO}" < /tmp/001-helpers-optional-args.patch
sudo patch -p1 -d "${ODOO}" < /tmp/002-homepage-add-url-endpoint.patch

sudo install -m 0644 /tmp/ServerDialog.js \
    "${ODOO}/addons/iot_drivers/static/src/app/components/dialog/ServerDialog.js"

sudo install -m 0755 /tmp/rc.local.filamind /etc/rc.local

# Cleanup
rm -f /tmp/001-helpers-optional-args.patch \
      /tmp/002-homepage-add-url-endpoint.patch \
      /tmp/ServerDialog.js \
      /tmp/rc.local.filamind

# Restart Odoo to pick up changes
sudo systemctl restart odoo
echo "OK — Odoo restarting"
REMOTE

log "Done. IoT Box should be reachable in 10–30 seconds with the new UI."
log "To roll back: restore .filamind-backup files and 'sudo systemctl restart odoo'"
