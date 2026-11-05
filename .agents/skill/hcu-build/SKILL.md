---
name: hcu-build
description: 在 PhysX-das 中使用仓库自带脚本编译 HCU/HIP GPU 库、CPU 库和 HCU 示例，并运行基础自检时使用。
---

# PhysX-das HCU 编译

在仓库根目录执行以下命令。需要 Linux HCU 机器和 DTK 26.04；构建 GPU/CPU 库及 HCU 示例**不需要安装 PyTorch（torch）**，不要把 `pip install torch` 当作前置步骤。

```bash
source /opt/dtk/env.sh
export CMAKE_PREFIX_PATH="/opt/dtk/lib64/cmake:/opt/dtk${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
./build_hcu.sh
./build_cpu.sh
```

`build_hcu.sh` 优先通过 `rocminfo` 自动识别 HCU 架构，可用 `rocminfo | grep -m1 gfx` 核对。若构建环境无法识别架构，确认设备型号后显式传入匹配的架构，例如 `./build_hcu.sh gfx938`；不要将 `gfx936` 固定用于 `gfx938` 设备。脚本本身也会在 DTK 目录存在时补充 `CMAKE_PREFIX_PATH`。

构建产物为 `build_hcu/libPhysXGpuHCU.so`、`build_hcu/kernels/*.hsaco` 和 `build_cpu/` 中的 CPU 库。完成后运行基础自检：

```bash
./build_cpu/test_cpu
./build_hcu/test_functional
```

两项自检均应输出 `Results: 7 / 7 passed`。如需编译示例，先完成上述两个库的构建，再运行：

```bash
cd examples/hcu
./build.sh                 # 默认编译 bench_physx_scene
./build.sh bench_compare   # 编译指定示例；./build.sh all 编译全部示例
```
