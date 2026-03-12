#!/usr/bin/env bash
# Build a complete sdr-pi Raspberry Pi OS image using pi-gen in Docker.
#
# Prerequisites:
#   - Docker installed and running
#   - ~10 GB free disk space
#
# Environment variables:
#   SDR_PI_CONF            Path to custom sdr-pi.conf (default: sdr-pi.conf.default)
#   SDR_PI_SSH_PASSWORD     SSH password for sdr user (default: sdr)
#   SDR_PI_APT_CACHE        apt-cacher-ng URL, or "none" to disable (default: auto)
#   SDR_PI_CONTINUE         Set to 1 to resume a previous build (skip completed stages)
#   SDR_PI_CLEAN            Set to 1 to wipe previous build state before starting
#   SDR_PI_RETRIES          Max automatic retries after failure (default: 2)
#   SDR_PI_SKIP_PREFLIGHT   Set to 1 to skip preflight checks
#
# Build acceleration:
#   - QEMU binfmt_misc registered automatically for ARM user-mode emulation
#   - ccache volume mounted at /ccache (persisted in build/ccache/)
#   - eatmydata disables fsync() inside the chroot (expensive under QEMU)
#   - rtl_433, dump1090, and OP25 compile in parallel after librtlsdr
#   - --no-install-recommends reduces package count
#
# Resilience:
#   - Preflight checks verify DNS, mirrors, and disk space before building
#   - apt-cacher-ng health check with fallback to direct mirrors
#   - Automatic build retries with CONTINUE mode (skips completed stages)
#   - Retry helpers inside chroot for apt, git, and compilation
#
# Usage: ./scripts/build-image.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if ! command -v docker &>/dev/null; then
    echo "Error: Docker is required but not installed." >&2
    exit 1
fi

if ! docker info &>/dev/null; then
    echo "Error: Docker daemon is not running." >&2
    exit 1
fi

# ── Warn if running from NTFS (Windows) filesystem ──────────────────────────
# The Windows ↔ Linux filesystem bridge is extremely slow for I/O-heavy builds.
if [[ "$PROJECT_DIR" == /mnt/[a-z]/* ]]; then
    echo "WARNING: Project is on the Windows filesystem ($PROJECT_DIR)." >&2
    echo "         Build I/O will be up to 20x slower than on the Linux FS." >&2
    echo "         Consider cloning to ~/src/sdr-pi instead." >&2
    echo ""
fi

# ── Preflight checks ─────────────────────────────────────────────────────────
# Verify the build environment before spending time on setup.  Each check
# gives a clear, actionable error message.
preflight_checks() {
    local PREFLIGHT_FAILED=0

    # 1. Docker disk space — pi-gen needs ~8-10 GB of working space.
    echo ">>> Preflight: checking Docker disk space..."
    local DOCKER_FREE
    DOCKER_FREE=$(timeout 10 docker system df --format '{{.Size}}' 2>/dev/null | head -1 || true)
    if [[ -z "$DOCKER_FREE" ]]; then
        echo "    (skipped — could not query Docker disk usage)" >&2
    fi

    # 2. DNS resolution inside Docker.
    #    This catches the common WSL2 issue where Docker containers can't
    #    resolve hostnames.  Uses alpine (7 MB) for a fast check.
    echo ">>> Preflight: checking DNS resolution in Docker..."
    if ! timeout 30 docker run --rm --dns 8.8.8.8 alpine \
        sh -c 'nslookup raspbian.raspberrypi.com >/dev/null 2>&1' 2>/dev/null; then
        echo "ERROR: DNS resolution failed inside Docker containers." >&2
        echo "       Cannot resolve raspbian.raspberrypi.com." >&2
        echo "       Fixes to try:" >&2
        echo "         1. Restart Docker Desktop" >&2
        echo "         2. Add to Docker daemon config: \"dns\": [\"8.8.8.8\", \"8.8.4.4\"]" >&2
        echo "         3. On WSL2: echo 'nameserver 8.8.8.8' | sudo tee /etc/resolv.conf" >&2
        PREFLIGHT_FAILED=1
    fi

    # 3. Mirror reachability — warning only (may be transient, retries can help).
    echo ">>> Preflight: checking mirror connectivity..."
    for host in raspbian.raspberrypi.com archive.raspberrypi.com; do
        if ! timeout 20 docker run --rm --dns 8.8.8.8 alpine \
            sh -c "wget -q --spider --timeout=15 http://${host}/ 2>/dev/null" 2>/dev/null; then
            echo "WARNING: Cannot reach ${host} — build may fail during apt-get update." >&2
        fi
    done

    # 4. GitHub connectivity (needed for git clone inside chroot).
    echo ">>> Preflight: checking github.com connectivity..."
    if ! timeout 20 docker run --rm --dns 8.8.8.8 alpine \
        sh -c 'nslookup github.com >/dev/null 2>&1' 2>/dev/null; then
        echo "WARNING: Cannot resolve github.com — git clones may fail." >&2
    fi

    if [[ "$PREFLIGHT_FAILED" -ne 0 ]]; then
        echo "" >&2
        echo "Preflight checks failed. Fix the issues above and retry." >&2
        echo "To skip checks: SDR_PI_SKIP_PREFLIGHT=1 ./scripts/build-image.sh" >&2
        exit 1
    fi
    echo ">>> Preflight: all checks passed"
}

if [[ "${SDR_PI_SKIP_PREFLIGHT:-0}" != "1" ]]; then
    preflight_checks
fi

# ── QEMU binfmt_misc setup ────────────────────────────────────────────────
# Register QEMU user-mode emulation so the Docker container can run ARM
# binaries in the pi-gen chroot without a full VM.  This is a no-op if
# already registered (e.g. Docker Desktop on macOS/Windows).
if [[ "$(uname -m)" != "aarch64" ]]; then
    if ! docker run --rm --privileged tonistiigi/binfmt:latest --install arm64,arm 2>/dev/null; then
        echo "Warning: Could not register QEMU binfmt_misc handlers." >&2
        echo "         Cross-architecture builds may fail." >&2
    fi
fi

# ── Clone pi-gen (pinned to a known-good commit) ────────────────────────────
# Pinning avoids upstream changes breaking our patches.  To update, change the
# hash below, delete build/pi-gen, and rebuild.
PIGEN_DIR="${PROJECT_DIR}/build/pi-gen"
PIGEN_BRANCH="bookworm"
PIGEN_COMMIT="de9df5623109331cebf990578f342583d9138376"
if [[ ! -d "$PIGEN_DIR" ]]; then
    echo ">>> Cloning pi-gen (${PIGEN_BRANCH} @ ${PIGEN_COMMIT:0:7})..."
    mkdir -p "${PROJECT_DIR}/build"
    git clone --branch "$PIGEN_BRANCH" https://github.com/RPi-Distro/pi-gen.git "$PIGEN_DIR"
    git -C "$PIGEN_DIR" checkout "$PIGEN_COMMIT"
fi

# ── Patch pi-gen build-docker.sh ─────────────────────────────────────────────
# Fixes for WSL2 / Docker Desktop and native ARM builds:
#   1. DNS: use --network=host for `docker build` so it inherits the host's
#      /etc/resolv.conf.  BuildKit doesn't support --dns, but does --network.
#   2. binfmt: pi-gen checks for `qemu-arm` on the host, but on WSL2 + Docker
#      Desktop the binfmt handlers are registered inside the Docker VM (via
#      tonistiigi/binfmt) and aren't visible at /proc/sys/fs/binfmt_misc.
#      The container already runs `dpkg-reconfigure qemu-user-binfmt` so the
#      host-side check is unnecessary.
#   3. Base image: pi-gen uses i386/debian on aarch64, but that image has no
#      ARM manifest.  On native ARM, use debian:bookworm instead.
PIGEN_BUILD_DOCKER="${PIGEN_DIR}/build-docker.sh"
if ! grep -q 'sdr-pi-patched' "$PIGEN_BUILD_DOCKER" 2>/dev/null; then
    echo ">>> Patching pi-gen build-docker.sh (DNS + binfmt + ARM base image)..."
    # 1. Add --network=host to docker build (BuildKit doesn't support --dns)
    # shellcheck disable=SC2016
    sed -i 's|${DOCKER} build --build-arg|${DOCKER} build --network=host --build-arg|' "$PIGEN_BUILD_DOCKER"
    # 2. Skip host-side binfmt check — handled by tonistiigi/binfmt + container
    sed -i 's|binfmt_misc_required=1|binfmt_misc_required=0  # sdr-pi-patched|' "$PIGEN_BUILD_DOCKER"
    # 3. Fix base image for native ARM: i386/debian has no arm64 manifest.
    #    On aarch64, use debian:bookworm (native ARM) instead of i386/debian.
    sed -i 's|x86_64\|aarch64)|x86_64)  # sdr-pi-patched|' "$PIGEN_BUILD_DOCKER"
fi

# ── Clean previous build if requested ────────────────────────────────────────
if [[ "${SDR_PI_CLEAN:-0}" == "1" ]]; then
    echo ">>> Cleaning previous build state..."
    rm -rf "${PIGEN_DIR}/work" "${PIGEN_DIR}/deploy"
fi

# ── Write pi-gen config ─────────────────────────────────────────────────────
# Note: APT_PROXY is appended later by the apt cache section if the proxy
# passes health checks.  This avoids baking in a broken proxy URL.
cat > "${PIGEN_DIR}/config" <<EOF
IMG_NAME=sdr-pi
RELEASE=bookworm
TARGET_HOSTNAME=sdr-pi
FIRST_USER_NAME=sdr
FIRST_USER_PASSWD=${SDR_PI_SSH_PASSWORD:-sdr}
ENABLE_SSH=1
LOCALE_DEFAULT=en_US.UTF-8
KEYBOARD_KEYMAP=us
TIMEZONE_DEFAULT=UTC
# Skip desktop stages (3–5) — headless only.
STAGE_LIST="stage0 stage1 stage2 stage-sdr-pi"
EOF

# ── apt-cacher-ng ────────────────────────────────────────────────────────────
# Cache downloaded .deb packages locally so rebuilds and retries don't
# re-download ~500 MB from remote mirrors.  The cache container is started
# automatically and persists across builds.
#
# Override: set SDR_PI_APT_CACHE to point at an existing apt-cacher-ng
# instance (e.g. http://192.168.1.10:3142).  Set SDR_PI_APT_CACHE=none
# to disable caching entirely.

# Test that apt-cacher-ng is actually proxying requests, not just running.
# Returns 0 if healthy, 1 if unreachable.
# Uses curl/wget on the host first (fast), falls back to a Docker container
# test to verify in-container reachability.
apt_cache_health_check() {
    local proxy_url="$1"
    local max_attempts=3
    local attempt

    for attempt in $(seq 1 "$max_attempts"); do
        # Fast host-side check: verify the proxy port is responding.
        if curl -sf --max-time 5 -x "${proxy_url}" \
               http://deb.debian.org/debian/dists/bookworm/Release.gpg \
               -o /dev/null 2>/dev/null; then
            return 0
        elif wget -q --timeout=5 -e "http_proxy=${proxy_url}" \
               http://deb.debian.org/debian/dists/bookworm/Release.gpg \
               -O /dev/null 2>/dev/null; then
            return 0
        fi
        if [ "$attempt" -lt "$max_attempts" ]; then
            echo "    apt cache not ready (attempt ${attempt}/${max_attempts}), waiting..." >&2
            # Restart the container in case it's wedged.
            docker restart sdr-pi-apt-cache >/dev/null 2>&1 || true
            sleep $(( attempt * 3 ))
        fi
    done
    return 1
}

if [[ "${SDR_PI_APT_CACHE:-}" == "none" ]]; then
    echo ">>> apt cache: disabled"
elif [[ -n "${SDR_PI_APT_CACHE:-}" ]]; then
    echo ">>> Using apt cache: ${SDR_PI_APT_CACHE}"
    echo ">>> Verifying apt cache is proxying correctly..."
    if apt_cache_health_check "$SDR_PI_APT_CACHE"; then
        echo ">>> apt cache: verified working"
        echo "APT_PROXY=${SDR_PI_APT_CACHE}" >> "${PIGEN_DIR}/config"
    else
        echo "WARNING: apt cache at ${SDR_PI_APT_CACHE} is not responding." >&2
        echo "         Falling back to direct mirror access (no caching)." >&2
    fi
else
    # Auto-start a local apt-cacher-ng container if one isn't running.
    APT_CACHE_NAME="sdr-pi-apt-cache"
    if docker ps --filter name="${APT_CACHE_NAME}" --filter status=running -q | grep -q .; then
        echo ">>> apt cache: running (${APT_CACHE_NAME})"
    elif docker ps -a --filter name="${APT_CACHE_NAME}" -q | grep -q .; then
        echo ">>> Starting existing apt cache container..."
        docker start "${APT_CACHE_NAME}" >/dev/null
    else
        echo ">>> Starting apt cache (first time — will persist across builds)..."
        docker run -d -p 3142:3142 \
            --name "${APT_CACHE_NAME}" \
            --restart unless-stopped \
            -v sdr-pi-apt-cache:/var/cache/apt-cacher-ng \
            sameersbn/apt-cacher-ng >/dev/null
    fi
    # Disable apt-cacher-ng's Remap rules so it acts as a pure HTTP cache.
    # The default Remap-debrep rule catches all /debian URLs and redirects
    # them through its Debian backends, which breaks Raspberry Pi mirrors
    # (archive.raspberrypi.com/debian/ has different packages).
    if docker exec "${APT_CACHE_NAME}" sh -c 'grep -q "^Remap-debrep:" /etc/apt-cacher-ng/acng.conf' 2>/dev/null; then
        echo ">>> Configuring apt cache (disabling Remap rules for RPi compatibility)..."
        docker exec "${APT_CACHE_NAME}" sh -c "sed -i 's/^Remap-/#Remap-/' /etc/apt-cacher-ng/acng.conf"
        docker restart "${APT_CACHE_NAME}" >/dev/null
        sleep 2
    fi
    # Determine the host IP reachable from Docker containers.
    # host.docker.internal works on Docker Desktop but not inside privileged
    # pi-gen containers.  Use the docker bridge gateway IP instead.
    APT_CACHE_HOST=$(docker network inspect bridge -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)
    APT_CACHE_HOST="${APT_CACHE_HOST:-172.17.0.1}"
    SDR_PI_APT_CACHE="http://${APT_CACHE_HOST}:3142"

    # Health-check the apt cache before committing to using it.
    # Test via localhost (reachable from host via Docker port mapping) even
    # though APT_PROXY uses the bridge IP (reachable from inside containers).
    echo ">>> Verifying apt cache at ${SDR_PI_APT_CACHE}..."
    if apt_cache_health_check "http://localhost:3142"; then
        echo ">>> apt cache: verified working"
        echo "APT_PROXY=${SDR_PI_APT_CACHE}" >> "${PIGEN_DIR}/config"
    else
        echo "WARNING: apt cache at ${SDR_PI_APT_CACHE} is not responding." >&2
        echo "         Falling back to direct mirror access (no caching)." >&2
        echo "         Rebuild may be slower. Check Docker networking." >&2
    fi
fi

# ── Copy our custom stage into pi-gen ─────────────────────────────────────────
# Must be a real copy (not symlink) because Docker COPY won't follow symlinks
# that point outside the build context.  Also populates the files/ directory
# with config files, scripts, and service units that are .gitignored in the
# source tree (generated at build time).
prepare_stage() {
    rm -rf "${PIGEN_DIR}/stage-sdr-pi"
    cp -r "${PROJECT_DIR}/pi-gen-stage" "${PIGEN_DIR}/stage-sdr-pi"

    local STAGE_FILES="${PIGEN_DIR}/stage-sdr-pi/01-configure-services/files"
    mkdir -p "$STAGE_FILES"
    # Use custom config if SDR_PI_CONF is set, otherwise use default.
    cp "${SDR_PI_CONF:-${PROJECT_DIR}/sdr-pi.conf.default}" "${STAGE_FILES}/sdr-pi.conf"
    cp "${PROJECT_DIR}/config/udev/99-rtlsdr.rules"       "${STAGE_FILES}/"
    cp "${PROJECT_DIR}/config/systemd/"*.service           "${STAGE_FILES}/"
    cp "${PROJECT_DIR}/scripts/sdr-pi-rtl433-wrapper"      "${STAGE_FILES}/"
    cp "${PROJECT_DIR}/scripts/sdr-pi-dump1090-wrapper"    "${STAGE_FILES}/"
    cp "${PROJECT_DIR}/scripts/sdr-pi-op25-wrapper"        "${STAGE_FILES}/"
    cp "${PROJECT_DIR}/scripts/sdr-pi-apply-config"        "${STAGE_FILES}/"
    cp "${PROJECT_DIR}/scripts/sdr-pi-status"              "${STAGE_FILES}/"
    cp "${PROJECT_DIR}/config/sysctl.d/99-sdr-pi.conf"    "${STAGE_FILES}/"
    cp "${PROJECT_DIR}/config/modprobe.d/99-sdr-pi-usb.conf" "${STAGE_FILES}/"
    cp "${PROJECT_DIR}/config/boot/config.txt.sdr-pi"     "${STAGE_FILES}/"
    cp "${PROJECT_DIR}/config/boot/cmdline.txt.sdr-pi"    "${STAGE_FILES}/"
    cp "${PROJECT_DIR}/config/journald/journald.conf.override" "${STAGE_FILES}/"
    cp "${PROJECT_DIR}/config/fstab/sdr-pi.fstab"         "${STAGE_FILES}/"
    echo ">>> Stage prepared ($(ls "$STAGE_FILES" | wc -l) files)"
}
prepare_stage

# Skip stages 3-5 (desktop and full environment — not needed for headless).
touch "${PIGEN_DIR}/stage3/SKIP" "${PIGEN_DIR}/stage4/SKIP" "${PIGEN_DIR}/stage5/SKIP"
touch "${PIGEN_DIR}/stage3/SKIP_IMAGES" "${PIGEN_DIR}/stage4/SKIP_IMAGES" "${PIGEN_DIR}/stage5/SKIP_IMAGES"

# ── Stage skipping — resume from previous build ─────────────────────────────
# pi-gen creates a SKIP file in each completed stage's work directory.  When
# SDR_PI_CONTINUE=1, we mark base stages (0–2) as skippable if their work
# directory already exists, so only our custom stage is rebuilt.  This cuts
# rebuild time from ~60 min to ~10 min after the first full build.
if [[ "${SDR_PI_CONTINUE:-0}" == "1" ]]; then
    echo ">>> Continuing previous build (skipping completed stages)..."
    export CONTINUE=1
    for stage_num in 0 1 2; do
        work_dir="${PIGEN_DIR}/work/sdr-pi/stage${stage_num}"
        if [[ -d "$work_dir" ]]; then
            echo "    Skipping stage${stage_num} (already built)"
            touch "${PIGEN_DIR}/stage${stage_num}/SKIP"
        fi
    done
fi

# ── ccache volume ────────────────────────────────────────────────────────────
# Mount a persistent ccache directory into the pi-gen container so compiled
# objects survive across rebuilds.  On a second build with unchanged sources,
# this turns ~30 min of compilation into seconds.
#
# pi-gen's build-docker.sh passes PIGEN_DOCKER_OPTS to `docker run`.
CCACHE_DIR="${PROJECT_DIR}/build/ccache"
mkdir -p "$CCACHE_DIR"
STAGE_DIR="${PIGEN_DIR}/stage-sdr-pi"
export PIGEN_DOCKER_OPTS="${PIGEN_DOCKER_OPTS:-} -v ${CCACHE_DIR}:/ccache --dns 8.8.8.8 -v ${STAGE_DIR}:/pi-gen/stage-sdr-pi"
echo ">>> ccache volume: ${CCACHE_DIR} → /ccache"
echo ">>> stage volume:  ${STAGE_DIR} → /pi-gen/stage-sdr-pi"

# ── Pre-pull pi-gen base image ──────────────────────────────────────────────
# pi-gen's build-docker.sh uses i386/debian on 64-bit hosts.  Pre-pulling the
# image here lets us detect Docker networking / DNS problems early and give a
# clear error message instead of a cryptic Dockerfile build failure.
case "$(uname -m)" in
    x86_64) BASE_IMAGE="i386/debian:bookworm" ;;
    *)      BASE_IMAGE="debian:bookworm" ;;
esac
if ! docker image inspect "$BASE_IMAGE" &>/dev/null; then
    echo ">>> Pulling base image ${BASE_IMAGE}..."
    if ! docker pull "$BASE_IMAGE"; then
        echo "" >&2
        echo "ERROR: Failed to pull ${BASE_IMAGE}." >&2
        echo "       This is usually a Docker DNS problem (common on WSL2)." >&2
        echo "       Fixes to try:" >&2
        echo "         1. Restart Docker Desktop" >&2
        echo "         2. In Docker Desktop → Settings → Docker Engine, add:" >&2
        echo '            "dns": ["8.8.8.8", "8.8.4.4"]' >&2
        echo "         3. Check your internet connection" >&2
        exit 1
    fi
fi

# ── Handle stale Docker container ───────────────────────────────────────────
# pi-gen's build-docker.sh refuses to start if a container from a previous
# (possibly failed) build still exists.  When continuing, keep the container
# (pi-gen reuses its volumes to skip completed work).  Otherwise remove it.
if docker ps -a --filter name=pigen_work -q | grep -q .; then
    if [[ "${SDR_PI_CONTINUE:-0}" == "1" ]] || [[ "${CONTINUE:-0}" == "1" ]]; then
        echo ">>> Keeping pigen_work container (CONTINUE mode)"
    else
        echo ">>> Removing stale pigen_work container..."
        docker rm -v pigen_work >/dev/null
    fi
fi

# ── Build with retry loop ────────────────────────────────────────────────────
# Automatically retry failed builds using CONTINUE mode (skips completed
# stages).  pi-gen's CONTINUE creates an ephemeral "pigen_work_cont" container
# that mounts volumes from the original "pigen_work" container, preserving
# work from previous attempts.
SDR_PI_RETRIES="${SDR_PI_RETRIES:-2}"
BUILD_ATTEMPT=0
BUILD_SUCCESS=0

while [[ $BUILD_ATTEMPT -le $SDR_PI_RETRIES ]]; do
    BUILD_ATTEMPT=$((BUILD_ATTEMPT + 1))

    if [[ $BUILD_ATTEMPT -gt 1 ]]; then
        echo ""
        echo ">>> Build attempt ${BUILD_ATTEMPT}/$((SDR_PI_RETRIES + 1)) (retrying with CONTINUE mode)..."
        echo "    Previous attempt failed at $(date)"
        echo ""

        # On retry, enable CONTINUE mode to reuse volumes from the failed
        # pigen_work container (skips completed stages).
        export CONTINUE=1

        # Remove the ephemeral continuation container if it lingered.
        # Do NOT remove pigen_work — it holds the build volumes.
        if docker ps -a --filter name=pigen_work_cont -q 2>/dev/null | grep -q .; then
            docker rm -v pigen_work_cont >/dev/null 2>&1 || true
        fi

        # Re-check apt cache health before retrying.  If the proxy is still
        # broken, strip APT_PROXY so this attempt uses direct mirrors.
        if grep -q '^APT_PROXY=' "${PIGEN_DIR}/config" 2>/dev/null; then
            echo ">>> Re-checking apt cache before retry..."
            if ! apt_cache_health_check "http://localhost:3142"; then
                echo "WARNING: apt cache still unavailable, removing proxy config..." >&2
                sed -i '/^APT_PROXY=/d' "${PIGEN_DIR}/config"
            fi
        fi

        # Re-prepare our custom stage (may have been modified by pi-gen).
        prepare_stage

        # Brief pause to let transient issues clear.
        RETRY_DELAY=$(( 15 * BUILD_ATTEMPT ))
        echo ">>> Waiting ${RETRY_DELAY}s before retry..."
        sleep "$RETRY_DELAY"
    fi

    echo ">>> Starting pi-gen Docker build (attempt ${BUILD_ATTEMPT}/$((SDR_PI_RETRIES + 1)))..."
    cd "$PIGEN_DIR"
    if ./build-docker.sh; then
        BUILD_SUCCESS=1
        break
    else
        echo "" >&2
        echo ">>> Build attempt ${BUILD_ATTEMPT} failed." >&2
        REMAINING=$((SDR_PI_RETRIES - BUILD_ATTEMPT + 1))
        if [[ $REMAINING -gt 0 ]]; then
            echo ">>> Will retry automatically (${REMAINING} retries remaining)." >&2
        fi
    fi
done

if [[ $BUILD_SUCCESS -ne 1 ]]; then
    echo "" >&2
    echo "ERROR: Build failed after $((SDR_PI_RETRIES + 1)) attempts." >&2
    echo "       Check the build log for details." >&2
    echo "       You can retry manually with: SDR_PI_CONTINUE=1 ./scripts/build-image.sh" >&2
    exit 1
fi

# ── Copy output image ───────────────────────────────────────────────────────
mkdir -p "${PROJECT_DIR}/deploy"
IMG=$(find "${PIGEN_DIR}/deploy" -name "*.img" -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2-)

if [[ -n "$IMG" ]]; then
    DATE=$(date +%Y%m%d)
    DEST="${PROJECT_DIR}/deploy/sdr-pi-${DATE}.img"
    cp "$IMG" "$DEST"
    echo ""
    echo ">>> Image built successfully: ${DEST}"
    echo "    Size: $(du -h "$DEST" | cut -f1)"
else
    echo "Error: No .img file found in pi-gen deploy directory." >&2
    exit 1
fi
