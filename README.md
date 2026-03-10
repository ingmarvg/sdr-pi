# sdr-pi

Custom Raspberry Pi OS image for headless SDR capture with RTL-SDR dongles.
Designed as a companion station for the [Spider](https://github.com/pierce403/urchin) Android app,
streaming live observations over TCP network bridges.

## Supported protocols

| Protocol | Frequency | Tool | TCP Port |
|----------|-----------|------|----------|
| TPMS | 315 / 433.92 MHz | rtl_433 | 1234 |
| POCSAG | 929.6125 MHz | rtl_433 | 1234 |
| ADS-B | 1090 MHz | dump1090-mutability | 30003 |
| P25 | 851 MHz | OP25 | 23456 |

## Quick start

### Option A: Build a complete image

Requires a Debian/Ubuntu host (or WSL) with docker installed.

```bash
./scripts/build-image.sh
```

The resulting `.img` file will be in `deploy/`.

### Option B: Install on an existing Raspberry Pi OS

```bash
curl -sSL https://raw.githubusercontent.com/<you>/sdr-pi/main/scripts/install.sh | sudo bash
```

Or clone and run manually:

```bash
git clone https://github.com/<you>/sdr-pi.git
cd sdr-pi
sudo ./scripts/install.sh
```

## Configuration

After boot, edit `/etc/sdr-pi/sdr-pi.conf` to set frequencies, gain, and
enabled protocols. Then restart services:

```bash
sudo systemctl restart sdr-pi-rtl433 sdr-pi-dump1090 sdr-pi-op25
```

### Wi-Fi

Copy and edit the example wpa_supplicant config before building the image:

```bash
cp config/network/wpa_supplicant.conf.example config/network/wpa_supplicant.conf
# edit with your SSID and password
```

### Multi-dongle setup

When multiple RTL-SDR dongles are connected, each service can be pinned to a
specific dongle by serial number in `sdr-pi.conf`. Run `rtl_test` to list
connected devices and their serials.

## Connecting Spider

1. Ensure the Pi and Android device are on the same network.
2. In Spider, go to Settings and set the bridge host to the Pi's IP address.
3. Ports are pre-configured to match Spider's defaults (1234, 30003, 23456).

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
│   └── network/           # network configuration templates
├── scripts/
│   ├── build-image.sh     # builds complete Pi image via pi-gen
│   ├── install.sh         # installs on existing Pi OS
│   ├── setup-rtl-sdr.sh   # builds librtlsdr from source
│   ├── setup-rtl433.sh    # builds rtl_433 from source
│   ├── setup-dump1090.sh  # builds dump1090-mutability from source
│   └── setup-op25.sh      # builds OP25 from source
├── pi-gen-stage/          # custom pi-gen stage
│   ├── 00-install-sdr/    # package installation
│   └── 01-configure-services/  # service configuration
└── sdr-pi.conf.default    # default configuration
```

## License

Apache-2.0
