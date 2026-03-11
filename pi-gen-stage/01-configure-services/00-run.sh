#!/bin/bash -e
# pi-gen stage: configure sdr-pi services and access point.
# This runs inside the pi-gen chroot during image build.

# Copy files into the chroot.
mkdir -p "${ROOTFS_DIR}/etc/sdr-pi"
install -m 644 files/sdr-pi.conf     "${ROOTFS_DIR}/etc/sdr-pi/sdr-pi.conf"
install -m 644 files/99-rtlsdr.rules "${ROOTFS_DIR}/etc/udev/rules.d/99-rtlsdr.rules"

install -m 755 files/sdr-pi-rtl433-wrapper  "${ROOTFS_DIR}/usr/local/bin/"
install -m 755 files/sdr-pi-dump1090-wrapper "${ROOTFS_DIR}/usr/local/bin/"
install -m 755 files/sdr-pi-op25-wrapper     "${ROOTFS_DIR}/usr/local/bin/"
install -m 755 files/sdr-pi-apply-config     "${ROOTFS_DIR}/usr/local/bin/"
install -m 755 files/sdr-pi-status           "${ROOTFS_DIR}/usr/local/bin/"

install -m 644 files/sdr-pi-rtl433.service       "${ROOTFS_DIR}/etc/systemd/system/"
install -m 644 files/sdr-pi-dump1090.service     "${ROOTFS_DIR}/etc/systemd/system/"
install -m 644 files/sdr-pi-op25.service          "${ROOTFS_DIR}/etc/systemd/system/"
install -m 644 files/sdr-pi-performance.service   "${ROOTFS_DIR}/etc/systemd/system/"

# Kernel and boot tuning
install -m 644 files/99-sdr-pi.conf      "${ROOTFS_DIR}/etc/sysctl.d/"
install -m 644 files/99-sdr-pi-usb.conf  "${ROOTFS_DIR}/etc/modprobe.d/"

# Journald — volatile storage to avoid SD card writes
mkdir -p "${ROOTFS_DIR}/etc/systemd/journald.conf.d"
install -m 644 files/journald.conf.override \
    "${ROOTFS_DIR}/etc/systemd/journald.conf.d/sdr-pi.conf"

# tmpfs mounts for /tmp, /var/log, /var/tmp
cat files/sdr-pi.fstab >> "${ROOTFS_DIR}/etc/fstab"

# Append boot firmware config for GPU/thermal/USB tuning.
BOOT_CONFIG="${ROOTFS_DIR}/boot/firmware/config.txt"
[ -f "$BOOT_CONFIG" ] || BOOT_CONFIG="${ROOTFS_DIR}/boot/config.txt"
if [ -f "$BOOT_CONFIG" ]; then
    cat files/config.txt.sdr-pi >> "$BOOT_CONFIG"
fi

# Append kernel command-line parameters for USB/CPU/scheduler tuning.
# cmdline.txt is a single line — extract the parameter line from our file
# (skip comments) and append it.
CMDLINE="${ROOTFS_DIR}/boot/firmware/cmdline.txt"
[ -f "$CMDLINE" ] || CMDLINE="${ROOTFS_DIR}/boot/cmdline.txt"
if [ -f "$CMDLINE" ]; then
    PARAMS=$(grep -v '^#' files/cmdline.txt.sdr-pi | tr -d '\n')
    sed -i "s|$| ${PARAMS}|" "$CMDLINE"
fi

# Set noatime on root partition to reduce SD card writes.
sed -i 's|defaults|defaults,noatime,commit=600|' "${ROOTFS_DIR}/etc/fstab"

on_chroot <<'CHROOT'
set -euo pipefail

# Create sdr user
useradd -r -m -s /bin/bash -G plugdev sdr
echo "sdr:sdr" | chpasswd

# Apply configuration (generates hostapd/dnsmasq config, enables services)
/usr/local/bin/sdr-pi-apply-config

# Enable SSH
systemctl enable ssh

# --- Disable unnecessary services for headless SDR appliance ---
systemctl disable dphys-swapfile.service || true
systemctl disable bluetooth.service || true
systemctl disable hciuart.service || true
systemctl disable ModemManager.service || true
systemctl disable triggerhappy.service || true
systemctl disable triggerhappy.socket || true
systemctl disable apt-daily.timer || true
systemctl disable apt-daily-upgrade.timer || true
systemctl disable man-db.timer || true
systemctl disable getty@tty1.service || true

# Remove swap file
rm -f /var/swap

# Remove unnecessary packages
apt-get purge -y triggerhappy modemmanager || true
apt-get autoremove -y || true
CHROOT