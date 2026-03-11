#!/usr/bin/env bash
# Install sdr-pi on an existing Raspberry Pi OS.
# Usage: sudo ./scripts/install.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Error: This script must be run as root (use sudo)." >&2
    exit 1
fi

# ── Create sdr user ──────────────────────────────────────────────────────────
if ! id -u sdr &>/dev/null; then
    echo ">>> Creating sdr user..."
    useradd -r -m -s /bin/bash -G plugdev sdr
    echo "sdr:sdr" | chpasswd
    echo "    Default password is 'sdr' — change it after first login."
fi

# ── Build SDR tools (dependency order matters) ───────────────────────────────
echo ">>> Building librtlsdr..."
"$SCRIPT_DIR/setup-rtl-sdr.sh"

echo ">>> Building rtl_433..."
"$SCRIPT_DIR/setup-rtl433.sh"

echo ">>> Building dump1090..."
"$SCRIPT_DIR/setup-dump1090.sh"

echo ">>> Building OP25..."
"$SCRIPT_DIR/setup-op25.sh"

# ── Install configuration ────────────────────────────────────────────────────
echo ">>> Installing configuration..."
mkdir -p /etc/sdr-pi
if [[ ! -f /etc/sdr-pi/sdr-pi.conf ]]; then
    cp "$PROJECT_DIR/sdr-pi.conf.default" /etc/sdr-pi/sdr-pi.conf
    echo "    Installed default config to /etc/sdr-pi/sdr-pi.conf"
else
    echo "    /etc/sdr-pi/sdr-pi.conf already exists, not overwriting."
fi

# ── Install udev rules ──────────────────────────────────────────────────────
echo ">>> Installing udev rules..."
cp "$PROJECT_DIR/config/udev/99-rtlsdr.rules" /etc/udev/rules.d/
udevadm control --reload-rules || true

# ── Install kernel and boot tuning ────────────────────────────────────────
echo ">>> Installing performance tuning..."
cp "$PROJECT_DIR/config/sysctl.d/99-sdr-pi.conf" /etc/sysctl.d/
sysctl --system 2>/dev/null || true

cp "$PROJECT_DIR/config/modprobe.d/99-sdr-pi-usb.conf" /etc/modprobe.d/

# Append boot firmware config (detect Pi OS boot partition location).
BOOT_CONFIG="/boot/firmware/config.txt"
[[ -f "$BOOT_CONFIG" ]] || BOOT_CONFIG="/boot/config.txt"
if [[ -f "$BOOT_CONFIG" ]] && ! grep -q "# sdr-pi performance tuning" "$BOOT_CONFIG" 2>/dev/null; then
    echo ">>> Applying boot firmware tuning to ${BOOT_CONFIG}..."
    cat "$PROJECT_DIR/config/boot/config.txt.sdr-pi" >> "$BOOT_CONFIG"
fi

# ── Install wrapper scripts ──────────────────────────────────────────────────
echo ">>> Installing scripts..."
for script in sdr-pi-rtl433-wrapper sdr-pi-dump1090-wrapper sdr-pi-op25-wrapper \
              sdr-pi-apply-config sdr-pi-status; do
    cp "$SCRIPT_DIR/$script" /usr/local/bin/
    chmod 755 "/usr/local/bin/$script"
done

# ── Install systemd services ────────────────────────────────────────────────
echo ">>> Installing systemd services..."
cp "$PROJECT_DIR/config/systemd/"*.service /etc/systemd/system/
systemctl daemon-reload

# ── Install and configure access point ───────────────────────────────────────
echo ">>> Installing network dependencies..."
apt-get install -y hostapd dnsmasq
systemctl unmask hostapd 2>/dev/null || true

# ── Apply configuration (generates hostapd/dnsmasq, enables protocols) ───────
echo ">>> Applying configuration..."
/usr/local/bin/sdr-pi-apply-config

# ── Enable SSH ───────────────────────────────────────────────────────────────
systemctl enable ssh 2>/dev/null || true

echo ""
echo ">>> Installation complete."
echo "    Edit /etc/sdr-pi/sdr-pi.conf to customize, then run: sudo sdr-pi-apply-config"
echo "    Reboot to start all services."