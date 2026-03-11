#!/usr/bin/env bash
# Build and install dump1090-mutability from source.
# Requires librtlsdr — run setup-rtl-sdr.sh first.
set -euo pipefail

# Pin to a known-good version for reproducible builds.
DUMP1090_VERSION="v1.15"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Error: This script must be run as root (use sudo)." >&2
    exit 1
fi

if command -v dump1090-mutability &>/dev/null; then
    echo ">>> dump1090-mutability already installed, skipping."
    echo "    To reinstall, remove /usr/local/bin/dump1090-mutability first."
    exit 0
fi

# Verify librtlsdr is installed (from setup-rtl-sdr.sh, not the distro package).
if ! pkg-config --exists librtlsdr 2>/dev/null; then
    echo "Error: librtlsdr not found. Run setup-rtl-sdr.sh first." >&2
    exit 1
fi

BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

echo ">>> Installing dump1090 build dependencies..."
apt-get install -y build-essential pkg-config

echo ">>> Cloning dump1090-mutability ${DUMP1090_VERSION}..."
git clone --branch "$DUMP1090_VERSION" --depth 1 \
    https://github.com/mutability/dump1090.git "${BUILD_DIR}/dump1090"

# ARM-optimized build flags for SDR DSP performance.
# Enables the NEON demodulator path in dump1090 (__ARM_NEON__).
SDR_PI_CFLAGS="-O2 -ftree-vectorize -ffast-math"
if [[ "$(uname -m)" == "aarch64" ]]; then
    SDR_PI_CFLAGS+=" -mcpu=native"
elif [[ "$(uname -m)" == "armv7l" ]]; then
    SDR_PI_CFLAGS+=" -mcpu=native -mfpu=neon-vfpv4 -mfloat-abi=hard"
fi

echo ">>> Building dump1090..."
cd "${BUILD_DIR}/dump1090"
make -j"$(nproc)" CFLAGS="$SDR_PI_CFLAGS"

echo ">>> Installing dump1090..."
cp dump1090 /usr/local/bin/dump1090-mutability
chmod 755 /usr/local/bin/dump1090-mutability

echo ">>> dump1090-mutability installed."