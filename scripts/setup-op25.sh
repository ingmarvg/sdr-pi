#!/usr/bin/env bash
# Build and install OP25 from source.
# Requires librtlsdr — run setup-rtl-sdr.sh first.
set -euo pipefail

# Pin to a known-good commit for reproducible builds.
# OP25 does not publish tagged releases.
OP25_COMMIT="5dfc043"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Error: This script must be run as root (use sudo)." >&2
    exit 1
fi

if command -v rx.py &>/dev/null; then
    echo ">>> OP25 already installed, skipping."
    echo "    To reinstall, remove /usr/local/bin/rx.py and /opt/op25 first."
    exit 0
fi

BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

echo ">>> Installing OP25 build dependencies..."
apt-get install -y build-essential cmake libusb-1.0-0-dev \
    gnuradio gnuradio-dev libboost-all-dev libcppunit-dev swig \
    python3-numpy python3-waitress python3-requests

echo ">>> Cloning OP25 (${OP25_COMMIT})..."
git clone https://github.com/boatbod/op25.git "${BUILD_DIR}/op25"
cd "${BUILD_DIR}/op25"
git checkout "$OP25_COMMIT"

# ARM-optimized build flags for SDR DSP performance.
SDR_PI_CFLAGS="-O2 -ftree-vectorize -ffast-math"
if [[ "$(uname -m)" == "aarch64" ]]; then
    SDR_PI_CFLAGS+=" -mcpu=native"
elif [[ "$(uname -m)" == "armv7l" ]]; then
    SDR_PI_CFLAGS+=" -mcpu=native -mfpu=neon-vfpv4 -mfloat-abi=hard"
fi

echo ">>> Building OP25..."
cd op25/gr-op25_repeater
mkdir build && cd build
cmake .. -DCMAKE_C_FLAGS="$SDR_PI_CFLAGS" -DCMAKE_CXX_FLAGS="$SDR_PI_CFLAGS"
make -j"$(nproc)"
make install
ldconfig

echo ">>> Installing OP25 apps..."
cp -r "${BUILD_DIR}/op25/op25/gr-op25_repeater/apps" /opt/op25
ln -sf /opt/op25/rx.py /usr/local/bin/rx.py

echo ">>> OP25 installed."