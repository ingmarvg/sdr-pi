#!/bin/bash -e
# pi-gen stage: install SDR tools from source.
# This runs inside the pi-gen chroot during image build.
#
# Build acceleration:
#   - eatmydata: skips fsync() calls (expensive under QEMU emulation)
#   - ccache: caches compiled objects across rebuilds (mount /ccache from host)
#   - Parallel builds: rtl_433 + dump1090 compile concurrently after librtlsdr

on_chroot <<'CHROOT'
set -euo pipefail

# ── Build acceleration ────────────────────────────────────────────────────
# eatmydata: disable fsync() — QEMU emulates it slowly.
apt-get install -y eatmydata
EATMYDATA="eatmydata"

# ccache: reuse compiled objects across rebuilds.
# The build script mounts a host volume at /ccache if available.
$EATMYDATA apt-get install -y ccache
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
$EATMYDATA apt-get install -y --no-install-recommends \
    git libusb-1.0-0-dev cmake build-essential pkg-config \
    gnuradio gnuradio-dev libboost-all-dev libcppunit-dev swig \
    python3-numpy python3-waitress python3-requests \
    hostapd dnsmasq

# ── Build librtlsdr (dependency for rtl_433 and dump1090) ────────────────
cd /tmp
git clone --branch v2.0.2 --depth 1 https://gitea.osmocom.org/sdr/rtl-sdr.git
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
    cd /tmp
    git clone --branch 24.10 --depth 1 https://github.com/merbanan/rtl_433.git
    cd rtl_433 && mkdir build && cd build
    cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_C_FLAGS="$SDR_PI_CFLAGS" -DCMAKE_CXX_FLAGS="$SDR_PI_CFLAGS"
    make -j"$(( $(nproc) / 3 + 1 ))" && make install
    cd /tmp && rm -rf rtl_433
}

build_dump1090() {
    cd /tmp
    git clone --branch v1.14 --depth 1 https://github.com/mutability/dump1090.git dump1090-src
    cd dump1090-src
    make -j"$(( $(nproc) / 3 + 1 ))" CFLAGS="$SDR_PI_CFLAGS"
    cp dump1090 /usr/local/bin/dump1090-mutability
    chmod 755 /usr/local/bin/dump1090-mutability
    cd /tmp && rm -rf dump1090-src
}

build_op25() {
    cd /tmp
    git clone https://github.com/boatbod/op25.git
    cd op25 && git checkout 5dfc043
    cd op25/gr-op25_repeater && mkdir build && cd build
    cmake .. -DCMAKE_C_FLAGS="$SDR_PI_CFLAGS" -DCMAKE_CXX_FLAGS="$SDR_PI_CFLAGS"
    make -j"$(( $(nproc) / 3 + 1 ))" && make install && ldconfig
    cp -r /tmp/op25/op25/gr-op25_repeater/apps /opt/op25
    ln -sf /opt/op25/rx.py /usr/local/bin/rx.py
    cd /tmp && rm -rf op25
}

# Export so subshells can use them.
export SDR_PI_CFLAGS
export -f build_rtl433 build_dump1090 build_op25

echo ">>> Building rtl_433, dump1090, and OP25 in parallel..."
build_rtl433 &
PID_RTL433=$!
build_dump1090 &
PID_DUMP1090=$!
build_op25 &
PID_OP25=$!

# Wait for all three and fail if any failed.
FAILED=0
wait $PID_RTL433  || { echo "ERROR: rtl_433 build failed" >&2; FAILED=1; }
wait $PID_DUMP1090 || { echo "ERROR: dump1090 build failed" >&2; FAILED=1; }
wait $PID_OP25    || { echo "ERROR: OP25 build failed" >&2; FAILED=1; }

if [ "$FAILED" -ne 0 ]; then
    exit 1
fi

# Print ccache stats if active.
if [ -d /ccache ]; then
    echo ">>> ccache stats:"
    ccache --show-stats
fi
CHROOT
