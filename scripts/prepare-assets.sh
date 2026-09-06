#!/usr/bin/env sh
# Check the current host SDK and prepare only the small fixed-CMake asset.
#
# v5 deliberately does NOT pack the ~25 GiB NXP SDK into a tar.gz. build-image.sh
# passes that directory directly to Buildx as a named context.
set -eu

fail()
{
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
PROJECT_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd -P)

SDK_DIR=${SDK_DIR:-/opt/fsl-imx-xwayland/6.1-mickledore}
SDK_ENV=$SDK_DIR/environment-setup-armv8a-poky-linux
CMAKE_SOURCE_DIR=${CMAKE_SOURCE_DIR:-$HOME/share/cmake-3.20.6-linux-x86_64}
CMAKE_ASSET=$PROJECT_ROOT/assets/cmake-3.20.6-linux-x86_64.tar.gz
CMAKE_TMP=

cleanup()
{
    if [ -n "$CMAKE_TMP" ]; then
        rm -f "$CMAKE_TMP"
    fi
}
trap cleanup EXIT HUP INT TERM

printf '%s\n' '== 1. Check NXP/FSL Yocto SDK =='
[ -d "$SDK_DIR" ] || fail "SDK directory does not exist: $SDK_DIR"
[ -r "$SDK_ENV" ] || fail "SDK environment file is not readable: $SDK_ENV"
printf 'SDK: %s\n' "$SDK_DIR"
du -sh "$SDK_DIR" 2>/dev/null || true

# Source in a child shell so vendor variables do not pollute this host shell.
# Do not enable nounset around the vendor script.
(
    set -e
    # shellcheck disable=SC1090
    . "$SDK_ENV"
    printf 'Raw Yocto CC=%s\n' "${CC:-<unset>}"
    printf 'Raw Yocto CXX=%s\n' "${CXX:-<unset>}"
    printf '%s\n' 'NOTE: raw Yocto optimization/security flags are expected here.'
    printf '%s\n' '      The container entrypoint normalizes CC/CXX for UTrack at runtime.'
    printf 'SDKTARGETSYSROOT=%s\n' "${SDKTARGETSYSROOT:-<unset>}"
    command -v aarch64-poky-linux-gcc
    command -v aarch64-poky-linux-g++
    aarch64-poky-linux-gcc --version | sed -n '1p'
    aarch64-poky-linux-g++ --version | sed -n '1p'
)

printf '%s\n' '== 2. Prepare fixed CMake 3.20.6 asset =='
[ -d "$CMAKE_SOURCE_DIR" ] || fail "CMake source directory does not exist: $CMAKE_SOURCE_DIR"
[ -x "$CMAKE_SOURCE_DIR/bin/cmake" ] || fail "CMake executable not found: $CMAKE_SOURCE_DIR/bin/cmake"
cmake_line=$("$CMAKE_SOURCE_DIR/bin/cmake" --version | sed -n '1p')
printf '%s\n' "$cmake_line"
case "$cmake_line" in
    'cmake version 3.20.6') ;;
    *) fail "expected CMake 3.20.6, got: $cmake_line" ;;
esac

mkdir -p "$PROJECT_ROOT/assets"
# mktemp avoids predictable temporary names; mv publishes only a completed tar.
CMAKE_TMP=$(mktemp "$PROJECT_ROOT/assets/.cmake-3.20.6.XXXXXX.tar.gz")
tar -C "$CMAKE_SOURCE_DIR" -czf "$CMAKE_TMP" .
mv "$CMAKE_TMP" "$CMAKE_ASSET"
CMAKE_TMP=
printf 'Created: %s\n' "$CMAKE_ASSET"
ls -lh "$CMAKE_ASSET"

printf '%s\n' '== 3. Check Docker / Buildx / Compose =='
command -v docker >/dev/null 2>&1 || fail "docker command not found"
docker --version
docker buildx version
docker compose version

printf '%s\n' '== 4. Disk information =='
docker info --format 'DockerRootDir: {{.DockerRootDir}}' 2>/dev/null || true
df -h "$SDK_DIR" "$PROJECT_ROOT" 2>/dev/null || true

printf '%s\n' 'Preparation completed.'
printf '%s\n' 'Next: ./scripts/build-image.sh'
