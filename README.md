# filamind-iotbox

Patched **Odoo IoT Box** image that lets you connect to a self-hosted Odoo server
**directly from the settings page** — without going through `iot-proxy.odoo.com`.

> Based on the official Odoo IoT Box (Raspbian 13 / pi-gen 2025-10-01 / Odoo `saas-19.1`).
> All modifications are released under LGPL-3 to match upstream.

---

## What this changes

| # | File | Change |
|---|------|--------|
| 1 | `addons/iot_drivers/tools/helpers.py` | `save_conf_server` accepts a bare URL |
| 2 | `addons/iot_drivers/controllers/homepage.py` | `/iot_drivers/connect_to_server` accepts `url` + optional `code` (pairs with [filamind-iot](https://github.com/filamind-app/filamind-iot)) |
| 3 | `addons/iot_drivers/static/src/app/components/dialog/ServerDialog.js` | Settings dialog gains a **Server URL** tab with URL + pairing-code fields |
| 4 | `/etc/rc.local` | Disables the upstream auto-update that would wipe the patches |

The original token-based pairing flow is preserved for compatibility.

### Pairing flow with [filamind-iot](https://github.com/filamind-app/filamind-iot)

1. Install the **Filamind IoT** addon on your Odoo server.
2. Go to **IoT → Connect IoT Box** in Odoo, generate a pairing code (8-char hex, valid 15 min by default).
3. On the IoT Box settings page (this image), open **Configure** → **Server URL** tab.
4. Paste the Odoo URL and the pairing code. Submit.
5. The box POSTs to `{url}/filamind_iot/pair` with its identifier and gets a permanent token back.
6. Box restarts and starts heartbeating to your Odoo.

Leave the code field empty if you prefer to pair from the Odoo side using box-token mode.

---

## Repo layout

```
filamind-iotbox/
├── patches/                      # source of truth — unified diffs
│   ├── 001-helpers-optional-args.patch
│   ├── 002-homepage-add-url-endpoint.patch
│   ├── 003-server-dialog-url-input.patch
│   └── 004-rc-local-disable-autoupdate.patch
├── src/                          # full modified files (replaced wholesale)
│   ├── etc/rc.local
│   └── iot_drivers/static/src/app/components/dialog/ServerDialog.js
├── scripts/
│   ├── build-image.sh            # apply patches to upstream .img
│   ├── split-image.sh            # compress + split + checksum for releases
│   ├── download-image.sh         # auto-download + verify + reassemble
│   ├── flash-patches.sh          # apply patches over SSH to a live IoT Box
│   └── verify-image.sh           # post-build sanity checks
├── .github/workflows/
│   ├── ci.yml                    # patch syntax, ruff, shellcheck, dry-run apply
│   └── release.yml               # builds image on tag, splits, publishes release
├── docs/
│   ├── INSTALL.md
│   └── ARCHITECTURE.md
├── CHANGELOG.md
├── LICENSE
└── README.md
```

---

## Quick start — for end users

### Get the image

#### Linux / macOS / WSL

```bash
curl -fsSL https://github.com/filamind-app/filamind-iotbox/releases/latest/download/download-image.sh \
  | bash -s -- latest ./iotbox-image
```

#### Windows (PowerShell — no WSL needed)

```powershell
# One-shot: fetch + run the PowerShell script
$tag  = (gh release view --repo filamind-app/filamind-iotbox --json tagName -q .tagName)
$base = "https://github.com/filamind-app/filamind-iotbox/releases/download/$tag"
irm "$base/download-image.ps1" -OutFile download-image.ps1
irm "$base/download-image.cmd" -OutFile download-image.cmd
.\download-image.cmd $tag
```

Or just **double-click `download-image.cmd`** after putting both files in a folder.

Prerequisites on Windows:
- `winget install --id GitHub.cli`
- `winget install --id Facebook.Zstandard`

All scripts download every release part, verify SHA-256 at each stage, and write
a single `iotbox-filamind-*.img` ready for flashing. See [docs/INSTALL.md](docs/INSTALL.md).

### Flash to SD card

```bash
sudo dd if=iotbox-image/iotbox-filamind-*.img of=/dev/sdX bs=4M status=progress conv=fsync
```

Or use **Raspberry Pi Imager** → *Use custom image*.

### Configure on first boot

1. Power up the Pi. Connect via Ethernet or join its `IoTBox-*` Wi-Fi.
2. Browse to `http://10.11.12.1:8069` (AP mode) or the IP shown on screen.
3. Click **Configure** → **Server URL** tab → paste your Odoo URL → **Connect**.

That's it. No `iot-proxy.odoo.com` round-trip required.

---

## Quick start — for contributors

### Apply the patches to a running IoT Box (no re-flash)

```bash
./scripts/flash-patches.sh pi@<iot-box-ip>
```

### Build a fresh image locally (Linux / WSL2)

```bash
sudo apt-get install -y zstd parted unzip
sudo ./scripts/build-image.sh                      # auto-downloads upstream
sudo ./scripts/verify-image.sh build/iotbox-filamind-*.img
./scripts/split-image.sh build/iotbox-filamind-*.img
```

### Cut a release

Push a tag — CI builds the image, splits it, and publishes the release automatically.

```bash
git tag v1.0.0
git push origin v1.0.0
```

---

## Error detection

Every push runs the full CI matrix:

- **Patch syntax** — every `.patch` is checked for valid unified-diff headers.
- **Ruff** — Python files pass static analysis.
- **`node --check`** — `ServerDialog.js` is parseable.
- **Apply-against-upstream** — patches are dry-run-applied to a fresh `saas-19.1` checkout. *Breaks loudly the moment Odoo upstream changes anything we depend on.*
- **shellcheck** — every script in `scripts/` is linted.
- **Manifest sanity** — required files must exist.

The release workflow additionally runs `verify-image.sh` against the built `.img`,
re-checking that all four patches are reflected before the release is cut.

---

## Security note

The IoT Box's communication with the configured Odoo server is authenticated by
`token` + `db_uuid` + `enterprise_code`. Setting only the URL via the new tab
**does not bypass authentication** — it just stores the URL. The target Odoo
server must still issue valid credentials (via the IoT app on that server) for
the box to actually exchange data.

---

## License

LGPL-3.0-or-later — same as upstream Odoo.
See [LICENSE](LICENSE) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
