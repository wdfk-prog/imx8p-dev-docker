#!/usr/bin/env sh
# Build the reusable i.MX8P development image.
#
# The 25 GiB SDK is NOT copied into this repository. Buildx receives the host
# SDK directory as a named build context called "sdk".
set -eu

fail()
{
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
PROJECT_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd -P)

SDK_DIR=${SDK_DIR:-/opt/fsl-imx-xwayland/6.1-mickledore}
IMX8P_IMAGE=${IMX8P_IMAGE:-imx8p-dev:20.04}
CMAKE_ASSET=$PROJECT_ROOT/assets/cmake-3.20.6-linux-x86_64.tar.gz

command -v docker >/dev/null 2>&1 || fail "docker command not found"
docker buildx version >/dev/null 2>&1 || fail "Docker Buildx plugin is not available"

HOST_UID=$(id -u)
HOST_GID=$(id -g)
[ "$HOST_UID" -ne 0 ] || fail "do not run build-image.sh as root or with sudo"
[ "$HOST_GID" -ne 0 ] || fail "host primary GID 0 is not supported for development"

[ -d "$SDK_DIR" ] || fail "SDK directory does not exist: $SDK_DIR"
[ -r "$SDK_DIR/environment-setup-armv8a-poky-linux" ] \
    || fail "SDK environment file is not readable; run ./scripts/prepare-assets.sh and check host SDK permissions"
[ -f "$CMAKE_ASSET" ] \
    || fail "missing CMake asset: $CMAKE_ASSET (run ./scripts/prepare-assets.sh first)"

printf 'Building image: %s\n' "$IMX8P_IMAGE"
printf 'SDK context   : %s\n' "$SDK_DIR"
printf '%s\n' 'The first SDK transfer is large; Buildx may transfer about 25 GiB.'

# --load puts the completed image into the local Docker image store so dev.sh
# can use it immediately.
docker buildx build \
    --progress=plain \
    --build-context "sdk=$SDK_DIR" \
    --load \
    -t "$IMX8P_IMAGE" \
    "$PROJECT_ROOT"

printf '%s\n' 'Image build completed. Running the UTrack compatibility verification...'
printf '%s\n' 'This gate checks CMake, host Thrift, normalized CC/CXX, target libthrift and UTrack-like compile flags.'

# This also exercises the runtime UID/GID mapping used by bind mounts.
docker run --rm \
    -e "HOST_UID=$HOST_UID" \
    -e "HOST_GID=$HOST_GID" \
    "$IMX8P_IMAGE" \
    verify-imx8p-env
