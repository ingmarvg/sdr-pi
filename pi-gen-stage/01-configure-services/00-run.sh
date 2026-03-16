#!/bin/bash -e
# pi-gen stage: configure sdr-pi services and access point.
# This runs inside the pi-gen chroot during image build.

# Copy files into the chroot.
mkdir -p "${ROOTFS_DIR}/etc/sdr-pi"
install -m 644 files/sdr-pi.conf     "${ROOTFS_DIR}/etc/sdr-pi/sdr-pi.conf"
install -m 644 files/99-rtlsdr.rules      "${ROOTFS_DIR}/etc/udev/rules.d/99-rtlsdr.rules"
install -m 644 files/99-lorawan-spi.rules "${ROOTFS_DIR}/etc/udev/rules.d/99-lorawan-spi.rules"

# LoRaWAN concentrator configuration
mkdir -p "${ROOTFS_DIR}/etc/sdr-pi/lorawan"
install -m 644 files/global_conf.us915.json "${ROOTFS_DIR}/etc/sdr-pi/lorawan/"
install -m 644 files/global_conf.eu868.json "${ROOTFS_DIR}/etc/sdr-pi/lorawan/"

install -m 755 files/sdr-pi-rtl433-wrapper      "${ROOTFS_DIR}/usr/local/bin/"
install -m 755 files/sdr-pi-dump1090-wrapper    "${ROOTFS_DIR}/usr/local/bin/"
install -m 755 files/sdr-pi-op25-wrapper        "${ROOTFS_DIR}/usr/local/bin/"
install -m 755 files/sdr-pi-lorawan-wrapper     "${ROOTFS_DIR}/usr/local/bin/"
install -m 755 files/sdr-pi-pocsag-wrapper      "${ROOTFS_DIR}/usr/local/bin/"
install -m 755 files/sdr-pi-dump978-wrapper     "${ROOTFS_DIR}/usr/local/bin/"
install -m 755 files/sdr-pi-dmr-wrapper         "${ROOTFS_DIR}/usr/local/bin/"
install -m 755 files/sdr-pi-nxdn-wrapper        "${ROOTFS_DIR}/usr/local/bin/"
install -m 755 files/sdr-pi-meshtastic-wrapper  "${ROOTFS_DIR}/usr/local/bin/"
install -m 755 files/sdr-pi-apply-config        "${ROOTFS_DIR}/usr/local/bin/"
install -m 755 files/sdr-pi-status              "${ROOTFS_DIR}/usr/local/bin/"

install -m 644 files/sdr-pi-rtl433.service       "${ROOTFS_DIR}/etc/systemd/system/"
install -m 644 files/sdr-pi-dump1090.service     "${ROOTFS_DIR}/etc/systemd/system/"
install -m 644 files/sdr-pi-op25.service         "${ROOTFS_DIR}/etc/systemd/system/"
install -m 644 files/sdr-pi-lorawan.service      "${ROOTFS_DIR}/etc/systemd/system/"
install -m 644 files/sdr-pi-pocsag.service       "${ROOTFS_DIR}/etc/systemd/system/"
install -m 644 files/sdr-pi-dump978.service      "${ROOTFS_DIR}/etc/systemd/system/"
install -m 644 files/sdr-pi-dmr.service          "${ROOTFS_DIR}/etc/systemd/system/"
install -m 644 files/sdr-pi-nxdn.service         "${ROOTFS_DIR}/etc/systemd/system/"
install -m 644 files/sdr-pi-meshtastic.service   "${ROOTFS_DIR}/etc/systemd/system/"
install -m 644 files/sdr-pi-performance.service  "${ROOTFS_DIR}/etc/systemd/system/"

# Kernel and boot tuning
install -m 644 files/99-sdr-pi.conf      "${ROOTFS_DIR}/etc/sysctl.d/"
install -m 644 files/99-sdr-pi-usb.conf  "${ROOTFS_DIR}/etc/modprobe.d/"

# Journald — volatile storage to avoid SD card writes
mkdir -p "${ROOTFS_DIR}/etc/systemd/journald.conf.d"
install -m 644 files/journald.conf.override \
    "${ROOTFS_DIR}/etc/systemd/journald.conf.d/sdr-pi.conf"

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

# Set noatime,commit=600 on real disk partitions only (proc, ext4, vfat).
# Do NOT touch tmpfs lines — commit= is invalid for tmpfs.
sed -i '/^proc\|^PARTUUID/s|defaults|defaults,noatime,commit=600|' "${ROOTFS_DIR}/etc/fstab"

# tmpfs mounts for /tmp, /var/log, /var/tmp — appended AFTER the sed above
# so they are not modified by it.
cat files/sdr-pi.fstab >> "${ROOTFS_DIR}/etc/fstab"

on_chroot <<'CHROOT'
set -euo pipefail

# Ensure sdr user exists with the right groups and an unlocked password.
# pi-gen stage1 creates the user (FIRST_USER_NAME=sdr) and sets the password
# (FIRST_USER_PASS from SDR_PI_SSH_PASSWORD).  If the user somehow doesn't
# exist, create a normal (not system) account so the password is not locked.
if id -u sdr &>/dev/null; then
    usermod -a -G plugdev,spi,gpio,dialout sdr
else
    useradd -m -s /bin/bash -G plugdev,spi,gpio,dialout sdr
fi
# Ensure password is not locked (useradd sets '!' by default).
# pi-gen should have already set FIRST_USER_PASS, but if the user was
# recreated above, the password field will be locked.  Unlock it and
# re-apply the configured password.
passwd -u sdr 2>/dev/null || true
if [ -n "${FIRST_USER_PASS:-}" ]; then
    echo "sdr:${FIRST_USER_PASS}" | chpasswd
fi

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