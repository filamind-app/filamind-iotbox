# Changelog

All notable changes to filamind-iotbox are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/) and
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added — Phase 20: Box image polish (filamind-iotbox v0.5.0)

> Two small but high-impact additions for support / debugging.

- **Patch 007** — `GET /iot_drivers/diagnose.html`: a browser-friendly
  view of the existing `/iot_drivers/diagnose` JSON. Same five
  checks, but rendered with red/green badges so an on-site tech
  can see at a glance which transport is broken without parsing
  JSON.
- **`/usr/local/bin/filamind-status`** — one-shot dump of everything
  support needs to know: image version, network, Odoo systemd
  status, configured server URL, USB devices, loaded vendor
  drivers, disk usage, recent log tail, and the diagnose summary.
  Pasteable into a support ticket. Doesn't leak credentials,
  secrets, or PAN data. Runs over SSH:
  `ssh pi@<box-ip> filamind-status`.
- `verify-image.sh` extended to assert patch 007, the four vendor
  drivers, and the `filamind-status` helper all shipped.

### Added — Phase 18: Vendor drivers on the box (filamind-iotbox v0.4.0)

> The server-side data layers for Six / Worldline / Adam / EG fiscal
> were already in `filamind-iot` v1.0.0; this release ships the
> matching driver code that actually talks to the hardware on the
> box.

- New directory `src/iot_drivers/drivers/` with four LGPL-3 driver
  files; the build script copies them into
  `/home/pi/odoo/addons/iot_drivers/drivers/` where Odoo's driver
  auto-discovery picks them up at startup.
- `filamind_six_driver.py` — Six TIM Direct (USB) + TIM Cloud
  (HTTPS). Detects USB VID `0bab` / `1fc9` (MOIFA / SIX TIM).
  Implements the `pay` / `cancel` / `test_connection` actions and
  returns the response shape `pos.payment._filamind_apply_six_response`
  expects. The TIM-protocol framing is currently a clearly-marked
  `TODO` so end-to-end wiring can be validated against a real
  terminal.
- `filamind_worldline_driver.py` — Worldline CTEP (Yomani XR,
  YoxiPOS, Move/2500). Detects USB VID `0ccd`. Same response
  shape as `pos.payment._filamind_apply_worldline_response`,
  including EMV TVR / TSI for chargeback defense. CTEP framing
  also `TODO`-stubbed.
- `filamind_adam_driver.py` — Adam Equipment AGN serial protocol
  (CPWplus / GFK / GBK / GFC / GBC). Detects USB VID `0403`
  (FTDI), `067b` (Prolific), `1a86` (CH340). Implements `Z`
  (zero), `T` (tare), and `P` (poll weight) AGN commands, and
  ships a working `parse_adam_weight` helper that handles Adam's
  variable padding (`"  +123.4 g\\r\\n"` → `(123.4, 'g')`).
- `filamind_eg_fiscal_driver.py` — Egyptian Tax Authority hardware
  fiscal printer (Sunmi V2 fiscal, Aures Yuno). Detects USB VID
  `27dd` / `0fe6`. Implements `fiscal_print` that frames
  `ESC i ... ESC I` around the receipt body, queries
  `ESC ? u` (UUID) + `ESC ? q` (QR), and returns the
  device-issued signature for `pos.order._filamind_apply_eg_fiscal_response`.
- `scripts/build-image.sh` and `scripts/flash-patches.sh` updated
  to copy the new driver files into the image / running box.
- `/etc/filamind/version` now records the vendor-driver count
  alongside the patch count.

### Added — Phase 3: Self-diagnose endpoint (filamind-iotbox v0.3.0)

> Roadmap Phase 3 of 16. The box now exposes a one-shot health-check
> URL that runs DNS + TCP + HTTP + WebSocket + LongPoll probes and
> returns a copy-pasteable JSON report.

- **New patch 006** — adds `GET /iot_drivers/diagnose` to homepage.py.
  Hit it with `curl -k https://<box-ip>/iot_drivers/diagnose`.
- The 5 checks the report contains:
  1. `dns` — DNS resolution of the configured `remote_server`
  2. `tcp` — raw TCP reachability to that host:port
  3. `iot_setup` — `POST /iot/setup` HTTP probe
  4. `websocket` — full WebSocket upgrade probe (catches the
     OpenLiteSpeed `Connection: Keep-Alive` bug that was blocking
     filamind-iotbox v0.1.0 customers)
  5. `longpoll` — `POST /filamind_iot/poll_short` reachability
- `verify-image.sh` extended to assert the diagnose endpoint shipped.
- CI manifest list updated.

### Added — Phase 2: Multi-transport client (filamind-iotbox v0.2.0)

> Roadmap Phase 2 of 16. Box-side companion to filamind_iot v0.4.0
> server endpoints. The box now survives any reverse-proxy that
> mishandles WebSocket (e.g. OpenLiteSpeed Connection: Keep-Alive bug).

- **New file** `src/iot_drivers/tools/transport.py` — installed wholesale
  by `build-image.sh`. Defines:
  * `WebSocketTransport` — wraps the upstream WebsocketClient (lowest
    latency, default).
  * `LongPollTransport` — POSTs `/filamind_iot/poll` every cycle,
    blocks up to 30 s on the server.
  * `ShortPollTransport` — POSTs `/filamind_iot/poll_short` every
    `interval` seconds (default 5).
  * `Transport.create(channel, server_url)` — at boot, reads the
    cached choice from `[iot.box] transport` in `odoo.conf`, or
    auto-probes WebSocket → LongPoll → ShortPoll and persists.
- **New patch 005** — `main.py` swaps `WebsocketClient(...)` for
  `Transport.create(...)`. Drivers and `communication.handle_message`
  see no change.
- `build-image.sh` updated: copies `transport.py` to the box's
  `iot_drivers/tools/` and applies patch 005 alongside the others.
- `verify-image.sh` extended to assert `tools/transport.py` is present
  and `main.py` references `Transport.create`.
- CI's `manifest-validity` step now also requires the new patch and
  transport module to exist.

### Added — Windows-native download scripts
- `scripts/download-image.ps1` — PowerShell port of `download-image.sh`,
  uses `Get-FileHash` for SHA-256 verification and `cmd /c copy /b` for
  binary concatenation. No WSL or Git Bash required.
- `scripts/download-image.cmd` — double-clickable wrapper that invokes
  PowerShell with `-ExecutionPolicy Bypass` so users don't have to fight
  the default execution policy.
- Both files are now bundled in every Release alongside the bash version
  via `release.yml`.
- CI: new `powershell-syntax` job that AST-tokenises every `.ps1` on the
  Linux runner via `pwsh`, catching parse errors before release.

### Added
- **Pairing-code support** in the Server URL tab — paired with the
  [filamind-iot](https://github.com/filamind-app/filamind-iot) Odoo addon.
  Box POSTs `{code, identifier, ip, mac, hostname, version}` to
  `{url}/filamind_iot/pair` and stores the returned token automatically.
- Tabbed `ServerDialog` settings UI with **Server URL** and **Pairing Token** modes
- `/iot_drivers/connect_to_server` JSON-RPC endpoint accepts `url` and `code` parameters
- `scripts/build-image.sh` — patches an upstream IoT Box `.img`
- `scripts/split-image.sh` — zstd compression + 1.9 GB chunking + SHA-256 manifest
- `scripts/download-image.sh` — auto-fetches a release, verifies, and reassembles
- `scripts/flash-patches.sh` — applies patches over SSH to a running box
- `scripts/verify-image.sh` — confirms all four patches are reflected in a built image
- CI: patch syntax check, ruff, node `--check`, shellcheck, dry-run patch apply against upstream Odoo
- Release CI: builds, verifies, splits, and publishes on tag push

### Changed
- `save_conf_server()` arguments after the URL are now optional with empty-string defaults
- `/etc/rc.local` no longer auto-updates `/home/pi/odoo` from `github.com/odoo/odoo.git`

### Notes
- Built on top of the **Odoo IoT Box** image (Raspbian 13, Odoo `saas-19.1`, pi-gen 2025-10-01).
- All four modifications are reversible — see `docs/INSTALL.md` for rollback steps.
