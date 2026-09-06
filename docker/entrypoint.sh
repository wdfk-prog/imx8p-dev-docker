#!/usr/bin/env sh
# Container startup policy for the i.MX8P development image.
#
# Why this script exists:
#   1. Bind-mounted source files keep the HOST numeric UID/GID.
#   2. A portable image must therefore adapt its development user at runtime.
#   3. Yocto's environment-setup file must be sourced for every new container.
#   4. UTrack must keep its OWN CMake compile policy (-O0, -Wno-format, etc.).
#   5. Build commands should run as the normal developer, never as root.
#
# Do not use `set -u` here: vendor environment-setup scripts are not guaranteed
# to be safe under nounset. `set -e` still stops on real command failures.
set -e

fail()
{
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

is_uint()
{
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

DEV_USER=${DEV_USER:-embedsky}
HOST_UID=${HOST_UID:-1000}
HOST_GID=${HOST_GID:-1000}
SDK_ENV=${SDK_ENV:-/opt/fsl-imx-xwayland/6.1-mickledore/environment-setup-armv8a-poky-linux}
CMAKE_ROOT=${CMAKE_ROOT:-/opt/cmake-3.20.6-linux-x86_64}
HOME_DIR=/home/$DEV_USER

is_uint "$HOST_UID" || fail "HOST_UID must be an unsigned integer, got: $HOST_UID"
is_uint "$HOST_GID" || fail "HOST_GID must be an unsigned integer, got: $HOST_GID"

# Running the development shell as root defeats the purpose of UID/GID mapping
# and can create root-owned build outputs on the host.
[ "$HOST_UID" -ne 0 ] || fail "HOST_UID=0 is not supported for the development user"
[ "$HOST_GID" -ne 0 ] || fail "HOST_GID=0 is not supported for the development user"

[ "$(id -u)" -eq 0 ] || fail "entrypoint must start as root so it can map UID/GID"
id "$DEV_USER" >/dev/null 2>&1 || fail "development user does not exist: $DEV_USER"
[ -r "$SDK_ENV" ] || fail "Yocto SDK environment file is not readable: $SDK_ENV"
[ -x "$CMAKE_ROOT/bin/cmake" ] || fail "fixed CMake is missing: $CMAKE_ROOT/bin/cmake"

current_uid=$(id -u "$DEV_USER")
current_gid=$(id -g "$DEV_USER")
dev_group=$(id -gn "$DEV_USER")

# First map the primary group. If the requested GID already exists in the base
# image, reuse that group instead of failing groupmod with a duplicate GID.
if [ "$current_gid" -ne "$HOST_GID" ]; then
    target_group=$(getent group "$HOST_GID" | cut -d: -f1 || true)
    if [ -n "$target_group" ]; then
        usermod -g "$target_group" "$DEV_USER"
    else
        groupmod -g "$HOST_GID" "$dev_group"
    fi
fi

# A host UID collision with another account is ambiguous and unsafe. Stop with
# a clear message instead of silently changing an unrelated system account.
if [ "$current_uid" -ne "$HOST_UID" ]; then
    uid_owner=$(getent passwd "$HOST_UID" | cut -d: -f1 || true)
    if [ -n "$uid_owner" ] && [ "$uid_owner" != "$DEV_USER" ]; then
        fail "HOST_UID=$HOST_UID is already used by container account '$uid_owner'"
    fi
    usermod -u "$HOST_UID" "$DEV_USER"
fi

# Only the small image-owned HOME is changed here. Never chown /workspace:
# when /workspace is a bind mount, recursive chown would modify the real host
# source tree, exactly what this design is intended to avoid.
chown -R "$HOST_UID:$HOST_GID" "$HOME_DIR"

export HOME="$HOME_DIR"
export USER="$DEV_USER"
export LOGNAME="$DEV_USER"

# Yocto SDK setup is still required. It supplies PATH, SDKTARGETSYSROOT,
# OECORE_*, pkg-config settings and the cross-tool binaries.
# shellcheck disable=SC1090
. "$SDK_ENV"

[ -n "${SDKTARGETSYSROOT:-}" ] || fail "Yocto SDK did not set SDKTARGETSYSROOT"

# IMPORTANT UTrack compatibility policy:
#
# The vendor environment-setup script embeds its own optimization/security
# policy directly into CC/CXX and also exports CFLAGS/CXXFLAGS/CPPFLAGS/LDFLAGS.
# UTrack already owns those policies in CMake (notably -O0 and -Wno-format).
# Keeping both produced the already-observed hard failure:
#   -Wformat-security ignored without -Wformat [-Werror=format-security]
# and _FORTIFY_SOURCE warnings when the project selected -O0.
#
# Preserve the SDK/toolchain/sysroot, but remove the vendor compile-policy
# flags. This matches the previously successful UTrack build command, where
# the compiler driver received only the explicit target sysroot before the
# project's own CMake flags.
CC="aarch64-poky-linux-gcc --sysroot=$SDKTARGETSYSROOT"
CXX="aarch64-poky-linux-g++ --sysroot=$SDKTARGETSYSROOT"
export CC CXX
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS

# The project intentionally uses CMake 3.20.6, so put it back at the front
# after the Yocto script has modified PATH.
export PATH="$CMAKE_ROOT/bin:$PATH"

if [ "$#" -eq 0 ]; then
    set -- /bin/bash
fi

# Drop root privileges for the actual shell/build command. --init-groups asks
# libc/NSS for the supplementary groups of DEV_USER after the UID/GID remap.
exec setpriv \
    --reuid="$DEV_USER" \
    --regid="$(id -gn "$DEV_USER")" \
    --init-groups \
    -- "$@"
