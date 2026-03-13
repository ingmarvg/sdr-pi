#!/bin/bash -e
# pi-gen stage: install SDR tools from source.
# This runs inside the pi-gen chroot during image build.
#
# Build acceleration:
#   - eatmydata: skips fsync() calls (expensive under QEMU emulation)
#   - ccache: caches compiled objects across rebuilds (mount /ccache from host)
#   - Parallel builds: rtl_433 + dump1090 + OP25 + lorawan compile concurrently
#
# Resilience:
#   - retry(): retries transient failures with exponential backoff
#   - apt_update_strict(): catches partial apt-get update failures
#   - git_clone_retry(): retries git clones with cleanup between attempts

# Stage lora_json_bridge source into the chroot's /tmp for the build.
STAGE_DIR="$(dirname "$0")"
if [ -f "${STAGE_DIR}/../01-configure-services/files/lora_json_bridge.c" ]; then
    cp "${STAGE_DIR}/../01-configure-services/files/lora_json_bridge.c" \
        "${ROOTFS_DIR}/tmp/lora_json_bridge.c"
fi

on_chroot <<'CHROOT'
set -euo pipefail

# ── Retry helpers ────────────────────────────────────────────────────────

# Retry a command with exponential backoff.
# Usage: retry <max_attempts> <description> <command...>
retry() {
    local max="$1" desc="$2"; shift 2
    local attempt delay
    for attempt in $(seq 1 "$max"); do
        if "$@"; then
            return 0
        fi
        if [ "$attempt" -eq "$max" ]; then
            echo "ERROR: ${desc} failed after ${max} attempts" >&2
            return 1
        fi
        delay=$(( 5 * (2 ** (attempt - 1)) ))
        echo ">>> ${desc} failed (attempt ${attempt}/${max}), retrying in ${delay}s..." >&2
        sleep "$delay"
    done
}

# apt-get update that fails on partial repo failures.
# By default, apt-get update exits 0 even when some repos return errors
# (e.g. 503 from a proxy).  This wrapper checks the output for error
# indicators and returns non-zero so retry() can catch it.
apt_update_strict() {
    local output rc
    output=$(apt-get update 2>&1) && rc=0 || rc=$?
    echo "$output"
    if [ "$rc" -ne 0 ]; then
        return 1
    fi
    if echo "$output" | grep -qE '^(Err:|W: Failed to fetch|E: )'; then
        echo "ERROR: apt-get update had partial failures" >&2
        return 1
    fi
    return 0
}

# Git clone with retry and cleanup of partial clones between attempts.
# Usage: git_clone_retry [git clone args...] <dest_directory>
git_clone_retry() {
    local max_attempts=3
    local dest="${!#}"  # last argument = destination directory
    local attempt delay
    for attempt in $(seq 1 "$max_attempts"); do
        if git clone "$@"; then
            return 0
        fi
        if [ "$attempt" -lt "$max_attempts" ]; then
            delay=$(( 5 * (2 ** (attempt - 1)) ))
            echo ">>> git clone failed (attempt ${attempt}/${max_attempts}), retrying in ${delay}s..." >&2
            rm -rf "$dest"
            sleep "$delay"
        fi
    done
    echo "ERROR: git clone failed after ${max_attempts} attempts" >&2
    return 1
}

# ── Build acceleration ────────────────────────────────────────────────────
# eatmydata: disable fsync() — QEMU emulates it slowly.
retry 3 "apt-get update" apt_update_strict
retry 3 "install eatmydata" apt-get install -y -o Acquire::Retries=5 eatmydata
EATMYDATA="eatmydata"

# ccache: reuse compiled objects across rebuilds.
# The build script mounts a host volume at /ccache if available.
retry 3 "install ccache" $EATMYDATA apt-get install -y -o Acquire::Retries=5 ccache
if [ -d /ccache ]; then
    export CCACHE_DIR=/ccache
    export CCACHE_MAXSIZE=2G
    export PATH="/usr/lib/ccache:$PATH"
    echo ">>> ccache enabled (CCACHE_DIR=/ccache)"
    ccache --zero-stats
else
    echo ">>> ccache installed but no /ccache volume — caching disabled"
fi

# ARM-optimized build flags for SDR DSP performance.
# Use explicit CPU target instead of -mcpu=native (which fails under QEMU emulation).
SDR_PI_CFLAGS="-O2 -ftree-vectorize -ffast-math"
if [ "$(uname -m)" = "aarch64" ]; then
    SDR_PI_CFLAGS="$SDR_PI_CFLAGS -mcpu=cortex-a72"
elif [ "$(uname -m)" = "armv7l" ]; then
    SDR_PI_CFLAGS="$SDR_PI_CFLAGS -mcpu=cortex-a7 -mfpu=neon-vfpv4 -mfloat-abi=hard"
fi

# ── Install build dependencies ────────────────────────────────────────────
# Split into core deps (rtl_433, dump1090, lorawan) and OP25 deps (gnuradio).
# This way, a gnuradio download failure doesn't block the other builds.
# Acquire::Retries makes apt retry individual failed package downloads.
APT_RETRY="-o Acquire::Retries=5"

retry 3 "install core build deps" \
    $EATMYDATA apt-get install -y $APT_RETRY --no-install-recommends \
    git libusb-1.0-0-dev cmake build-essential pkg-config \
    hostapd dnsmasq

# OP25 requires gnuradio (~200 MB of packages).  Install separately so
# failure here doesn't block rtl_433, dump1090, or lorawan.
OP25_DEPS_OK=1
if ! retry 3 "install OP25 deps (gnuradio)" \
    $EATMYDATA apt-get install -y $APT_RETRY --no-install-recommends \
    gnuradio gnuradio-dev libboost-all-dev libcppunit-dev swig \
    python3-numpy python3-waitress python3-requests; then
    echo "WARNING: OP25 dependencies failed to install — OP25 build will be skipped." >&2
    OP25_DEPS_OK=0
fi

# ── Build librtlsdr (dependency for rtl_433 and dump1090) ────────────────
cd /tmp
git_clone_retry --branch v2.0.2 --depth 1 https://gitea.osmocom.org/sdr/rtl-sdr.git rtl-sdr
cd rtl-sdr && mkdir build && cd build
cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local -DDETACH_KERNEL_DRIVER=ON \
    -DCMAKE_C_FLAGS="$SDR_PI_CFLAGS" -DCMAKE_CXX_FLAGS="$SDR_PI_CFLAGS"
make -j"$(nproc)" && make install && ldconfig
cd /tmp && rm -rf rtl-sdr

cat > /etc/modprobe.d/blacklist-rtlsdr.conf <<'MOD'
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2830
MOD

# ── Build rtl_433, dump1090, OP25, and LoRaWAN in parallel ────────────────
# librtlsdr is installed; the remaining four are independent of each other.

build_rtl433() {
    cd /tmp \
    && git_clone_retry --branch 24.10 --depth 1 https://github.com/merbanan/rtl_433.git rtl_433 \
    && cd rtl_433 && mkdir build && cd build \
    && cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_C_FLAGS="$SDR_PI_CFLAGS" -DCMAKE_CXX_FLAGS="$SDR_PI_CFLAGS" \
    && make -j"$(( $(nproc) / 4 + 1 ))" && make install \
    && cd /tmp && rm -rf rtl_433
}

build_dump1090() {
    cd /tmp \
    && git_clone_retry --branch v1.14 --depth 1 https://github.com/mutability/dump1090.git dump1090-src \
    && cd dump1090-src \
    && make -j"$(( $(nproc) / 4 + 1 ))" CFLAGS="$SDR_PI_CFLAGS -fcommon" \
    && cp dump1090 /usr/local/bin/dump1090-mutability \
    && chmod 755 /usr/local/bin/dump1090-mutability \
    && cd /tmp && rm -rf dump1090-src
}

build_op25() {
    local OP25_COMMIT="0f0116572f837fe8fc326c1f4f89e6c435b1823d"
    local OP25_URL="https://github.com/boatbod/op25/archive/${OP25_COMMIT}.tar.gz"
    cd /tmp \
    && retry 3 "OP25 download" wget -q --timeout=30 -O op25.tar.gz "$OP25_URL" \
    && mkdir op25 && tar xzf op25.tar.gz -C op25 --strip-components=1 && rm op25.tar.gz \
    && cd op25/op25/gr-op25_repeater && mkdir build && cd build \
    && cmake .. -DCMAKE_C_FLAGS="$SDR_PI_CFLAGS" -DCMAKE_CXX_FLAGS="$SDR_PI_CFLAGS" \
    && make -j"$(( $(nproc) / 4 + 1 ))" && make install && ldconfig \
    && cp -r /tmp/op25/op25/gr-op25_repeater/apps /opt/op25 \
    && ln -sf /opt/op25/rx.py /usr/local/bin/rx.py \
    && cd /tmp && rm -rf op25
}

build_lorawan() {
    # lora_gateway and packet_forwarder use CFLAGS := ... with -Iinc -I.
    # in their Makefiles.  Do NOT override CFLAGS on the command line or
    # the include paths are lost and headers won't be found.
    cd /tmp \
    && git_clone_retry --branch v5.0.1 --depth 1 \
        https://github.com/Lora-net/lora_gateway.git lora_gateway \
    && cd lora_gateway \
    && make -j"$(( $(nproc) / 4 + 1 ))" \
    && cd /tmp \
    && git_clone_retry --branch v4.0.1 --depth 1 \
        https://github.com/Lora-net/packet_forwarder.git packet_forwarder \
    && cd packet_forwarder \
    && make -j"$(( $(nproc) / 4 + 1 ))" \
    && cp lora_pkt_fwd/lora_pkt_fwd /usr/local/bin/ \
    && chmod 755 /usr/local/bin/lora_pkt_fwd \
    && cd /tmp && rm -rf lora_gateway packet_forwarder \
    && gcc $SDR_PI_CFLAGS -Wall -Wextra \
        -o /usr/local/bin/lora_json_bridge \
        /tmp/lora_json_bridge.c \
    && chmod 755 /usr/local/bin/lora_json_bridge
}

# Export so subshells can use them.
export SDR_PI_CFLAGS OP25_DEPS_OK
export -f retry git_clone_retry
export -f build_rtl433 build_dump1090 build_op25 build_lorawan

echo ">>> Building rtl_433, dump1090, OP25, and LoRaWAN in parallel..."
retry 2 "rtl_433 build" build_rtl433 &
PID_RTL433=$!
retry 2 "dump1090 build" build_dump1090 &
PID_DUMP1090=$!
retry 2 "lorawan build" build_lorawan &
PID_LORAWAN=$!

# OP25 is optional — skip if gnuradio deps failed to install.
PID_OP25=""
if [ "$OP25_DEPS_OK" -eq 1 ]; then
    retry 2 "OP25 build" build_op25 &
    PID_OP25=$!
else
    echo ">>> Skipping OP25 build (dependencies unavailable)"
fi

# Wait for builds — core builds are required, OP25 is best-effort.
FAILED=0
wait $PID_RTL433  || { echo "ERROR: rtl_433 build failed after retries" >&2; FAILED=1; }
wait $PID_DUMP1090 || { echo "ERROR: dump1090 build failed after retries" >&2; FAILED=1; }
wait $PID_LORAWAN || { echo "ERROR: lorawan build failed after retries" >&2; FAILED=1; }

if [ -n "$PID_OP25" ]; then
    wait $PID_OP25 || { echo "WARNING: OP25 build failed — image will work without P25 support." >&2; }
fi

if [ "$FAILED" -ne 0 ]; then
    exit 1
fi

# Print ccache stats if active.
if [ -d /ccache ]; then
    echo ">>> ccache stats:"
    ccache --show-stats
fi
CHROOT
