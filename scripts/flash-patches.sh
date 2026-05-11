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
scp -q "${REPO_ROOT}"/patches/007-homepage-diagnose-html.patch "${TARGET}:/tmp/"
scp -q "${REPO_ROOT}"/src/iot_drivers/static/src/app/components/dialog/ServerDialog.js "${TARGET}:/tmp/"
scp -q "${REPO_ROOT}"/src/etc/rc.local "${TARGET}:/tmp/rc.local.filamind"
scp -q "${REPO_ROOT}"/src/usr/local/bin/filamind-status "${TARGET}:/tmp/"
scp -q "${REPO_ROOT}"/src/usr/local/bin/filamind-make-self-signed-cert "${TARGET}:/tmp/"

# Vendor drivers — new files, no patches needed. Copied wholesale to
# /home/pi/odoo/addons/iot_drivers/drivers/ where Odoo's driver
# auto-discovery picks them up at startup.
log "Uploading filamind vendor drivers (Six, Worldline, Adam, EG fiscal)"
ssh "${TARGET}" 'mkdir -p /tmp/filamind_drivers'
for d in "${REPO_ROOT}"/src/iot_drivers/drivers/filamind_*.py; do
    [[ -f "$d" ]] && scp -q "$d" "${TARGET}:/tmp/filamind_drivers/"
done

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
sudo patch -p1 -d "${ODOO}" < /tmp/007-homepage-diagnose-html.patch || true

sudo install -m 0644 /tmp/ServerDialog.js \
    "${ODOO}/addons/iot_drivers/static/src/app/components/dialog/ServerDialog.js"

sudo install -m 0755 /tmp/rc.local.filamind /etc/rc.local

# filamind helper scripts (in PATH)
sudo install -m 0755 /tmp/filamind-status /usr/local/bin/filamind-status
sudo install -m 0755 /tmp/filamind-make-self-signed-cert \
    /usr/local/bin/filamind-make-self-signed-cert
# Generate the cert immediately so the next homepage hit shows
# "self-signed by filamind" rather than "no cert"
sudo /usr/local/bin/filamind-make-self-signed-cert || true

# Vendor drivers
sudo mkdir -p "${ODOO}/addons/iot_drivers/drivers"
if compgen -G "/tmp/filamind_drivers/filamind_*.py" >/dev/null; then
    for f in /tmp/filamind_drivers/filamind_*.py; do
        sudo install -m 0644 "$f" \
            "${ODOO}/addons/iot_drivers/drivers/$(basename "$f")"
    done
fi

# Cleanup
rm -f /tmp/001-helpers-optional-args.patch \
      /tmp/002-homepage-add-url-endpoint.patch \
      /tmp/007-homepage-diagnose-html.patch \
      /tmp/ServerDialog.js \
      /tmp/rc.local.filamind \
      /tmp/filamind-status \
      /tmp/filamind-make-self-signed-cert
rm -rf /tmp/filamind_drivers

# Restart Odoo to pick up changes
sudo systemctl restart odoo
echo "OK — Odoo restarting"
REMOTE

log "Done. IoT Box should be reachable in 10–30 seconds with the new UI."
log "To roll back: restore .filamind-backup files and 'sudo systemctl restart odoo'"
