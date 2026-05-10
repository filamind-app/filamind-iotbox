# Installation

Three supported paths, ordered from least to most invasive.

## A. Apply patches over SSH to a live IoT Box (~30 seconds)

Best when you already have an Odoo IoT Box running and just want the new UI.

```bash
git clone https://github.com/filamind-app/filamind-iotbox
cd filamind-iotbox
./scripts/flash-patches.sh pi@<iot-box-ip>
```

The script:
1. Remounts `/` read-write
2. Backs up the four originals to `*.filamind-backup`
3. Applies the two Python patches with `patch -p1`
4. Replaces `ServerDialog.js` and `/etc/rc.local`
5. Restarts `odoo.service`

To roll back:

```bash
ssh pi@<iot-box-ip>
sudo cp /etc/rc.local.filamind-backup /etc/rc.local
sudo cp /home/pi/odoo/addons/iot_drivers/tools/helpers.py.filamind-backup \
        /home/pi/odoo/addons/iot_drivers/tools/helpers.py
# ... etc for the other two files
sudo systemctl restart odoo
```

---

## B. Flash a pre-built release image (recommended)

Best when bringing up a new device.

### 1. Download

```bash
curl -fsSL https://github.com/filamind-app/filamind-iotbox/releases/latest/download/download-image.sh -o download-image.sh
chmod +x download-image.sh
./download-image.sh                # latest release
./download-image.sh v1.0.0         # specific version
```

The script downloads every release part, verifies SHA-256 at three stages
(parts → compressed image → final `.img`), reassembles, and decompresses.

### 2. Flash

#### Option 1: `dd` (Linux / WSL2 / macOS)

```bash
sudo dd if=iotbox-image/iotbox-filamind-*.img of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

> Replace `/dev/sdX` with the **whole disk** node of your SD card (`lsblk` will tell you).
> **Triple-check** — `dd` will silently overwrite anything you point it at.

#### Option 2: Raspberry Pi Imager (cross-platform)

1. Open **Raspberry Pi Imager**
2. Choose OS → **Use custom** → pick the `iotbox-filamind-*.img`
3. Choose Storage → your SD card
4. Write

### 3. First boot

Insert the SD card into a Raspberry Pi (any model from Pi B+ to Pi 5 / CM5).
Within ~60 seconds the box is reachable:

- **Wired:** the IP it gets from DHCP (you'll see it on a connected screen, or via your router).
- **Wireless setup:** the box exposes an `IoT-Box-XXXX` Wi-Fi access point. Join it, then
  open `http://10.11.12.1:8069`.

### 4. Point at your server

1. Click **Configure** in the Connection card
2. Pick the **Server URL** tab
3. Enter `https://your-odoo-server.com` and click **Connect**
4. The box restarts Odoo. After ~10 seconds the page reloads showing your server URL.

> If your server is internal-only (no public TLS cert), use plain `http://` or install
> a trusted CA on the IoT Box. Self-signed certs are not auto-trusted.

---

## C. Build the image yourself

When you want to verify what's in the release, or customize further.

### Requirements (Linux / WSL2 Ubuntu)

```bash
sudo apt-get install -y zstd parted unzip kpartx mount
```

### Build

```bash
git clone https://github.com/filamind-app/filamind-iotbox
cd filamind-iotbox
sudo ./scripts/build-image.sh                       # downloads latest upstream
# OR:
sudo ./scripts/build-image.sh /path/to/iotbox-2026.05.09.img
```

Output: `build/iotbox-filamind-<date>.img`.

### Verify

```bash
sudo ./scripts/verify-image.sh build/iotbox-filamind-*.img
```

Confirms:
- Partition table is intact
- OS identity matches (Raspbian + iotbox hostname)
- All four patches are reflected in the on-disk filesystem

### Package for distribution

```bash
./scripts/split-image.sh build/iotbox-filamind-*.img
ls build/release/
```

Produces `*.img.zst.NN.part` chunks (≤ 1.9 GB each) and `MANIFEST.sha256`.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `download-image.sh: gh: command not found` | install [GitHub CLI](https://cli.github.com/) **or** install `curl` + `jq` (script auto-falls-back) |
| `sha256sum: WARNING: ... computed checksum did NOT match` | re-download — a release asset was truncated |
| Box reboots into pairing screen after `Connect` | server URL is unreachable, or TLS cert is untrusted |
| Patches don't apply on a running box | the box has the upstream auto-update enabled — patches were already wiped. Apply patch 4 first, then re-apply 1-3 |
| `mount: unknown filesystem type` (build script) | install `e2fsprogs` and ensure your kernel has ext4 |

---

## Architecture details

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full picture: how the IoT Box
communicates with the server, what `iot-proxy.odoo.com` does, and exactly which
endpoints we modify.
