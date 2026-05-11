# Changelog

All notable changes to filamind-iotbox are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/) and
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed — transport.py circular import (patch 005 was unloadable)

> Phase-2 transport selector (`patch 005`) failed to load on the
> first real-box deploy at deltafabs.com:
>
>     CRITICAL ? odoo.modules.module: Couldn't load module iot_drivers
>     ImportError: cannot import name 'communication' from partially
>     initialized module 'odoo.addons.iot_drivers' (most likely due
>     to a circular import)
>     File ".../iot_drivers/tools/transport.py", line 27,
>     in <module> from odoo.addons.iot_drivers import communication
>
> `iot_drivers/__init__.py` → `connection_manager` → `main` →
> `tools.transport` (us). `transport.py` then re-imported from
> `iot_drivers` while it was still partially initialised → boom.
>
> Net effect on a real box: ALL `/iot_drivers/*` endpoints 404
> because the addon never finished loading. The box was dead until
> patch 005 was reverted.

Fix: defer `from odoo.addons.iot_drivers import communication` to
inside `_PollingTransportBase._dispatch()` where it's actually
used. By the time a poll fires the module load is complete and
the cycle is resolved.

Also drops the unused `import time` flagged by ruff that snuck in
when the file was first written.

Verified end-to-end on the customer box: patch 005 + new
transport.py applied, `systemctl restart odoo`, `iot_drivers`
loads cleanly, `/iot_drivers/diagnose` and
`/iot_drivers/diagnose.html` both return 200.

### Fixed — patch 007 runtime bugs (uncovered by first real-box deploy)

> Phase-25 patch 007 (the `/iot_drivers/diagnose.html` HTML
> wrapper) SHIPPED in v0.6.0 but THREW 500 ON FIRST USE on the
> real customer box at deltafabs.com:
> `TypeError: the JSON object must be str, bytes or bytearray,
> not _Response`. Two bugs in one function:

1. `json.loads(self.diagnose())` — `self.diagnose()` is decorated
   as an HTTP route, so Odoo wraps its return in a `Response`
   object. Calling `json.loads` on the wrapper raises `TypeError`.
   **Fix:** `json.loads(self.diagnose().get_data(as_text=True))`.

2. The HTML template was built via Python `%` formatting, which
   interpreted literal `%` characters in CSS (`width:100%`) as
   format specifiers and threw `ValueError` on the first request
   that had non-empty data. **Fix:** rewrite the function to build
   the HTML via `str.replace('__SLOT__', value)` with distinct
   sentinel placeholders, so no `%`-escaping is needed and CSS
   `width:100%` is passed through verbatim.

Also tightens HTML-escaping (now escapes `<` consistently in
both `name` and `detail` cells, plus `word-break: break-all` on
the `<code>` so long URLs don't overflow on tablets).

Both fixes have been hot-applied to the customer box and verified
working: `https://<box>/iot_drivers/diagnose.html` returns 200
with the expected red/green table.
### Fixed — Phase 25: self-signed TLS cert (filamind-iotbox v0.6.0)

> Resolves the persistent "This IoT Box doesn't have a valid
> certificate" warning surfaced by the upstream homepage UI.
> Upstream Odoo IoT Boxes fetch a wildcard cert from
> iot-proxy.odoo.com after pairing. filamind-iotbox skips that
> proxy by design, which left the box's own HTTPS without a
> cert and the homepage flagged it. This phase generates a
> 10-year self-signed cert at first boot.

- New helper `/usr/local/bin/filamind-make-self-signed-cert`:
  - Idempotent — exits cleanly if a valid (≥ 30 days remaining)
    cert is already in place, or if a real upstream-managed
    cert exists at the standard path.
  - Generates a 2048-bit RSA cert with SAN entries for hostname,
    short name, `*.local` mDNS, `localhost`, `127.0.0.1`, and
    every detected LAN IP. Subject: `O=filamind-iotbox,
    OU=self-signed, CN=<fqdn>`.
  - Symlinks into the upstream paths
    (`/etc/ssl/certs/nginx-cert.crt`,
    `/etc/ssl/private/nginx-cert.key`) so nginx + the homepage
    UI find them without code changes.
  - Drops `/etc/filamind/cert-source = self-signed` so any
    cosmetic UI improvement can later show "self-signed" rather
    than the alarming "no cert".
  - Reloads nginx if running, swallows the reload error if not.
- `src/etc/rc.local` now invokes the helper at boot. Both
  build-image.sh + flash-patches.sh install the helper; the
  flash path also generates the cert immediately so the next
  homepage hit reflects the new state.
- `verify-image.sh` asserts both the helper file and the
  rc.local invocation are present.
- Smoke-tested locally: openssl produces a valid 10-year cert
  with the expected subject and full SAN list.

Browsers will still show "Not secure / proceed anyway?" the
first time — that's expected for any self-signed cert. Admins
who want a clean lock icon can replace the symlinked files
with a CA-signed cert; the helper detects that and stays out
of the way.

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
