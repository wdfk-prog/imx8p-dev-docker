#!/usr/bin/env sh
# Full SDK permission audit. This scans the entire ~25 GiB SDK and is therefore
# intentionally NOT run every time the container starts.
set -eu

fail()
{
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

SDK_ROOT=${SDK_ROOT:-/opt/fsl-imx-xwayland/6.1-mickledore}
[ -d "$SDK_ROOT" ] || fail "SDK directory does not exist: $SDK_ROOT"

printf 'Scanning SDK directories for missing other-execute permission: %s\n' "$SDK_ROOT"
bad_dir=$(find "$SDK_ROOT" -type d ! -perm -0001 -print -quit)
if [ -n "$bad_dir" ]; then
    fail "directory cannot be traversed by a normal user: $bad_dir"
fi

printf '%s\n' 'Scanning SDK files for missing other-read permission...'
bad_file=$(find "$SDK_ROOT" -type f ! -perm -0004 -print -quit)
if [ -n "$bad_file" ]; then
    fail "file cannot be read by a normal user: $bad_file"
fi

printf '%s\n' 'PASS: every SDK directory is traversable and every regular SDK file is readable.'
