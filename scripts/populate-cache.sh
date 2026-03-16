#!/usr/bin/env bash
# Pre-download all source code into a persistent Docker volume.
# This eliminates network dependencies during builds and avoids rate limiting.
#
# The cache volume (sdr-pi-source-cache) persists across builds and container
# removals.  Run this once before your first build, and again if you bump
# any upstream version tags.
#
# Usage: bash scripts/populate-cache.sh
set -euo pipefail

CACHE_VOLUME="sdr-pi-source-cache"
CACHE_MOUNT="/source-cache"

# All git repos used by the build, with their pinned tags.
declare -A GIT_REPOS=(
    [rtl-sdr]="https://gitea.osmocom.org/sdr/rtl-sdr.git|v2.0.2"
    [rtl_433]="https://github.com/merbanan/rtl_433.git|24.10"
    [dump1090]="https://github.com/mutability/dump1090.git|v1.14"
    [lora_gateway]="https://github.com/Lora-net/lora_gateway.git|v5.0.1"
    [packet_forwarder]="https://github.com/Lora-net/packet_forwarder.git|v4.0.1"
    [hackrf]="https://github.com/greatscottgadgets/hackrf.git|v2024.02.1"
    [SoapySDR]="https://github.com/pothosware/SoapySDR.git|soapy-sdr-0.8.1"
    [SoapyHackRF]="https://github.com/pothosware/SoapyHackRF.git|soapy-hackrf-0.3.4"
)

# Tarballs (URL|filename).
OP25_COMMIT="0f0116572f837fe8fc326c1f4f89e6c435b1823d"
declare -A TARBALLS=(
    [op25.tar.gz]="https://github.com/boatbod/op25/archive/${OP25_COMMIT}.tar.gz"
)

echo ">>> Source cache: ${CACHE_VOLUME}"

# Create the volume if it doesn't exist.
if ! docker volume inspect "$CACHE_VOLUME" &>/dev/null; then
    echo ">>> Creating Docker volume ${CACHE_VOLUME}..."
    docker volume create "$CACHE_VOLUME"
fi

# Run a lightweight container to populate the cache.
# Alpine has git and wget, which is all we need.
CONTAINER="sdr-pi-cache-populator"
docker rm -f "$CONTAINER" 2>/dev/null || true

echo ">>> Starting cache populator..."
docker run -d --name "$CONTAINER" \
    -v "${CACHE_VOLUME}:${CACHE_MOUNT}" \
    alpine:latest sleep 600

# Install git inside the container.
docker exec "$CONTAINER" apk add --no-cache git >/dev/null 2>&1

# Clone or update bare git mirrors.
for name in "${!GIT_REPOS[@]}"; do
    IFS='|' read -r url tag <<< "${GIT_REPOS[$name]}"
    bare_path="${CACHE_MOUNT}/git/${name}.git"

    if docker exec "$CONTAINER" test -d "$bare_path" 2>/dev/null; then
        echo ">>> Updating ${name} (${tag})..."
        docker exec "$CONTAINER" git -C "$bare_path" fetch --all --prune 2>&1 | tail -1 || true
    else
        echo ">>> Cloning ${name} (${tag})..."
        docker exec "$CONTAINER" mkdir -p "${CACHE_MOUNT}/git"
        docker exec "$CONTAINER" git clone --bare "$url" "$bare_path"
    fi
done

# Download tarballs.
for filename in "${!TARBALLS[@]}"; do
    url="${TARBALLS[$filename]}"
    tarball_path="${CACHE_MOUNT}/tarballs/${filename}"

    if docker exec "$CONTAINER" test -f "$tarball_path" 2>/dev/null; then
        echo ">>> Cached: ${filename}"
    else
        echo ">>> Downloading ${filename}..."
        docker exec "$CONTAINER" mkdir -p "${CACHE_MOUNT}/tarballs"
        docker exec "$CONTAINER" wget -q -O "$tarball_path" "$url"
    fi
done

# Show cache contents.
echo ""
echo ">>> Cache contents:"
docker exec "$CONTAINER" sh -c "du -sh ${CACHE_MOUNT}/git/* ${CACHE_MOUNT}/tarballs/* 2>/dev/null" || true

# Cleanup.
docker rm -f "$CONTAINER" >/dev/null

echo ""
echo ">>> Source cache populated. The volume '${CACHE_VOLUME}' persists across builds."
echo "    To refresh: bash scripts/populate-cache.sh"
echo "    To wipe:    docker volume rm ${CACHE_VOLUME}"
