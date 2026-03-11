#!/bin/bash -e
# pi-gen stage: install SDR tools from source.
# This runs inside the pi-gen chroot during image build.

on_chroot <<'CHROOT'
set -euo pipefail

# ARM-optimized build flags for SDR DSP performance.
SDR_PI_CFLAGS="-O2 -ftree-vectorize -ffast-math"
if [ "$(uname -m)" = "aarch64" ]; then
    SDR_PI_CFLAGS="$SDR_PI_CFLAGS -mcpu=native"
elif [ "$(uname -m)" = "armv7l" ]; then
    SDR_PI_CFLAGS="$SDR_PI_CFLAGS -mcpu=native -mfpu=neon-vfpv4 -mfloat-abi=hard"
fi

# Build librtlsdr
apt-get install -y libusb-1.0-0-dev cmake build-essential pkg-config
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

# Build rtl_433
cd /tmp
git clone --branch 24.10 --depth 1 https://github.com/merbanan/rtl_433.git
cd rtl_433 && mkdir build && cd build
cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DCMAKE_C_FLAGS="$SDR_PI_CFLAGS" -DCMAKE_CXX_FLAGS="$SDR_PI_CFLAGS"
make -j"$(nproc)" && make install
cd /tmp && rm -rf rtl_433

# Build dump1090-mutability
apt-get install -y pkg-config
cd /tmp
git clone --branch v1.15 --depth 1 https://github.com/mutability/dump1090.git
cd dump1090
make -j"$(nproc)" CFLAGS="$SDR_PI_CFLAGS"
cp dump1090 /usr/local/bin/dump1090-mutability
chmod 755 /usr/local/bin/dump1090-mutability
cd /tmp && rm -rf dump1090

# Build OP25
apt-get install -y gnuradio gnuradio-dev libboost-all-dev libcppunit-dev swig \
    python3-numpy python3-waitress python3-requests
cd /tmp
git clone https://github.com/boatbod/op25.git
cd op25 && git checkout 5dfc043
cd op25/gr-op25_repeater && mkdir build && cd build
cmake .. -DCMAKE_C_FLAGS="$SDR_PI_CFLAGS" -DCMAKE_CXX_FLAGS="$SDR_PI_CFLAGS"
make -j"$(nproc)" && make install && ldconfig
cp -r /tmp/op25/op25/gr-op25_repeater/apps /opt/op25
ln -sf /opt/op25/rx.py /usr/local/bin/rx.py
cd /tmp && rm -rf op25

# Install network dependencies
apt-get install -y hostapd dnsmasq
CHROOT
