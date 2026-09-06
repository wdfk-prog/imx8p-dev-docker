#!/usr/bin/env sh
# Export the built Docker image for offline/new-host distribution.
# Stream docker save through a compressor via a FIFO so a large temporary .tar
# is not written to disk, while preserving both producer and compressor errors.
set -eu

fail()
{
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

IMX8P_IMAGE=${IMX8P_IMAGE:-imx8p-dev:20.04}
OUTPUT=${1:-imx8p-dev-20.04-image.tar.gz}

case "$OUTPUT" in
    *.tar.gz|*.tgz)
        COMPRESS_KIND=gzip
        ;;
    *.tar.zst|*.tzst)
        COMPRESS_KIND=zstd
        ;;
    *)
        fail "output must end in .tar.gz/.tgz or .tar.zst/.tzst: $OUTPUT"
        ;;
esac

command -v docker >/dev/null 2>&1 || fail "docker command not found"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum command not found"
command -v mktemp >/dev/null 2>&1 || fail "mktemp command not found"
command -v mkfifo >/dev/null 2>&1 || fail "mkfifo command not found"
case "$COMPRESS_KIND" in
    gzip)
        command -v gzip >/dev/null 2>&1 || fail "gzip command not found"
        ;;
    zstd)
        command -v zstd >/dev/null 2>&1 || fail "zstd command not found; install package: zstd"
        ;;
esac

docker info >/dev/null 2>&1 || fail "cannot connect to Docker daemon"
docker image inspect "$IMX8P_IMAGE" >/dev/null 2>&1 || fail "image not found: $IMX8P_IMAGE"

OUTPUT_DIR=$(dirname "$OUTPUT")
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(CDPATH= cd "$OUTPUT_DIR" && pwd -P)
OUTPUT_NAME=$(basename "$OUTPUT")
OUTPUT=$OUTPUT_DIR/$OUTPUT_NAME
CHECKSUM=$OUTPUT.sha256

TMP_BASE=${TMPDIR:-/tmp}
[ -d "$TMP_BASE" ] || fail "TMPDIR does not exist: $TMP_BASE"
TMP_DIR=$(mktemp -d "$TMP_BASE/imx8p-export.XXXXXX")
FIFO=$TMP_DIR/image.tar
TMP_ARCHIVE=$(mktemp "$OUTPUT_DIR/.${OUTPUT_NAME}.XXXXXX.tmp")
TMP_SHA=$(mktemp "$OUTPUT_DIR/.${OUTPUT_NAME}.sha256.XXXXXX.tmp")
COMPRESS_PID=

cleanup()
{
    if [ -n "${COMPRESS_PID:-}" ]; then
        kill "$COMPRESS_PID" >/dev/null 2>&1 || true
        wait "$COMPRESS_PID" >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP_DIR"
    if [ -n "${TMP_ARCHIVE:-}" ]; then
        rm -f "$TMP_ARCHIVE"
    fi
    if [ -n "${TMP_SHA:-}" ]; then
        rm -f "$TMP_SHA"
    fi
}
trap cleanup EXIT HUP INT TERM

mkfifo "$FIFO"

printf 'Image     : %s\n' "$IMX8P_IMAGE"
printf 'Output    : %s\n' "$OUTPUT"
printf 'Compress  : %s\n' "$COMPRESS_KIND"
printf '%s\n' 'Mode      : streaming docker save (no full-size temporary tar)'
printf '%s\n' 'Filesystem before export:'
df -h "$OUTPUT_DIR" 2>/dev/null || true

# Start the FIFO consumer first. The background PID is retained so POSIX sh can
# check the compressor independently from the foreground docker save command.
case "$COMPRESS_KIND" in
    gzip)
        gzip -1 -c < "$FIFO" > "$TMP_ARCHIVE" &
        ;;
    zstd)
        zstd -T0 -1 -q -c < "$FIFO" > "$TMP_ARCHIVE" &
        ;;
esac
COMPRESS_PID=$!

if docker save "$IMX8P_IMAGE" > "$FIFO"; then
    SAVE_STATUS=0
else
    SAVE_STATUS=$?
fi

if wait "$COMPRESS_PID"; then
    COMPRESS_STATUS=0
else
    COMPRESS_STATUS=$?
fi
COMPRESS_PID=

if [ "$SAVE_STATUS" -ne 0 ] || [ "$COMPRESS_STATUS" -ne 0 ]; then
    fail "export failed (docker save=$SAVE_STATUS, $COMPRESS_KIND=$COMPRESS_STATUS)"
fi

# Prepare the checksum before publishing either final artifact. If publication
# later fails, remove any old sidecar first so a stale checksum cannot describe
# the newly published archive.
SHA256_LINE=$(sha256sum "$TMP_ARCHIVE")
SHA256_VALUE=${SHA256_LINE%% *}
[ -n "$SHA256_VALUE" ] || fail "failed to calculate SHA256"
printf '%s  %s\n' "$SHA256_VALUE" "$OUTPUT_NAME" > "$TMP_SHA"

rm -f "$CHECKSUM"
mv -f "$TMP_ARCHIVE" "$OUTPUT"
TMP_ARCHIVE=
mv -f "$TMP_SHA" "$CHECKSUM"
TMP_SHA=

printf 'Created   : %s\n' "$OUTPUT"
printf 'SHA256    : %s\n' "$CHECKSUM"
printf '%s\n' 'Note      : bind-mounted Git source code is not included in the image archive.'
