#!/usr/bin/env sh
# Fast verification executed INSIDE the container.
#
# This is intentionally stronger than a generic "compiler exists" check. It
# verifies the contracts that UTrack already proved it needs:
#   - fixed CMake 3.20.6;
#   - host-side Thrift compiler 0.13.0;
#   - target-side Thrift header/library from the Yocto sysroot;
#   - normalized CC/CXX without conflicting Yocto policy flags;
#   - UTrack-like -O0/-Wno-format C/C++ compilation;
#   - linker discovery of target libthrift.a.
#
# For a complete permission scan of the ~25 GiB SDK, run
# check-imx8p-sdk-permissions separately.
set -eu

fail()
{
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

contains_forbidden_build_flag()
{
    value=$1
    case " $value " in
        *' -D_FORTIFY_SOURCE='*|*' -Wp,-D_FORTIFY_SOURCE='*|*' -Wformat-security '*|*' -Werror=format-security '*|*' -O2 '*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

SDK_ROOT=${SDK_ROOT:-/opt/fsl-imx-xwayland/6.1-mickledore}
SDK_ENV=${SDK_ENV:-$SDK_ROOT/environment-setup-armv8a-poky-linux}
TARGET_SYSROOT=${SDKTARGETSYSROOT:-$SDK_ROOT/sysroots/armv8a-poky-linux}
THRIFT_HEADER=$TARGET_SYSROOT/usr/include/thrift/TDispatchProcessor.h
THRIFT_LIB=$TARGET_SYSROOT/lib/libthrift.a

printf '%s\n' '== Container identity =='
printf 'user=%s uid=%s gid=%s\n' "$(id -un)" "$(id -u)" "$(id -g)"
[ "$(id -u)" -ne 0 ] || fail "build command is still running as root"

if [ -n "${HOST_UID:-}" ] && [ "$(id -u)" != "$HOST_UID" ]; then
    fail "container uid $(id -u) does not match HOST_UID=$HOST_UID"
fi
if [ -n "${HOST_GID:-}" ] && [ "$(id -g)" != "$HOST_GID" ]; then
    fail "container gid $(id -g) does not match HOST_GID=$HOST_GID"
fi

printf '%s\n' '== Fixed CMake =='
cmake_path=$(command -v cmake) || fail "cmake not found"
printf '%s\n' "$cmake_path"
cmake_line=$(cmake --version | sed -n '1p')
printf '%s\n' "$cmake_line"
case "$cmake_line" in
    'cmake version 3.20.6') ;;
    *) fail "expected CMake 3.20.6" ;;
esac

printf '%s\n' '== Host Thrift compiler =='
thrift_path=$(command -v thrift) || fail "host Thrift compiler not found"
printf '%s\n' "$thrift_path"
[ "$thrift_path" = /usr/bin/thrift ] \
    || fail "expected Ubuntu host Thrift compiler at /usr/bin/thrift, got: $thrift_path"
thrift_version=$(thrift -version 2>&1 || true)
printf '%s\n' "$thrift_version"
case "$thrift_version" in
    *'0.13.0'*) ;;
    *) fail "expected host Thrift compiler 0.13.0" ;;
esac

printf '%s\n' '== Yocto SDK and normalized UTrack compiler environment =='
[ -r "$SDK_ENV" ] || fail "SDK environment file is not readable: $SDK_ENV"
[ -n "${SDKTARGETSYSROOT:-}" ] || fail "SDKTARGETSYSROOT is empty; entrypoint did not activate the SDK"
[ -n "${CC:-}" ] || fail "CC is empty"
[ -n "${CXX:-}" ] || fail "CXX is empty"
command -v aarch64-poky-linux-gcc || fail "C cross compiler not found"
command -v aarch64-poky-linux-g++ || fail "C++ cross compiler not found"
aarch64-poky-linux-gcc --version | sed -n '1p'
aarch64-poky-linux-g++ --version | sed -n '1p'
printf 'CC=%s\n' "$CC"
printf 'CXX=%s\n' "$CXX"

case "$CC" in
    "aarch64-poky-linux-gcc --sysroot=$SDKTARGETSYSROOT") ;;
    *) fail "CC does not match the normalized UTrack compiler contract" ;;
esac
case "$CXX" in
    "aarch64-poky-linux-g++ --sysroot=$SDKTARGETSYSROOT") ;;
    *) fail "CXX does not match the normalized UTrack compiler contract" ;;
esac

for value in "$CC" "$CXX" "${CFLAGS:-}" "${CXXFLAGS:-}" "${CPPFLAGS:-}" "${LDFLAGS:-}"; do
    if contains_forbidden_build_flag "$value"; then
        fail "conflicting Yocto/UTrack build flag remains in environment: $value"
    fi
done

[ -z "${CFLAGS:-}" ] || fail "CFLAGS must be empty after UTrack normalization"
[ -z "${CXXFLAGS:-}" ] || fail "CXXFLAGS must be empty after UTrack normalization"
[ -z "${CPPFLAGS:-}" ] || fail "CPPFLAGS must be empty after UTrack normalization"
[ -z "${LDFLAGS:-}" ] || fail "LDFLAGS must be empty after UTrack normalization"

printf '%s\n' '== Permission regression checks =='
[ -r "$THRIFT_HEADER" ] || fail "Thrift header is not readable: $THRIFT_HEADER"
[ -r "$THRIFT_LIB" ] || fail "Thrift library is not readable: $THRIFT_LIB"
printf 'readable: %s\n' "$THRIFT_HEADER"
printf 'readable: %s\n' "$THRIFT_LIB"

printf '%s\n' '== UTrack-like C/C++ cross-compile smoke tests =='
tmp_dir=$(mktemp -d /tmp/imx8p-verify.XXXXXX)
cleanup()
{
    rm -rf "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

cat > "$tmp_dir/main.c" <<'EOF_C'
#include <stdio.h>
int main(void)
{
    printf("%s\n", "imx8p-c-smoke");
    return 0;
}
EOF_C

cat > "$tmp_dir/main.cpp" <<'EOF_CPP'
#include <cstdio>
int main()
{
    std::printf("%s\n", "imx8p-cxx-smoke");
    return 0;
}
EOF_CPP

# UTrack deliberately compiles with -O0 and disables format warnings. These
# two commands are regression tests for the exact conflict that previously
# produced -Werror=format-security / _FORTIFY_SOURCE failures.
# Intentional word splitting preserves the compiler plus --sysroot argument.
# shellcheck disable=SC2086
$CC -O0 -Wno-format "$tmp_dir/main.c" -o "$tmp_dir/main-c"
# shellcheck disable=SC2086
$CXX -O0 -Wno-format "$tmp_dir/main.cpp" -o "$tmp_dir/main-cxx"
file "$tmp_dir/main-c"
file "$tmp_dir/main-cxx"
file "$tmp_dir/main-c" | grep -q 'ARM aarch64' || fail "C smoke output is not AArch64"
file "$tmp_dir/main-cxx" | grep -q 'ARM aarch64' || fail "C++ smoke output is not AArch64"

printf '%s\n' '== Target libthrift linker discovery =='
# shellcheck disable=SC2086
resolved_thrift=$($CXX -print-file-name=libthrift.a)
printf 'resolved libthrift.a: %s\n' "$resolved_thrift"
[ "$resolved_thrift" != libthrift.a ] || fail "cross linker cannot resolve libthrift.a"
[ -r "$resolved_thrift" ] || fail "resolved libthrift.a is not readable: $resolved_thrift"

# A trivial -lthrift link confirms that the driver can actually open the target
# archive from its sysroot search path. No host libthrift-dev is installed.
# shellcheck disable=SC2086
$CXX -O0 -Wno-format "$tmp_dir/main.cpp" -lthrift -lpthread -o "$tmp_dir/main-thrift-link"
file "$tmp_dir/main-thrift-link" | grep -q 'ARM aarch64' \
    || fail "Thrift link smoke output is not AArch64"

printf '%s\n' '== Thrift code-generation smoke test =='
mkdir -p "$tmp_dir/gen-cpp"
cat > "$tmp_dir/smoke.thrift" <<'EOF_THRIFT'
namespace cpp imx8p_verify

struct SmokeValue {
  1: i32 value
}
EOF_THRIFT

thrift --gen cpp -out "$tmp_dir/gen-cpp" "$tmp_dir/smoke.thrift"
[ -f "$tmp_dir/gen-cpp/smoke_types.cpp" ] || fail "Thrift did not generate smoke_types.cpp"
[ -f "$tmp_dir/gen-cpp/smoke_types.h" ] || fail "Thrift did not generate smoke_types.h"

# Compile the generated file with the ARM64 target headers. This catches a
# host-generator/target-header mismatch before a one-hour image build is used
# for the real UTrack project.
# shellcheck disable=SC2086
$CXX -O0 -Wno-format -I"$tmp_dir/gen-cpp" \
    -c "$tmp_dir/gen-cpp/smoke_types.cpp" -o "$tmp_dir/smoke_types.o"
file "$tmp_dir/smoke_types.o" | grep -q 'ARM aarch64' \
    || fail "generated Thrift object is not AArch64"

printf '%s\n' '== CMake integration smoke test =='
mkdir -p "$tmp_dir/cmake-src"
cat > "$tmp_dir/cmake-src/CMakeLists.txt" <<'EOF_CMAKE'
cmake_minimum_required(VERSION 3.10)
project(imx8p_utrack_environment_smoke LANGUAGES CXX)

if(NOT THRIFT_COMPILER)
    message(FATAL_ERROR "THRIFT_COMPILER was not provided")
endif()
set(THRIFT_COMPILER "${THRIFT_COMPILER}" CACHE FILEPATH "Host Thrift compiler" FORCE)
if(NOT THRIFT_COMPILER STREQUAL "/usr/bin/thrift")
    message(FATAL_ERROR "Unexpected Thrift compiler: ${THRIFT_COMPILER}")
endif()

add_executable(cmake-cxx-smoke main.cpp)
target_compile_options(cmake-cxx-smoke PRIVATE -O0 -Wno-format)
target_link_libraries(cmake-cxx-smoke PRIVATE thrift pthread)
EOF_CMAKE
cat > "$tmp_dir/cmake-src/main.cpp" <<'EOF_CMAKE_CPP'
#include <thrift/Thrift.h>

int main()
{
    return 0;
}
EOF_CMAKE_CPP

# This is the final fast regression for the real integration path: CMake must
# parse CC/CXX with --sysroot, accept the same explicit Thrift path used by
# UTrack, compile with UTrack-like flags and link the ARM64 target libthrift
# from the Yocto sysroot.
cmake -S "$tmp_dir/cmake-src" -B "$tmp_dir/cmake-build" \
    -DTHRIFT_COMPILER=/usr/bin/thrift
cmake --build "$tmp_dir/cmake-build" --parallel 2
grep -q '^THRIFT_COMPILER:FILEPATH=/usr/bin/thrift$' \
    "$tmp_dir/cmake-build/CMakeCache.txt" \
    || fail "CMake did not cache /usr/bin/thrift as THRIFT_COMPILER"
file "$tmp_dir/cmake-build/cmake-cxx-smoke" | grep -q 'ARM aarch64' \
    || fail "CMake smoke output is not AArch64"

printf '%s\n' 'PASS: i.MX8P Docker development environment is UTrack-ready.'
