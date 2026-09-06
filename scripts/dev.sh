#!/usr/bin/env sh
# Enter the development container while keeping host file ownership correct.
#
# Usage:
#   ./scripts/dev.sh
#   ./scripts/dev.sh /path/to/source
#   ./scripts/dev.sh /path/to/source make -j4
set -eu

fail()
{
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
PROJECT_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd -P)

if [ "$#" -gt 0 ]; then
    workspace_input=$1
    shift
else
    workspace_input=$PROJECT_ROOT/../
fi

[ -d "$workspace_input" ] || fail "workspace directory does not exist: $workspace_input"
WORKSPACE_DIR=$(CDPATH= cd "$workspace_input" && pwd -P)

# A development build normally writes build/objects/output into the source tree.
# Do not auto-chown the host directory here; that could damage deliberate ACLs.
[ -r "$WORKSPACE_DIR" ] || fail "host user cannot read workspace: $WORKSPACE_DIR"
[ -w "$WORKSPACE_DIR" ] || fail "host user cannot write workspace: $WORKSPACE_DIR"
[ -x "$WORKSPACE_DIR" ] || fail "host user cannot enter workspace: $WORKSPACE_DIR"

command -v docker >/dev/null 2>&1 || fail "docker command not found"
docker compose version >/dev/null 2>&1 || fail "Docker Compose plugin is not available"

IMX8P_IMAGE=${IMX8P_IMAGE:-imx8p-dev:20.04}
docker image inspect "$IMX8P_IMAGE" >/dev/null 2>&1 \
    || fail "Docker image not found: $IMX8P_IMAGE (run ./scripts/build-image.sh or import-image.sh first)"

HOST_UID=$(id -u)
HOST_GID=$(id -g)

# Root-host development would intentionally map to UID/GID 0, which the image
# rejects to prevent root-owned source/build files.
[ "$HOST_UID" -ne 0 ] || fail "do not run dev.sh as root or with sudo"
[ "$HOST_GID" -ne 0 ] || fail "host primary GID 0 is not supported for development"

export HOST_UID HOST_GID WORKSPACE_DIR IMX8P_IMAGE

printf 'Host user : %s (uid=%s gid=%s)\n' "$(id -un)" "$HOST_UID" "$HOST_GID"
printf 'Workspace : %s\n' "$WORKSPACE_DIR"
printf 'Image     : %s\n' "$IMX8P_IMAGE"
printf '%s\n' 'Container : /workspace (same host files via bind mount)'

# With no remaining command, Compose uses Dockerfile CMD (/bin/bash).
exec docker compose -f "$PROJECT_ROOT/compose.yaml" run --rm imx8p-dev "$@"
