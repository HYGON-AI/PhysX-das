#!/usr/bin/env bash
# Copyright (c) 2026 Hygon Information Technology Co., Ltd.
# SPDX-License-Identifier: BSD-3-Clause
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#  * Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
#  * Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#  * Neither the name of NVIDIA CORPORATION nor the names of its
#    contributors may be used to endorse or promote products derived
#    from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ''AS IS'' AND ANY
# EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
# PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
# PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
# OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

# Build PhysX HCU Examples
set -euo pipefail

# Keep the legacy marker value: external build verification helpers match it verbatim.
BUILD_SCRIPT_MARKER="PX_DCU_EXAMPLES_BUILD_R2_FOREIGN_CMAKE_CACHE_RECOVERY"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
BUILD_DIR="$SCRIPT_DIR/build"
PHYSX_ROOT="$SCRIPT_DIR/../../physx"
PHYSX_BUILD_DIR="${PHYSX_BUILD_DIR:-$SCRIPT_DIR/../../build_cpu}"
CMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}"

case "$CMAKE_BUILD_TYPE" in
    Debug|Release|RelWithDebInfo|MinSizeRel) ;;
    *)
        echo "ERROR: unsupported CMAKE_BUILD_TYPE: $CMAKE_BUILD_TYPE" >&2
        echo "Use Debug, Release, RelWithDebInfo, or MinSizeRel." >&2
        exit 2
        ;;
esac

read_cache_value()
{
    local cache_file="$1" key="$2"
    if [[ -f "$cache_file" ]]; then
        sed -n "s/^${key}:[^=]*=//p" "$cache_file" | tail -1
    fi
}

normalize_hcu_arch()
{
    local raw="${1//$'\r'/}"
    local arch
    local first_arch=""
    local values=()

    IFS=';' read -r -a values <<< "$raw"
    for value in "${values[@]}"; do
        arch="${value//[[:space:]]/}"
        [[ -n "$arch" ]] || continue
        if [[ ! "$arch" =~ ^gfx[0-9][0-9A-Za-z]*$ ]]; then
            printf '%s\n' "$raw"
            return 0
        fi
        if [[ -z "$first_arch" ]]; then
            first_arch="$arch"
        elif [[ "$arch" != "$first_arch" ]]; then
            printf 'ERROR: multiple HCU architectures in CMAKE_HIP_ARCHITECTURES: %s\n' "$raw" >&2
            return 2
        fi
    done

    if [[ -n "$first_arch" ]]; then
        printf '%s\n' "$first_arch"
    else
        printf '%s\n' "$raw"
    fi
}

detect_hcu_arch()
{
    if command -v rocminfo >/dev/null 2>&1; then
        rocminfo 2>/dev/null |
            sed -n 's/.*\(gfx[0-9][0-9A-Za-z]*\).*/\1/p' |
            head -n 1
    fi
}

BUILD_HCU_CACHE="$SCRIPT_DIR/../../build_hcu/CMakeCache.txt"
HCU_ARCH="${HCU_ARCH:-}"
if [[ -z "$HCU_ARCH" ]]; then
    HCU_ARCH="$(read_cache_value "$BUILD_HCU_CACHE" HCU_ARCH)"
fi
if [[ -z "$HCU_ARCH" ]]; then
    HCU_ARCH="$(read_cache_value "$BUILD_HCU_CACHE" CMAKE_HIP_ARCHITECTURES)"
fi
if [[ -z "$HCU_ARCH" ]]; then
    HCU_ARCH="$(detect_hcu_arch || true)"
fi
HCU_ARCH="$(normalize_hcu_arch "$HCU_ARCH")"
if [[ -z "$HCU_ARCH" ]]; then
    printf 'ERROR: cannot determine HCU architecture. Run build_hcu.sh first or set HCU_ARCH=gfxXXX.\n' >&2
    exit 2
fi
if [[ ! "$HCU_ARCH" =~ ^gfx[0-9][0-9A-Za-z]*$ ]]; then
    printf 'ERROR: invalid HCU architecture: %s\n' "$HCU_ARCH" >&2
    exit 2
fi

reset_build_dir()
{
    if [[ -z "$BUILD_DIR" || "$BUILD_DIR" != "$SCRIPT_DIR/build" ]]; then
        printf 'ERROR: refusing to reset unexpected build directory: %s\n' "$BUILD_DIR" >&2
        exit 2
    fi
    rm -rf -- "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
}

# Find a usable HIP compiler (same search order as build_hcu.sh).
HIP_CLANG=""
if [[ -n "${HIPCXX:-}" ]]; then
    if [[ -x "$HIPCXX" ]]; then
        HIP_CLANG="$HIPCXX"
    else
        HIP_CLANG="$(command -v "$HIPCXX" 2>/dev/null || true)"
    fi
fi
if [[ -z "$HIP_CLANG" ]]; then
    for compiler in /opt/dtk/bin/clang++ /opt/dtk/dcc/bin/clang++ /opt/rocm/bin/clang++ /opt/rocm/llvm/bin/clang++; do
        [[ -x "$compiler" ]] && HIP_CLANG="$compiler" && break
    done
fi
if [[ -z "$HIP_CLANG" ]]; then
    HIP_CLANG="$(command -v clang++ 2>/dev/null || true)"
fi
if [[ -z "$HIP_CLANG" ]]; then
    echo "ERROR: Cannot find a usable HIP compiler" >&2
    exit 1
fi

echo "HIP Clang: $HIP_CLANG"
echo "Build type: $CMAKE_BUILD_TYPE"
echo "Building PhysX HCU Examples..."
echo "HCU Architecture: $HCU_ARCH"
printf 'build_script_marker=%s\n' "$BUILD_SCRIPT_MARKER"

# CMake caches absolute paths. A cache copied from Windows/WSL or another checkout cannot be
# reused on the remote node, so discard only this exact example build directory on mismatch.
CACHE_FILE="$BUILD_DIR/CMakeCache.txt"
if [[ -f "$CACHE_FILE" && ( -f "$BUILD_DIR/Makefile" || -f "$BUILD_DIR/build.ninja" ) ]]; then
    cache_source="$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "$CACHE_FILE" | tail -1)"
    cache_build="$(sed -n 's/^CMAKE_CACHEFILE_DIR:INTERNAL=//p' "$CACHE_FILE" | tail -1)"
    cache_hip="$(sed -n 's/^CMAKE_HIP_COMPILER:[^=]*=//p' "$CACHE_FILE" | tail -1)"
    cache_physx_root="$(sed -n 's/^PHYSX_ROOT_DIR:[^=]*=//p' "$CACHE_FILE" | tail -1)"
    cache_physx_build="$(sed -n 's/^PHYSX_BUILD_DIR:[^=]*=//p' "$CACHE_FILE" | tail -1)"
    cache_build_type="$(sed -n 's/^CMAKE_BUILD_TYPE:[^=]*=//p' "$CACHE_FILE" | tail -1)"
    cache_arch="$(sed -n 's/^CMAKE_HIP_ARCHITECTURES:[^=]*=//p' "$CACHE_FILE" | tail -1)"
    if [[ -z "$cache_arch" ]]; then
        cache_arch="$(sed -n 's/^HCU_ARCH:[^=]*=//p' "$CACHE_FILE" | tail -1)"
    fi
    if [[ "$cache_source" != "$SCRIPT_DIR" || "$cache_build" != "$BUILD_DIR" || \
          "$cache_hip" != "$HIP_CLANG" || "$cache_physx_root" != "$PHYSX_ROOT" || \
          "$cache_physx_build" != "$PHYSX_BUILD_DIR" || \
          "$cache_build_type" != "$CMAKE_BUILD_TYPE" || "$cache_arch" != "$HCU_ARCH" || \
          ! -x "$cache_hip" ]]; then
        printf 'Discarding stale/foreign CMake cache: source=%s build=%s hip=%s physx=%s physx_build=%s type=%s arch=%s expected_hip=%s expected_type=%s expected_arch=%s\n' \
            "${cache_source:-missing}" "${cache_build:-missing}" \
            "${cache_hip:-missing}" "${cache_physx_root:-missing}" \
            "${cache_physx_build:-missing}" "${cache_build_type:-missing}" \
            "${cache_arch:-missing}" \
            "$HIP_CLANG" "$CMAKE_BUILD_TYPE" "$HCU_ARCH"
        reset_build_dir
    fi
elif [[ -e "$BUILD_DIR" ]]; then
    printf 'Discarding incomplete example build directory: %s\n' "$BUILD_DIR"
    reset_build_dir
else
    mkdir -p "$BUILD_DIR"
fi

cd "$BUILD_DIR"

# Always configure so build type, source paths, and example rules stay current.
cmake "$SCRIPT_DIR" \
    -DCMAKE_CXX_COMPILER="$(command -v g++)" \
    -DCMAKE_HIP_COMPILER="$HIP_CLANG" \
    -DCMAKE_BUILD_TYPE="$CMAKE_BUILD_TYPE" \
    -DCMAKE_HIP_ARCHITECTURES="$HCU_ARCH" \
    -DPHYSX_ROOT_DIR="$PHYSX_ROOT" \
    -DPHYSX_BUILD_DIR="$PHYSX_BUILD_DIR"

TARGET="${1:-bench_physx_scene}"
if [[ "$TARGET" == "all" ]]; then
    cmake --build . -j1 --target all
    printf 'Built all targets in %s\n' "$BUILD_DIR"
    exit 0
fi

cmake --build . -j1 --target "$TARGET"

if [[ ! -x "$TARGET" ]]; then
    printf 'ERROR: target was not produced or is not executable: %s/%s\n' "$BUILD_DIR" "$TARGET" >&2
    exit 1
fi
printf 'Built %s/%s\n' "$BUILD_DIR" "$TARGET"
