#!/usr/bin/env bash
# Build and install rtl_433 from source.
set -euo pipefail

# Pin to a known-good release for reproducible builds.
RTL433_VERSION="24.10"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Error: This script must be run as root (use sudo)." >&2
    exit 1
fi

if command -v rtl_433 &>/dev/null; then
    echo ">>> rtl_433 already installed ($(rtl_433 -V 2>&1 | head -1 || true)), skipping."
    echo "    To reinstall, remove /usr/local/bin/rtl_433 first."
    exit 0
fi

BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

echo ">>> Installing rtl_433 build dependencies..."
apt-get install -y cmake build-essential libusb-1.0-0-dev

echo ">>> Cloning rtl_433 ${RTL433_VERSION}..."
git clone --branch "$RTL433_VERSION" --depth 1 \
    https://github.com/merbanan/rtl_433.git "${BUILD_DIR}/rtl_433"

# ARM-optimized build flags for SDR DSP performance.
SDR_PI_CFLAGS="-O2 -ftree-vectorize -ffast-math"
if [[ "$(uname -m)" == "aarch64" ]]; then
    SDR_PI_CFLAGS+=" -mcpu=native"
elif [[ "$(uname -m)" == "armv7l" ]]; then
    SDR_PI_CFLAGS+=" -mcpu=native -mfpu=neon-vfpv4 -mfloat-abi=hard"
fi

echo ">>> Building rtl_433..."
cd "${BUILD_DIR}/rtl_433"
mkdir build && cd build
cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DCMAKE_C_FLAGS="$SDR_PI_CFLAGS" -DCMAKE_CXX_FLAGS="$SDR_PI_CFLAGS"
make -j"$(nproc)"
make install

echo ">>> rtl_433 installed: $(rtl_433 -V 2>&1 | head -1)"