# sdr-pi

Custom Raspberry Pi OS image for headless SDR capture with RTL-SDR dongles.
The Pi operates as a standalone Wi-Fi access point — phones running the
[Urchin](https://github.com/pierce403/urchin) Android app connect directly to
it and receive live observations over TCP.

## Supported protocols

| Protocol | Frequency | Tool | TCP Port |
|----------|-----------|------|----------|
| TPMS | 315 / 433.92 MHz | rtl_433 | 1234 |
| POCSAG | 929.6125 MHz | rtl_433 | 1234 |
| ADS-B | 1090 MHz | dump1090-mutability | 30003 |
| P25 | 851 MHz | OP25 | 23456 |

## Building the image

### Prerequisites

- Debian, Ubuntu, or WSL2 host
- Docker installed and running
- ~10 GB free disk space
- Internet connection (the build pulls packages and compiles SDR tools from source)

### Customize the access point (optional)

The Pi broadcasts a Wi-Fi network by default. You can change the SSID and
password in `sdr-pi.conf.default` before building (or in `/etc/sdr-pi/sdr-pi.conf`
after installation):

| Setting | Default |
|---------|---------|
| SSID | `sdr-pi` |
| Password | `sdr-pi-pass` |
| IP address | `192.168.4.1` |
| DHCP range | `192.168.4.2` – `192.168.4.20` |

### Build

```bash
./scripts/build-image.sh
```

The build uses [pi-gen](https://github.com/RPi-Distro/pi-gen) inside Docker
to produce a complete Raspberry Pi OS image with all SDR tools pre-installed.
The first build takes 30–60 minutes; subsequent rebuilds are much faster with
stage skipping and apt caching (see below).

The resulting image is written to:

```
deploy/sdr-pi-<date>.img
```

### Faster rebuilds

The build script registers QEMU user-mode emulation via `binfmt_misc`
automatically so ARM binaries run in the chroot without a full VM. On
Linux hosts with KVM support, Docker uses hardware-accelerated emulation.

**Skip unchanged stages** — after a successful build, the base OS stages
(0–2) are cached. Set `SDR_PI_CONTINUE=1` to skip them and only rebuild
the sdr-pi stage (~10 min instead of ~60 min):

```bash
SDR_PI_CONTINUE=1 ./scripts/build-image.sh
```

**apt-cacher-ng** — avoid re-downloading ~500 MB of packages on every
build by running a local apt cache:

```bash
# Start a cache container (one-time)
docker run -d -p 3142:3142 --name apt-cache \
    -v apt-cache:/var/cache/apt-cacher-ng sameersbn/apt-cacher-ng

# Point the build at it
SDR_PI_APT_CACHE=http://host.docker.internal:3142 ./scripts/build-image.sh
```

**ccache** — compiled object files are cached in `build/ccache/` and
automatically mounted into the Docker container. On rebuilds where the
SDR source hasn't changed, compilation drops from minutes to seconds.
No configuration needed — it works out of the box.

**eatmydata** — installed automatically inside the chroot to skip
`fsync()` calls, which QEMU emulates slowly. Speeds up `apt-get` and
compilation I/O by 10–20%.

**Parallel compilation** — after librtlsdr is built, rtl_433, dump1090,
and OP25 compile concurrently.

**Clean build** — wipe all cached state and start fresh:

```bash
SDR_PI_CLEAN=1 ./scripts/build-image.sh
```

All options can be combined:

```bash
SDR_PI_CONTINUE=1 SDR_PI_APT_CACHE=http://host.docker.internal:3142 ./scripts/build-image.sh
```

### WSL2 performance tips

If building on Windows with WSL2, these settings make a significant
difference:

1. **Keep files on the Linux filesystem.** Clone the repo inside WSL2
   (e.g. `~/src/sdr-pi`), not on `/mnt/c/`. The NTFS bridge is up to
   20x slower for I/O-heavy builds.

2. **Allocate sufficient resources.** Create or edit
   `C:\Users\<you>\.wslconfig`:

   ```ini
   [wsl2]
   memory=16GB
   processors=8
   swap=4GB
   ```

3. **Exclude from Windows Defender.** Add the WSL2 VHD path and Docker
   data directory to Defender's exclusion list — real-time scanning adds
   measurable overhead to every file operation during compilation.

### Alternative: install on an existing Raspberry Pi OS

If you already have a Pi running Raspberry Pi OS:

```bash
git clone https://github.com/ingmarvg/sdr-pi.git
cd sdr-pi
sudo ./scripts/install.sh
```

This installs all dependencies, builds the SDR tools from source, and configures
the systemd services.

## Writing the image to an SD card

### Linux / WSL

1. Insert your SD card and identify the device:

   ```bash
   lsblk
   ```

   Look for your SD card (e.g. `/dev/sdb` or `/dev/mmcblk0`). **Make sure you
   pick the right device — this will overwrite everything on it.**

2. Write the image:

   ```bash
   sudo dd if=deploy/sdr-pi-*.img of=/dev/sdX bs=4M status=progress conv=fsync
   ```

   Replace `/dev/sdX` with your actual device path.

3. Eject safely:

   ```bash
   sudo eject /dev/sdX
   ```

### Windows

Use [Raspberry Pi Imager](https://www.raspberrypi.com/software/) or
[balenaEtcher](https://etcher.balena.io/):

1. Open the tool and select **Use custom** / **Flash from file**.
2. Choose the `.img` file from `deploy/`.
3. Select your SD card as the target.
4. Click **Write** and wait for it to complete.

### macOS

1. Identify the disk:

   ```bash
   diskutil list
   ```

2. Unmount (not eject) the SD card:

   ```bash
   diskutil unmountDisk /dev/diskN
   ```

3. Write:

   ```bash
   sudo dd if=deploy/sdr-pi-*.img of=/dev/rdiskN bs=4m
   ```

   Using `/dev/rdiskN` (raw disk) is significantly faster than `/dev/diskN`.

4. Eject:

   ```bash
   diskutil eject /dev/diskN
   ```

## First boot

1. Insert the SD card into the Pi and connect your RTL-SDR dongle(s).
2. Power on. The Pi will start the access point and the enabled SDR services
   automatically.
3. On your phone or laptop, join the `sdr-pi` Wi-Fi network (password:
   `sdr-pi-pass`).
4. The Pi is reachable at `192.168.4.1`. To SSH in:

   ```bash
   ssh sdr@192.168.4.1
   ```

## Configuration

All runtime settings live in `/etc/sdr-pi/sdr-pi.conf`. After making changes,
apply the configuration and restart services:

```bash
sudo sdr-pi-apply-config
sudo systemctl restart sdr-pi-rtl433 sdr-pi-dump1090 sdr-pi-op25
```

`sdr-pi-apply-config` regenerates the hostapd and dnsmasq configs from
`sdr-pi.conf` and enables/disables systemd services based on
`ENABLED_PROTOCOLS`. Run it whenever you change AP or protocol settings.

### Service status

Check the health of all services at a glance:

```bash
sdr-pi-status
```

### Enabling and disabling protocols

Set `ENABLED_PROTOCOLS` to a space-separated list of the protocols you want
active on boot:

```bash
# Run only TPMS and ADS-B
ENABLED_PROTOCOLS="tpms adsb"

# Run everything
ENABLED_PROTOCOLS="tpms pocsag adsb p25"
```

### Tuning frequencies

Each decoder has a frequency setting. Set the value in Hz or use the `M`
suffix for MHz:

```bash
# rtl_433 — covers TPMS and POCSAG
RTL433_FREQUENCY="315M"       # US TPMS (use 433.92M for EU)

# OP25 — P25 trunked radio
OP25_FREQUENCY="851M"
```

ADS-B is always 1090 MHz (fixed in the dump1090 protocol).

### Adjusting gain

Each decoder accepts a gain value. Use `auto` to let the dongle decide, or
set a specific value:

```bash
RTL433_GAIN="auto"            # auto AGC
DUMP1090_GAIN="max"           # maximum gain (best for ADS-B)
OP25_GAIN="40"                # manual gain
```

### Extra decoder flags

Pass additional command-line flags to any decoder with the `_EXTRA_ARGS`
settings. For example, to limit rtl_433 to only TPMS decoders:

```bash
RTL433_EXTRA_ARGS="-R 59 -R 60"
```

### Multi-dongle setup

When multiple RTL-SDR dongles are connected, each service can be pinned to a
specific dongle by serial number. Run `rtl_test` to list connected devices:

```bash
$ rtl_test
Found 2 device(s):
  0:  Realtek, RTL2838UHIDIR, SN: 00000001
  1:  Realtek, RTL2838UHIDIR, SN: 00000002
```

Then assign serials in `sdr-pi.conf`:

```bash
RTL433_DEVICE_SERIAL="00000001"
DUMP1090_DEVICE_SERIAL="00000002"
OP25_DEVICE_SERIAL=""          # leave blank for auto
```

### All configuration options

| Setting | Default | Description |
|---------|---------|-------------|
| `ENABLED_PROTOCOLS` | `tpms adsb` | Protocols to start on boot |
| `AP_SSID` | `sdr-pi` | Wi-Fi access point name |
| `AP_PASSWORD` | `sdr-pi-pass` | Wi-Fi password |
| `AP_CHANNEL` | `7` | Wi-Fi channel |
| `AP_IP` | `192.168.4.1` | Pi's static IP on the AP network |
| `RTL433_FREQUENCY` | `315M` | rtl_433 center frequency |
| `RTL433_GAIN` | `auto` | rtl_433 gain |
| `RTL433_PORT` | `1234` | rtl_433 TCP listen port |
| `RTL433_DEVICE_SERIAL` | _(auto)_ | RTL-SDR serial for rtl_433 |
| `RTL433_EXTRA_ARGS` | _(none)_ | Additional rtl_433 flags |
| `DUMP1090_GAIN` | `max` | dump1090 gain |
| `DUMP1090_PORT` | `30003` | dump1090 TCP listen port |
| `DUMP1090_DEVICE_SERIAL` | _(auto)_ | RTL-SDR serial for dump1090 |
| `DUMP1090_EXTRA_ARGS` | _(none)_ | Additional dump1090 flags |
| `OP25_FREQUENCY` | `851M` | OP25 center frequency |
| `OP25_GAIN` | `auto` | OP25 gain |
| `OP25_PORT` | `23456` | OP25 TCP listen port |
| `OP25_DEVICE_SERIAL` | _(auto)_ | RTL-SDR serial for OP25 |
| `OP25_EXTRA_ARGS` | _(none)_ | Additional OP25 flags |

## Accessing rtl_tcp

`rtl_tcp` is a raw IQ streaming server included with librtlsdr. It lets you
use the Pi's RTL-SDR dongle from any networked SDR application (SDR#, GQRX,
CubicSDR, GNU Radio, etc.) as if it were plugged in locally.

### Starting rtl_tcp

rtl_tcp is not started by default because it takes exclusive control of a
dongle. To start it manually:

```bash
rtl_tcp -a 0.0.0.0 -p 1234
```

| Flag | Description |
|------|-------------|
| `-a 0.0.0.0` | Listen on all network interfaces (required for remote access) |
| `-p 1234` | TCP port to listen on (default: 1234) |
| `-d 0` | Device index if multiple dongles are connected |
| `-s 2048000` | Sample rate in Hz (default: 2048000) |
| `-f 100000000` | Initial frequency in Hz (e.g. 100 MHz) |
| `-g 40` | Gain in tenths of dB (e.g. 40 = 4.0 dB), or 0 for auto |

> **Note:** rtl_tcp binds one dongle exclusively. If you want to run rtl_tcp
> alongside the SDR services, you need a separate dongle for each. Stop the
> conflicting service first, or use a different device index (`-d`).

### Connecting from a client

In your SDR application, add an RTL-TCP source with:

- **Host:** `192.168.4.1` (the Pi's AP address)
- **Port:** `1234` (or whatever you passed to `-p`)

**SDR# (Windows):**
Select `RTL-SDR (TCP)` as the source, enter the Pi's IP and port in the
settings panel.

**GQRX (Linux/macOS):**
Set the device string to `rtl_tcp=192.168.4.1:1234` in the device
configuration dialog.

**CubicSDR:**
Select `RTL-SDR (TCP)` and enter the host and port when prompted.

### Running rtl_tcp as a service

To have rtl_tcp start automatically on boot, create a systemd unit:

```bash
sudo tee /etc/systemd/system/rtl-tcp.service << 'EOF'
[Unit]
Description=RTL-TCP IQ streaming server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/rtl_tcp -a 0.0.0.0 -p 1234
Restart=on-failure
RestartSec=5
User=sdr
Group=plugdev

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now rtl-tcp
```

Check status:

```bash
sudo systemctl status rtl-tcp
```

## Connecting Urchin

1. On your Android device, connect to the `sdr-pi` Wi-Fi network.
2. In Urchin, go to Settings and set the bridge host to `192.168.4.1`.
3. Ports are pre-configured to match Urchin's defaults (1234, 30003, 23456).

## Hardware

- Raspberry Pi 3B+ / 4 / 5
- One or more RTL-SDR Blog V3/V4 dongles (or HackRF One)
- Powered USB hub recommended for multiple dongles

## Project structure

```
sdr-pi/
├── config/
│   ├── systemd/           # systemd unit files for SDR services
│   ├── udev/              # udev rules for RTL-SDR device permissions
│   └── network/           # default network config (templates)
├── scripts/
│   ├── build-image.sh     # builds complete Pi image via pi-gen
│   ├── install.sh         # installs on existing Pi OS
│   ├── setup-rtl-sdr.sh   # builds librtlsdr from source
│   ├── setup-rtl433.sh    # builds rtl_433 from source
│   ├── setup-dump1090.sh  # builds dump1090-mutability from source
│   ├── setup-op25.sh      # builds OP25 from source
│   ├── sdr-pi-apply-config   # applies sdr-pi.conf to system configs
│   ├── sdr-pi-status         # shows service health at a glance
│   ├── sdr-pi-rtl433-wrapper # systemd wrapper for rtl_433
│   ├── sdr-pi-dump1090-wrapper # systemd wrapper for dump1090
│   └── sdr-pi-op25-wrapper   # systemd wrapper for OP25
├── pi-gen-stage/          # custom pi-gen stage for image builds
│   ├── 00-install-sdr/    # builds SDR tools from source
│   └── 01-configure-services/  # installs configs and enables services
├── sdr-pi.conf.default    # default configuration
└── LICENSE                # Apache-2.0
```

## License

Apache-2.0
