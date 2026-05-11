# Changelog

All notable changes to filamind-iotbox are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/) and
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
