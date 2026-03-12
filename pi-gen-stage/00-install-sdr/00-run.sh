#!/bin/bash -e
# pi-gen stage: install SDR tools from source.
# This runs inside the pi-gen chroot during image build.
#
# Build acceleration:
#   - eatmydata: skips fsync() calls (expensive under QEMU emulation)
#   - ccache: caches compiled objects across rebuilds (mount /ccache from host)
#   - Parallel builds: rtl_433 + dump1090 compile concurrently after librtlsdr
#
# Resilience:
#   - retry(): retries transient failures with exponential backoff
#   - apt_update_strict(): catches partial apt-get update failures
#   - git_clone_retry(): retries git clones with cleanup between attempts

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
retry 3 "install eatmydata" apt-get install -y eatmydata
EATMYDATA="eatmydata"

# ccache: reuse compiled objects across rebuilds.
# The build script mounts a host volume at /ccache if available.
retry 3 "install ccache" $EATMYDATA apt-get install -y ccache
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

# ── Install build dependencies up front ───────────────────────────────────
retry 3 "install build dependencies" $EATMYDATA apt-get install -y --no-install-recommends \
    git libusb-1.0-0-dev cmake build-essential pkg-config \
    gnuradio gnuradio-dev libboost-all-dev libcppunit-dev swig \
    python3-numpy python3-waitress python3-requests \
    hostapd dnsmasq

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

# ── Build rtl_433, dump1090, and OP25 in parallel ────────────────────────
# librtlsdr is installed; the remaining three are independent of each other.

build_rtl433() {
    cd /tmp \
    && git_clone_retry --branch 24.10 --depth 1 https://github.com/merbanan/rtl_433.git rtl_433 \
    && cd rtl_433 && mkdir build && cd build \
    && cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_C_FLAGS="$SDR_PI_CFLAGS" -DCMAKE_CXX_FLAGS="$SDR_PI_CFLAGS" \
    && make -j"$(( $(nproc) / 3 + 1 ))" && make install \
    && cd /tmp && rm -rf rtl_433
}

build_dump1090() {
    cd /tmp \
    && git_clone_retry --branch v1.14 --depth 1 https://github.com/mutability/dump1090.git dump1090-src \
    && cd dump1090-src \
    && make -j"$(( $(nproc) / 3 + 1 ))" CFLAGS="$SDR_PI_CFLAGS -fcommon" \
    && cp dump1090 /usr/local/bin/dump1090-mutability \
    && chmod 755 /usr/local/bin/dump1090-mutability \
    && cd /tmp && rm -rf dump1090-src
}

build_op25() {
    local OP25_COMMIT="5dfc043"
    local OP25_URL="https://github.com/boatbod/op25/archive/${OP25_COMMIT}.tar.gz"
    cd /tmp \
    && retry 3 "OP25 download" wget -q --timeout=30 -O op25.tar.gz "$OP25_URL" \
    && mkdir op25 && tar xzf op25.tar.gz -C op25 --strip-components=1 && rm op25.tar.gz \
    && cd op25/op25/gr-op25_repeater && mkdir build && cd build \
    && cmake .. -DCMAKE_C_FLAGS="$SDR_PI_CFLAGS" -DCMAKE_CXX_FLAGS="$SDR_PI_CFLAGS" \
    && make -j"$(( $(nproc) / 3 + 1 ))" && make install && ldconfig \
    && cp -r /tmp/op25/op25/gr-op25_repeater/apps /opt/op25 \
    && ln -sf /opt/op25/rx.py /usr/local/bin/rx.py \
    && cd /tmp && rm -rf op25
}

# Export so subshells can use them.
export SDR_PI_CFLAGS
export -f retry git_clone_retry
export -f build_rtl433 build_dump1090 build_op25

echo ">>> Building rtl_433, dump1090, and OP25 in parallel..."
retry 2 "rtl_433 build" build_rtl433 &
PID_RTL433=$!
retry 2 "dump1090 build" build_dump1090 &
PID_DUMP1090=$!
retry 2 "OP25 build" build_op25 &
PID_OP25=$!

# Wait for all three and fail if any failed.
FAILED=0
wait $PID_RTL433  || { echo "ERROR: rtl_433 build failed after retries" >&2; FAILED=1; }
wait $PID_DUMP1090 || { echo "ERROR: dump1090 build failed after retries" >&2; FAILED=1; }
wait $PID_OP25    || { echo "ERROR: OP25 build failed after retries" >&2; FAILED=1; }

if [ "$FAILED" -ne 0 ]; then
    exit 1
fi

# Print ccache stats if active.
if [ -d /ccache ]; then
    echo ">>> ccache stats:"
    ccache --show-stats
fi
CHROOT
