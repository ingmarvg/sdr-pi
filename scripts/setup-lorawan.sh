#!/usr/bin/env bash
# Build and install the Semtech LoRaWAN packet forwarder and lora_json_bridge.
set -euo pipefail

# Pin to known-good releases for reproducible builds.
LORAGW_VERSION="v5.0.1"
PKT_FWD_VERSION="v4.0.1"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Error: This script must be run as root (use sudo)." >&2
    exit 1
fi

if command -v lora_pkt_fwd &>/dev/null && command -v lora_json_bridge &>/dev/null; then
    echo ">>> LoRaWAN tools already installed, skipping."
    echo "    To reinstall, remove /usr/local/bin/lora_pkt_fwd first."
    exit 0
fi

BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

echo ">>> Installing LoRaWAN build dependencies..."
apt-get install -y build-essential

# ARM-optimized build flags.
SDR_PI_CFLAGS="-O2 -ftree-vectorize -ffast-math"
if [[ "$(uname -m)" == "aarch64" ]]; then
    SDR_PI_CFLAGS+=" -mcpu=native"
elif [[ "$(uname -m)" == "armv7l" ]]; then
    SDR_PI_CFLAGS+=" -mcpu=native -mfpu=neon-vfpv4 -mfloat-abi=hard"
fi

# ── Build libloragw + lora_pkt_fwd ────────────────────────────────────────
echo ">>> Cloning lora_gateway ${LORAGW_VERSION}..."
git clone --branch "$LORAGW_VERSION" --depth 1 \
    https://github.com/Lora-net/lora_gateway.git "${BUILD_DIR}/lora_gateway"

echo ">>> Cloning packet_forwarder ${PKT_FWD_VERSION}..."
git clone --branch "$PKT_FWD_VERSION" --depth 1 \
    https://github.com/Lora-net/packet_forwarder.git "${BUILD_DIR}/packet_forwarder"

# libloragw must be built first (packet_forwarder links against it).
echo ">>> Building libloragw..."
cd "${BUILD_DIR}/lora_gateway"
make -j"$(nproc)" CFLAGS="$SDR_PI_CFLAGS"

echo ">>> Building packet_forwarder..."
cd "${BUILD_DIR}/packet_forwarder"
# The packet_forwarder Makefile expects libloragw in ../lora_gateway.
make -j"$(nproc)" CFLAGS="$SDR_PI_CFLAGS"

cp lora_pkt_fwd/lora_pkt_fwd /usr/local/bin/
chmod 755 /usr/local/bin/lora_pkt_fwd

# ── Build lora_json_bridge ────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BRIDGE_SRC="${PROJECT_DIR}/src/lora_json_bridge.c"

if [[ ! -f "$BRIDGE_SRC" ]]; then
    echo "Error: ${BRIDGE_SRC} not found." >&2
    exit 1
fi

echo ">>> Building lora_json_bridge..."
gcc $SDR_PI_CFLAGS -Wall -Wextra -o /usr/local/bin/lora_json_bridge "$BRIDGE_SRC"
chmod 755 /usr/local/bin/lora_json_bridge

# ── Install default configuration ─────────────────────────────────────────
mkdir -p /etc/sdr-pi/lorawan
for region in us915 eu868; do
    SRC="${PROJECT_DIR}/config/lorawan/global_conf.${region}.json"
    if [[ -f "$SRC" ]]; then
        cp "$SRC" "/etc/sdr-pi/lorawan/"
    fi
done

echo ">>> LoRaWAN tools installed."
echo "    lora_pkt_fwd:     $(lora_pkt_fwd --help 2>&1 | head -1 || echo 'installed')"
echo "    lora_json_bridge: installed"
