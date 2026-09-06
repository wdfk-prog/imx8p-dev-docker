#!/usr/bin/env sh
# Import an image previously created by export-image.sh.
# Docker loads supported compressed archives directly, avoiding a full-size
# temporary .tar in /tmp before docker load.
set -eu

fail()
{
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[ "$#" -eq 1 ] || fail "usage: ./scripts/import-image.sh /path/to/image.tar[.gz|.bz2|.xz|.zst]"

IMX8P_IMAGE=${IMX8P_IMAGE:-imx8p-dev:20.04}
ARCHIVE=$1
[ -f "$ARCHIVE" ] || fail "archive does not exist: $ARCHIVE"

case "$ARCHIVE" in
    *.tar|*.tar.gz|*.tgz|*.tar.bz2|*.tbz2|*.tar.xz|*.txz|*.tar.zst|*.tzst)
        ;;
    *)
        fail "supported formats: .tar, .tar.gz/.tgz, .tar.bz2/.tbz2, .tar.xz/.txz, .tar.zst/.tzst"
        ;;
esac

command -v docker >/dev/null 2>&1 || fail "docker command not found"
command -v awk >/dev/null 2>&1 || fail "awk command not found"
docker info >/dev/null 2>&1 || fail "cannot connect to Docker daemon"

ARCHIVE_DIR=$(dirname "$ARCHIVE")
ARCHIVE_DIR=$(CDPATH= cd "$ARCHIVE_DIR" && pwd -P)
ARCHIVE_NAME=$(basename "$ARCHIVE")
ARCHIVE=$ARCHIVE_DIR/$ARCHIVE_NAME
CHECKSUM=$ARCHIVE.sha256

if [ -f "$CHECKSUM" ]; then
    command -v sha256sum >/dev/null 2>&1 || fail "sha256sum command not found"

    EXPECTED_SHA256=$(awk 'NR == 1 { print $1; exit }' "$CHECKSUM")
    [ -n "$EXPECTED_SHA256" ] || fail "invalid checksum file: $CHECKSUM"
    ACTUAL_SHA256=$(sha256sum "$ARCHIVE" | awk '{ print $1 }')
    [ "$EXPECTED_SHA256" = "$ACTUAL_SHA256" ] \
        || fail "SHA256 mismatch: $ARCHIVE_NAME"
    printf 'SHA256    : OK (%s)\n' "$ARCHIVE_NAME"
else
    printf 'WARNING: checksum sidecar not found: %s\n' "$CHECKSUM" >&2
fi

DRIVER_STATUS=$(docker info -f '{{ .DriverStatus }}' 2>/dev/null || true)
STORAGE_PATH=/
CONTAINERD_STORE=0
case "$DRIVER_STATUS" in
    *io.containerd.snapshotter.v1*)
        CONTAINERD_STORE=1
        printf '%s\n' 'Storage   : containerd image store detected'
        if [ -d /var/lib/containerd ]; then
            STORAGE_PATH=/var/lib/containerd
        fi
        ;;
    *)
        DOCKER_ROOT=$(docker info -f '{{ .DockerRootDir }}' 2>/dev/null || true)
        printf 'Storage   : Docker data root%s\n' "${DOCKER_ROOT:+ $DOCKER_ROOT}"
        if [ -n "$DOCKER_ROOT" ] && [ -e "$DOCKER_ROOT" ]; then
            STORAGE_PATH=$DOCKER_ROOT
        fi
        ;;
esac

df -h "$STORAGE_PATH" 2>/dev/null || df -h / 2>/dev/null || true

# Docker Engine 29+ fresh installs use the containerd image store by default.
# It retains compressed image content and unpacked snapshots, so this project's
# large SDK image can need far more disk than the transport archive itself.
# The threshold is a warning only: exact usage depends on Docker/storage state.
if [ "$CONTAINERD_STORE" -eq 1 ]; then
    available_kib=$(df -Pk "$STORAGE_PATH" 2>/dev/null | awk 'NR == 2 { print $4; exit }')
    case "$available_kib" in
        ''|*[!0-9]*) ;;
        *)
            if [ "$available_kib" -lt 62914560 ]; then
                available_gib=$(awk -v kib="$available_kib" 'BEGIN { printf "%.1f", kib / 1048576 }')
                printf 'WARNING   : only %s GiB free on Docker storage filesystem.\n' "$available_gib" >&2
                printf '%s\n' '            For this large image, 60+ GiB free is recommended before import.' >&2
            fi
            ;;
    esac
fi

TMP_BASE=${TMPDIR:-/tmp}
[ -d "$TMP_BASE" ] || fail "TMPDIR does not exist: $TMP_BASE"
LOAD_LOG=$(mktemp "$TMP_BASE/imx8p-load.XXXXXX.log")
cleanup()
{
    rm -f "$LOAD_LOG"
}
trap cleanup EXIT HUP INT TERM

BEFORE_ID=$(docker image inspect "$IMX8P_IMAGE" --format '{{.Id}}' 2>/dev/null || true)

printf 'Archive   : %s\n' "$ARCHIVE"
printf '%s\n' 'Loading   : direct docker load (no full-size temporary tar)'
if docker load -i "$ARCHIVE" > "$LOAD_LOG"; then
    LOAD_STATUS=0
else
    LOAD_STATUS=$?
fi
cat "$LOAD_LOG"
[ "$LOAD_STATUS" -eq 0 ] || fail "docker load failed with status $LOAD_STATUS"

AFTER_ID=$(docker image inspect "$IMX8P_IMAGE" --format '{{.Id}}' 2>/dev/null || true)
[ -n "$AFTER_ID" ] || fail "load completed but expected image was not found: $IMX8P_IMAGE"

# A successful load normally reports the tag. If an older/pre-existing image
# has the same tag, this output check prevents us from claiming that an
# unrelated archive imported that image merely because it was already present.
if ! grep -F "Loaded image: $IMX8P_IMAGE" "$LOAD_LOG" >/dev/null 2>&1; then
    if [ -n "$BEFORE_ID" ] && [ "$BEFORE_ID" = "$AFTER_ID" ]; then
        fail "docker load succeeded, but archive did not confirm expected image tag: $IMX8P_IMAGE"
    fi
fi

printf 'Imported  : %s\n' "$IMX8P_IMAGE"
printf 'Image ID  : %s\n' "$AFTER_ID"
printf '%s\n' 'Check     : docker image ls'
