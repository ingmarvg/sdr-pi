#!/usr/bin/env bash
# Build and install librtlsdr from source.
set -euo pipefail

# Pin to a known-good version for reproducible builds.
RTL_SDR_VERSION="v2.0.2"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Error: This script must be run as root (use sudo)." >&2
    exit 1
fi

if command -v rtl_test &>/dev/null; then
    echo ">>> librtlsdr already installed ($(rtl_test -h 2>&1 | head -1 || true)), skipping."
    echo "    To reinstall, remove /usr/local/bin/rtl_test first."
    exit 0
fi

BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

echo ">>> Installing librtlsdr build dependencies..."
apt-get install -y libusb-1.0-0-dev cmake build-essential pkg-config

echo ">>> Cloning rtl-sdr ${RTL_SDR_VERSION}..."
git clone --branch "$RTL_SDR_VERSION" --depth 1 \
    https://gitea.osmocom.org/sdr/rtl-sdr.git "${BUILD_DIR}/rtl-sdr"

# ARM-optimized build flags for SDR DSP performance.
SDR_PI_CFLAGS="-O2 -ftree-vectorize -ffast-math"
if [[ "$(uname -m)" == "aarch64" ]]; then
    SDR_PI_CFLAGS+=" -mcpu=native"
elif [[ "$(uname -m)" == "armv7l" ]]; then
    SDR_PI_CFLAGS+=" -mcpu=native -mfpu=neon-vfpv4 -mfloat-abi=hard"
fi

echo ">>> Building librtlsdr..."
cd "${BUILD_DIR}/rtl-sdr"
mkdir build && cd build
cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local -DDETACH_KERNEL_DRIVER=ON \
    -DCMAKE_C_FLAGS="$SDR_PI_CFLAGS" -DCMAKE_CXX_FLAGS="$SDR_PI_CFLAGS"
make -j"$(nproc)"
make install
ldconfig

echo ">>> Blacklisting kernel DVB-T drivers..."
cat > /etc/modprobe.d/blacklist-rtlsdr.conf <<'MODPROBE'
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2830
MODPROBE

echo ">>> librtlsdr installed."