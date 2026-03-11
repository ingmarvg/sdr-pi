#!/usr/bin/env bash
# Build a complete sdr-pi Raspberry Pi OS image using pi-gen in Docker.
#
# Prerequisites:
#   - Docker installed and running
#   - ~10 GB free disk space
#
# Usage: ./scripts/build-image.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if ! command -v docker &>/dev/null; then
    echo "Error: Docker is required but not installed." >&2
    exit 1
fi

if ! docker info &>/dev/null; then
    echo "Error: Docker daemon is not running." >&2
    exit 1
fi

# ── Clone pi-gen if needed ───────────────────────────────────────────────────
PIGEN_DIR="${PROJECT_DIR}/build/pi-gen"
if [[ ! -d "$PIGEN_DIR" ]]; then
    echo ">>> Cloning pi-gen..."
    mkdir -p "${PROJECT_DIR}/build"
    git clone --depth 1 https://github.com/RPi-Distro/pi-gen.git "$PIGEN_DIR"
fi

# ── Write pi-gen config ─────────────────────────────────────────────────────
cat > "${PIGEN_DIR}/config" <<EOF
IMG_NAME=sdr-pi
RELEASE=bookworm
TARGET_HOSTNAME=sdr-pi
FIRST_USER_NAME=sdr
FIRST_USER_PASSWD=${SDR_PI_SSH_PASSWORD:-sdr}
ENABLE_SSH=1
LOCALE_DEFAULT=en_US.UTF-8
KEYBOARD_KEYMAP=us
TIMEZONE_DEFAULT=UTC
# Skip desktop stages (3–5) — headless only.
STAGE_LIST="stage0 stage1 stage2 stage-sdr-pi"
EOF

# ── Copy our custom stage into pi-gen ─────────────────────────────────────────
# Must be a real copy (not symlink) because Docker COPY won't follow symlinks
# that point outside the build context.
rm -rf "${PIGEN_DIR}/stage-sdr-pi"
cp -r "${PROJECT_DIR}/pi-gen-stage" "${PIGEN_DIR}/stage-sdr-pi"

# ── Populate the pi-gen files/ directory for the configure stage ─────────────
STAGE_FILES="${PIGEN_DIR}/stage-sdr-pi/01-configure-services/files"
mkdir -p "$STAGE_FILES"
# Use custom config if SDR_PI_CONF is set, otherwise use default.
cp "${SDR_PI_CONF:-${PROJECT_DIR}/sdr-pi.conf.default}" "${STAGE_FILES}/sdr-pi.conf"
cp "${PROJECT_DIR}/config/udev/99-rtlsdr.rules"       "${STAGE_FILES}/"
cp "${PROJECT_DIR}/config/systemd/"*.service           "${STAGE_FILES}/"
cp "${PROJECT_DIR}/scripts/sdr-pi-rtl433-wrapper"      "${STAGE_FILES}/"
cp "${PROJECT_DIR}/scripts/sdr-pi-dump1090-wrapper"    "${STAGE_FILES}/"
cp "${PROJECT_DIR}/scripts/sdr-pi-op25-wrapper"        "${STAGE_FILES}/"
cp "${PROJECT_DIR}/scripts/sdr-pi-apply-config"        "${STAGE_FILES}/"
cp "${PROJECT_DIR}/scripts/sdr-pi-status"              "${STAGE_FILES}/"
cp "${PROJECT_DIR}/config/sysctl.d/99-sdr-pi.conf"    "${STAGE_FILES}/"
cp "${PROJECT_DIR}/config/modprobe.d/99-sdr-pi-usb.conf" "${STAGE_FILES}/"
cp "${PROJECT_DIR}/config/boot/config.txt.sdr-pi"     "${STAGE_FILES}/"

# Skip stages 3-5 (desktop and full environment — not needed for headless).
touch "${PIGEN_DIR}/stage3/SKIP" "${PIGEN_DIR}/stage4/SKIP" "${PIGEN_DIR}/stage5/SKIP"
touch "${PIGEN_DIR}/stage3/SKIP_IMAGES" "${PIGEN_DIR}/stage4/SKIP_IMAGES" "${PIGEN_DIR}/stage5/SKIP_IMAGES"

# ── Build ────────────────────────────────────────────────────────────────────
echo ">>> Starting pi-gen Docker build..."
cd "$PIGEN_DIR"
./build-docker.sh

# ── Copy output image ───────────────────────────────────────────────────────
mkdir -p "${PROJECT_DIR}/deploy"
IMG=$(find "${PIGEN_DIR}/deploy" -name "*.img" -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2-)

if [[ -n "$IMG" ]]; then
    DATE=$(date +%Y%m%d)
    DEST="${PROJECT_DIR}/deploy/sdr-pi-${DATE}.img"
    cp "$IMG" "$DEST"
    echo ""
    echo ">>> Image built successfully: ${DEST}"
    echo "    Size: $(du -h "$DEST" | cut -f1)"
else
    echo "Error: No .img file found in pi-gen deploy directory." >&2
    exit 1
fi