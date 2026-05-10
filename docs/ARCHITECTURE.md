# Architecture

This document describes the upstream Odoo IoT Box and the four small changes
filamind-iotbox makes to it.

## 1. The upstream IoT Box

A Raspberry Pi running Raspbian + an Odoo server with two addons enabled:
`iot_drivers` and `web`. It exposes peripherals (printers, scales, scanners,
payment terminals, customer displays) to a remote Odoo database over HTTPS +
WebSocket.

### Connection lifecycle (stock)

```
┌──────────┐   1. POST pairing_code         ┌──────────────────────────┐
│  IoT Box │ ─────────────────────────────► │ iot-proxy.odoo.com       │
│          │ ◄───────────────────────────── │ (registers + polls)      │
└──────────┘    2. {url, token, db_uuid}    └──────────────────────────┘
      │
      │ 3. save_conf_server(...)
      ▼
/home/pi/odoo.conf  [iot.box]
  remote_server = https://customer-db.odoo.com
  token         = ...
  db_uuid       = ...
  enterprise_code = ...
      │
      │ 4. WebSocket subscribe + HTTP POST /iot/box/...
      ▼
┌────────────────────┐
│  Customer's Odoo   │
│  database          │
└────────────────────┘
```

The user pastes a **pairing code** in the customer's Odoo database (via the IoT
app), the database calls `iot-proxy.odoo.com`, and the proxy forwards the
connection details to the polling box.

### Why this is fine for SaaS but awkward for self-hosted

If your Odoo runs on `odoo.example.com` with no exposure to `odoo.com`'s proxy,
you can still use the existing **Pairing Token** path (you copy the token string
out of your own database and paste it into the box). But:

- It's a manual copy-paste of a long string.
- If the box can't reach `iot-proxy.odoo.com`, the registration thread keeps
  hammering it forever. Idle bandwidth, noisy logs.
- The settings dialog leads with proxy-based onboarding messaging.

filamind-iotbox adds a **second equivalent path**: paste the URL only. The
existing token path is preserved.

---

## 2. Servers contacted by the stock image

| URL | Purpose | Modifiable in stock | After filamind |
|---|---|---|---|
| `https://iot-proxy.odoo.com/odoo-enterprise/iot/connect-box` | Pairing proxy | code edit | bypassable via URL tab |
| `https://www.odoo.com/odoo-enterprise/iot/x509` | TLS cert provisioning | code edit | unchanged |
| `https://nightly.odoo.com/master/iotbox/SHA1SUMS.txt` | Image self-update check | code edit | unchanged |
| `https://nightly.odoo.com/master/posbox/iotbox/*.zip` | Payment-terminal driver downloads | code edit | unchanged |
| `https://github.com/odoo/odoo.git` | Git auto-update at every boot | rc.local | **disabled** by patch 4 |
| `www.odoo.com` (ICMP) | WAN-quality ping | code edit | unchanged |
| Customer Odoo URL | Actual data exchange | `odoo.conf` | **also settable from UI** |

---

## 3. Patches

### Patch 1 — `tools/helpers.py`

`save_conf_server(url, token, db_uuid, enterprise_code, db_name=None)` becomes
`save_conf_server(url, token='', db_uuid='', enterprise_code='', db_name=None)`.

Before: a caller had to supply all four fields. The pairing proxy always returns
all four together, so this never mattered. Now we want to support saving just
the URL.

The default `''` (empty string) is consistent with how `disconnect_from_server`
clears these values today.

### Patch 2 — `controllers/homepage.py`

`/iot_drivers/connect_to_server` is JSON-RPC; today it accepts `{token: "..."}`.
After the patch it also accepts `{url: "..."}` and routes that case through
`helpers.parse_url` + `helpers.save_conf_server`. Both paths end with
`helpers.odoo_restart(1)`.

The token path is preserved verbatim; the new branch is exclusive to the
no-token case.

### Patch 3 — `static/.../ServerDialog.js`

Replaces the single token input with a tabbed UI:

- Tab **Server URL**: one `<input type="url">`. Submits `{url: ...}`.
- Tab **Pairing Token**: original input. Submits `{token: ...}`.

The submit button enables/disables based on which tab is active and whether
its input is non-empty.

### Patch 4 — `/etc/rc.local`

The stock script does this on every boot:

```sh
sudo -u odoo git remote set-url "${localremote}" "https://github.com/odoo/odoo.git"
sudo -u odoo GIT_SSL_NO_VERIFY=1 git fetch "${localremote}" "${localbranch}" --depth=1
sudo -u odoo git reset --hard FETCH_HEAD
```

The `git reset --hard FETCH_HEAD` would silently revert patches 1, 2, 3 every
time the box is power-cycled. We comment the entire block out.

**Implication:** the box no longer self-updates from upstream. To refresh, flash
a new filamind-iotbox release (which itself rebuilds from a fresh upstream
nightly). A self-update mechanism that pulls from this repo could be added
later without conflicting.

---

## 4. The release pipeline

```
┌────────────┐
│  git tag   │
│   v1.0.0   │
└─────┬──────┘
      │ push
      ▼
┌────────────────────────────────────────────────────────────────┐
│  .github/workflows/release.yml                                 │
│  ─────────────────────────────                                 │
│  1. download nightly upstream iotbox-*.img.zip                 │
│  2. unzip → upstream.img                                       │
│  3. ./scripts/build-image.sh (patches applied)                 │
│  4. ./scripts/verify-image.sh (4 patches confirmed in fs)      │
│  5. ./scripts/split-image.sh (zstd + 1.9 GB chunks + sha256)   │
│  6. gh release create with all parts + manifest + downloader   │
└─────┬──────────────────────────────────────────────────────────┘
      ▼
┌────────────────────────────────────────────────────────────────┐
│  GitHub Release v1.0.0                                         │
│   ├─ iotbox-filamind-v1.0.0.img.zst.00.part                    │
│   ├─ iotbox-filamind-v1.0.0.img.zst.01.part                    │
│   ├─ iotbox-filamind-v1.0.0.img.zst.NN.part                    │
│   ├─ MANIFEST.sha256                                           │
│   └─ download-image.sh                                         │
└─────┬──────────────────────────────────────────────────────────┘
      │ curl … | bash
      ▼
┌────────────────────────────────────────────────────────────────┐
│  download-image.sh                                             │
│  1. gh release download (or curl fallback)                     │
│  2. sha256sum -c parts                                         │
│  3. cat *.part > image.img.zst                                 │
│  4. sha256sum -c compressed                                    │
│  5. zstd -d                                                    │
│  6. sha256sum -c final .img                                    │
└────────────────────────────────────────────────────────────────┘
```

Three layers of SHA-256 verification mean any corruption is caught before the
user wastes time flashing a bad image.

---

## 5. Why the image is split

GitHub release assets cap at 2 GB per file. The stock IoT Box image is ~5.6 GB;
zstd brings it to ~1.8–2.4 GB. To stay safely under the cap (and to support
future image growth), `split-image.sh` chunks the compressed image into
1.9 GB parts. Reassembly is just `cat` — no special tooling required on the
client.

---

## 6. License

Odoo is **LGPL-3.0-or-later**. The patches we add are derivative works of Odoo
source files and are therefore also distributed under LGPL-3.0-or-later.
Build scripts, CI workflows, and documentation are also LGPL-3.0-or-later for
simplicity. See `LICENSE`.
