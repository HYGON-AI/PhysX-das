# PhysX-das

<details>
<summary>Copyright & License</summary>

Copyright (c) 2008-2025 NVIDIA Corporation. All rights reserved.
Copyright (c) 2026 Hygon Information Technology Co., Ltd.

This repository is based on NVIDIA PhysX. Modifications for Hygon HCU/HIP
support are made by Hygon Information Technology Co., Ltd.

### Upstream attribution

| Field | Value |
|-------|-------|
| Upstream repository | `https://github.com/NVIDIA-Omniverse/PhysX.git` |
| Upstream branch | `main` |
| Upstream tag | `ovphysx-0.4.9` |
| Upstream commit | `34ce3ed80821f91c88fe02ace9c454280983b50a` |
| Upstream license | `BSD-3-Clause` |

Modified by Hygon Information Technology Co., Ltd.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:
 * Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.
 * Neither the name of NVIDIA CORPORATION nor the names of its
   contributors may be used to endorse or promote products derived
   from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS "AS IS" AND ANY
EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

</details>

Please also see license files in the root folder and in the respective subfolders.

## Hygon HCU / HIP Port

PhysX GPU modules have been ported to **Hygon HCU** (gfx936/gfx938) with HIP.

### Build Requirements (HCU)

| Component | Version |
|-----------|---------|
| DTK (HCU Toolkit) | 2604 |
| CMake | >= 3.21 |
| g++ | >= 8.0 |

### Build Environment

Run this command from the repository root before the first build:

```bash
chmod +x examples/hcu/*.sh
```

`build_hcu.sh` automatically adds `/opt/dtk/lib64/cmake` and `/opt/dtk` to
`CMAKE_PREFIX_PATH` when those DTK 2604 directories are present. For a custom
DTK installation, set `CMAKE_PREFIX_PATH` explicitly.

The build scripts detect the HCU architecture with `rocminfo`. You can check it
directly:

```bash
rocminfo | grep -m1 gfx
```

BW1101 systems report `gfx938`. If `rocminfo` is unavailable, pass the
architecture explicitly. An explicit value that differs from the detected
hardware is rejected because it can produce incomplete or incorrect results.

### Quick Start

The HCU port is built in three stages, in this order. The examples link
against the CPU libraries and load the GPU library at runtime, so both library
builds must complete before the examples are built.

```bash
# 1) GPU (HIP) libraries -> build_hcu/libPhysXGpuHCU.so, build_hcu/kernels/*.hsaco
./build_hcu.sh

# 2) CPU (host) libraries -> build_cpu/ (Foundation, PhysXSDK, ...)
./build_cpu.sh

# 3) Example binaries -> examples/hcu/build/<target>
cd examples/hcu
./build.sh
```

`build_hcu.sh` automatically discards an incomplete or architecture-mismatched
build directory before reconfiguring. `examples/hcu/build.sh` reuses the
architecture recorded by `build_hcu.sh`.

### Build Configuration

`build_hcu.sh` and `examples/hcu/build.sh` default to
`CMAKE_BUILD_TYPE=Release` and pass it to CMake explicitly. The HCU CMake
project adds `-O3` to the HIP compilation flags for Release builds. Use
`CMAKE_BUILD_TYPE=Debug` only when debugging; it is not representative for
performance measurements.

The scripts detect and replace build trees configured with a different build
type, HCU architecture, compiler, or source path. `build_hcu.sh` also removes
stale `.hsaco` files before extracting code objects from the current build.

### Running the Examples

`./build.sh` defaults to `bench_physx_scene`. To build every example in
`examples/hcu`:

```bash
cd examples/hcu
./build.sh all
```

Pass another target name to build a specific example:

```bash
cd examples/hcu
./build.sh bench_compare
```

Binaries are written to `examples/hcu/build/`. The runtime searches the
standard relative locations by default, so run from `examples/hcu/`:

```bash
cd examples/hcu
./build/bench_physx_scene
```

To run from another directory, set the HCU module paths explicitly:

```bash
export PX_HCU_KERNEL_DIR=/absolute/path/to/build_hcu/kernels
export PX_HCU_GPU_LIBRARY=/absolute/path/to/build_hcu/libPhysXGpuHCU.so
```

`PX_HCU_KERNEL_DIR` is checked first. If it does not contain loadable `.hsaco`
modules, the runtime reports a warning and then tries the standard kernel
directories before `PX_HCU_GPU_LIBRARY` and the default `.so` paths. Use a
`.so` or `.hsaco` build produced for the same HCU architecture as the local
device. If no HCU modules are loaded, the runtime reports an error with these
environment variable names.

For performance runs, start from a Release build and make sure the diagnostic
runtime switches are not enabled:

```bash
unset PX_HCU_SYNC_KERNELS PX_HCU_TRACE_KERNELS
./build/bench_physx_scene
```

`PX_HCU_SYNC_KERNELS` synchronizes after every kernel launch, and
`PX_HCU_TRACE_KERNELS` logs every launch; either switch can dominate runtime
and produce misleading FPS results.

### Tests

The basic probes are:

```bash
./build_cpu/test_cpu
./build_hcu/test_functional
```

Both probes should report `Results: 7 / 7 passed`. If `test_functional` reports
a partial pass on BW1101, verify that the HCU library was built for `gfx938`
rather than `gfx936`.

For a CPU/GPU comparison of the same scene:

```bash
cd examples/hcu
./build.sh bench_compare
./build/bench_compare
```

`VERDICT: CPU and GPU match` indicates that the GPU result matches the CPU
result.

### Port Summary

| Layer | Modules | Status |
|-------|---------|--------|
| GPU Kernel | PhysXCommonGpu, BroadphaseGpu, ArticulationGpu, SolverGpu, SimulationControllerGpu, NarrowphaseGpu | 100% (69 .cu files) |
| CPU Library | Foundation, Common, LowLevel, LowLevelAABB, LowLevelDynamics, SceneQuery, SimulationController, PhysXSDK | 100% |

### Key Adaptations

- WARP_SIZE = 64 (wavefront)
- FULL_MASK = 0xffffffffffffffff (64-bit)
- CUDA intrinsics → HIP macros (`shuffle.cuh`, `atomic.cuh`, `warpHelpers.cuh`)
- Named barriers → `__syncthreads()`
- PTX inline assembly → HIP equivalents
- 3D texture sampling → stubbed (SDF collision path)

### Example Results (BW200, UBB BW1000, 80 CUs)

| Example | Performance | Accuracy vs CPU |
|---------|------------|-----------------|
| N-Body (16K) | sub-ms per step | max err < 1e-3 |
| Particles (1M) | 3000+ FPS | max err < 0.01 |
| Raycast | 100M+ rays/s | max err < 1e-3 |

### Adapted Files

- **New**: `physx/source/gpucommon/include/PxgHIPCompat.h` — HIP compatibility layer
- **New**: `physx/source/gpucommon/src/HCU/` — runtime, stubs, tests
- **New**: `physx/source/compiler/cmakehip/` — HIP CMake build
- **New**: `physx/source/compiler/cmakecpu/` — CPU library CMake build
- **Modified**: ~55 .cu/.cuh files — `cuda.h` → conditional, intrinsic macros, PTX asm

This repo contains:

| Directory | Description |
|---|---|
| [`ovphysx/`](ovphysx/) | ovphysx — C API with Python bindings for USD physics simulation with DLPack tensor interop (`pip install ovphysx`) |
| [`physx/`](physx/) | PhysX SDK — real-time physics simulation engine |
| [`omni/`](omni/) | Omniverse PhysX extensions for Kit-based applications |

Additional simulation libraries:

| Directory | Description |
|---|---|
| [`blast/`](blast/) | Blast SDK — destruction and fracture simulation |
| [`flow/`](flow/) | Flow SDK — fluid and fire simulation |

## Support

* Please use GitHub [Discussions](https://github.com/NVIDIA-Omniverse/PhysX/discussions/) for questions and comments.
* GitHub [Issues](https://github.com/NVIDIA-Omniverse/PhysX/issues) should only be used for bug reports or documentation issues.
* You can also ask questions in the NVIDIA Omniverse #physics [Discord Channel](https://discord.com/invite/XWQNJDNuaC).
