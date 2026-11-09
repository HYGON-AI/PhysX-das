# PhysX-das HCU CI 说明

本文说明主仓当前的 [HCU 工作流](../.github/workflows/hcu-build.yml)：镜像如何保存、fork PR 如何自动触发 CI，以及构建和测试的判定方式。供贡献者和维护者讨论、排查问题使用。

## 先看结论

- 两个 DTK 镜像地址保存在主仓 **Settings → Secrets and variables → Actions → Variables**，变量名为 `DTK_IMAGE_PY310` 和 `DTK_IMAGE_PY312`。工作流只写变量名，不写镜像地址。
- 指向主仓 `main` 的 PR 创建、更新或重新打开后，包括 fork PR，都会自动触发 Python 3.10 和 3.12 两个 GPU 作业；**不需要添加 `ready-hcu` 标签**。
- GPU/CPU 库和 HCU 示例的**构建失败会让 CI 失败**。构建在 `hygon-build` 上完成，产物经共享的 `/ci_public` 交给 `hygon-bw1100-1card` 测试作业。探针和示例运行的失败会记入作业摘要，并继续执行其他检查；因此绿色 CI 表示构建和流程完成，**不代表每项运行测试都通过**。
- 编译和运行这些 HCU 示例不需要安装 PyTorch（`torch`）。

## 1. 镜像地址：Variable 还是 Secret？

| 项目 | Actions Variable | Actions Secret |
| --- | --- | --- |
| 用途 | 非敏感、可复用的配置，例如镜像地址 | 密码、令牌等敏感数据 |
| 读取方式 | `${{ vars.DTK_IMAGE_PY310 }}` 等 | `${{ secrets.NAME }}` |
| 页面和日志 | 变量值可在设置页面查看，日志默认不遮蔽 | Secret 加密保存，使用时 GitHub 会尝试在日志中遮蔽其原值；遮蔽并非绝对保证 |
| 当前 `container.image` | 支持 `vars` 和 `matrix` | 不支持直接使用 `secrets` 上下文 |

仓库维护者在 **Settings → Secrets and variables → Actions → Variables → New repository variable** 中创建两个变量；值分别是对应 Python 3.10、3.12 的 DTK 镜像地址。工作流的读取关系如下，实际地址无需出现在 YAML 中：

```yaml
matrix:
  include:
    - python: '3.10'
      image: ${{ vars.DTK_IMAGE_PY310 }}
    - python: '3.12'
      image: ${{ vars.DTK_IMAGE_PY312 }}
container:
  image: ${{ matrix.image }}
```

当前选择 **Variable**，因为需求是“不把镜像地址写入仓库文件”，而不是把地址对 PR 作者保密。矩阵将两个变量分别交给 `container.image`，形成两个并行作业。Docker 拉取镜像时，地址可能出现在 Actions 日志中；Variable 不提供日志保密能力。如果以后需要保存真正的凭据，应单独使用 Secret，并重新评估 PR 的信任边界。[GitHub Variables](https://docs.github.com/en/actions/concepts/workflows-and-actions/variables)、[Secrets](https://docs.github.com/en/actions/concepts/security/secrets)、[表达式上下文限制](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts)。

**容易混淆的一点：**能打开“New secret”页面，只说明可以新增 Secret；它不会改变 fork PR 的传递策略，也不能让当前工作流的 `container.image` 直接读取 Secret。私有仓库若想让普通 fork `pull_request` 工作流获得主仓变量，需要管理员调整 fork PR 策略中的“Send secrets to workflows from pull requests”（API 名称为 `send_secrets_and_variables`）。该设置同时放开 Secrets 和 Variables，并非只放开这两个镜像变量。当前方案已经实测可用，**不需要开启这个开关**。[私有仓库 fork 策略](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository)、[对应 API 字段](https://docs.github.com/en/rest/actions/permissions)。

## 2. 普通 `pull_request` 与当前 `pull_request_target` 有什么不同？

| | `pull_request` | `pull_request_target` |
| --- | --- | --- |
| 工作流文件来自哪里 | PR 的合并结果 | 主仓默认分支的受信任工作流 |
| 默认检出什么 | PR 的合并结果 | 主仓默认分支；若要测试 PR，必须显式取 PR 代码 |
| fork PR 的主仓配置 | 私有仓库的 fork PR 默认受传递策略限制；此前镜像变量为空 | 在主仓上下文运行，可读取主仓的镜像 Variables |
| 主要风险 | PR 可以修改本次执行的工作流，但 fork 权限受到限制 | 若随后运行 fork 的代码，代码将接触到信任级别更高的执行环境 |

最初使用 `pull_request` 时，fork PR **确实触发了**两个矩阵作业，但没有得到主仓镜像变量，容器未按预期初始化。由此可见，“PR 能触发工作流”和“工作流能取得镜像并跑 GPU 构建”是两件事。

现在使用 `pull_request_target`，工作流本身来自主仓 `main`，所以可以取得主仓变量。不过它默认只检出主仓代码。当前工作流在 PR 事件触发后固定主仓与 PR 的提交 SHA，用只读 `GITHUB_TOKEN` 临时拉取 PR 提交、核对 SHA，再合并到工作目录中编译。检出步骤设置了 `persist-credentials: false`，取 PR 代码所用的 token 只在该步骤提供。[GitHub 事件说明](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows)。

## 3. fork PR 如何自动启动？

此前使用 `ready-hcu` 是为了让维护者审核后再占用 GPU runner。现在为了避免忘记贴标签，已移除这道人工门控：`opened`、`synchronize`、`reopened` 事件直接启动构建。`pull_request_target` 能访问主仓上下文，工作流随后会在**自托管 GPU runner 的特权容器**中编译和运行 PR 代码。只读 token 和提交 SHA 校验仍保留，但自动执行 fork 代码增加了 runner 风险；对私有仓库的 fork 权限、runner 隔离和可执行的 PR 代码应持续管理。[GitHub 的 `pull_request_target` 安全说明](https://docs.github.com/en/actions/reference/security/securely-using-pull_request_target)。

完整顺序：

1. 有权访问并 fork 此私有仓库的贡献者，把提交推到自己的 fork，发起目标为 `HYGON-AI/PhysX-das:main` 的 PR。
2. `opened`、`reopened` 或新提交的 `synchronize` 事件启动 `validate_pr`。它检查 PR 仍开放、目标仍是 `main`、提交 SHA 未变、两个镜像变量存在；检查通过后直接放行 GPU 作业。
3. Python 3.10 和 3.12 构建作业在 `hygon-build` runner 上启动。作业检出事件对应的主仓提交、拉取并核对该 PR 提交，然后编译。每套产物保存到 `/ci_public/PhysX-das/runs/<run_id>/<attempt>/py<版本>/`。
4. 两套构建都成功后，Python 3.10 和 3.12 测试作业在 `hygon-bw1100-1card` runner 上分别启动，核对 PR 提交 SHA、恢复对应版本的产物，再运行探针和示例。
5. PR 后续又有新提交时，新的 `synchronize` 事件自动触发新一轮 CI，无需移除或添加标签。

贡献者不需要在自己的 fork 中复制这两个镜像变量，也不需要为主仓 PR CI 启用 fork 自己的 Actions；PR 事件发送到主仓，作业在主仓运行。但贡献者必须有权限 fork 私有仓库，主仓和组织策略也必须允许相关 PR 事件。[fork PR 事件位置](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows)。

## 4. 触发后固定执行什么？

两个镜像使用相同的构建和测试步骤：

1. 加载 `/opt/dtk/env.sh`，为编译设置 `CMAKE_PREFIX_PATH=/opt/dtk/lib64/cmake:/opt/dtk:...`。
2. 在仓库根目录运行 `./build_hcu.sh`，检查 `build_hcu/libPhysXGpuHCU.so` 和 `build_hcu/kernels/*.hsaco`；再运行 `./build_cpu.sh`。这些都是**阻断性构建检查**。
3. 在 `examples/hcu` 运行 `./build.sh`、`./build.sh all` 和 `./build.sh bench_compare`。示例**编译失败会阻断 CI**。
4. 将 `build_hcu/`、`build_cpu/`、`examples/hcu/build/` 打包到共享目录；测试作业按同一次运行、同一次尝试和对应 Python 版本恢复产物。
5. 分别运行 `./build_cpu/test_cpu` 和 `./build_hcu/test_functional`，再设置 HCU 模块路径，运行 `bench_physx_scene` 和 `bench_compare`。探针与示例运行均设为 `continue-on-error`；其真实结果写入作业摘要，后续步骤照常执行。

详细的本地编译命令和“不需要安装 torch”的说明见 [HCU 编译 Skill](../.agents/skill/hcu-build/SKILL.md)。

## 5. 常见误解与排查

- **“我提交 fork PR 后，为什么没有立刻开始 GPU 作业？”** 查看 `validate_pr` 是否通过、两个 Variables 是否存在，以及 `hygon-build` 和 `hygon-bw1100-1card` runner 是否可用。测试作业会等待两套构建成功，runner 忙时也会排队；现在不需要 `ready-hcu`。
- **“我推送新提交后需要重新贴标签吗？”** 不需要。`synchronize` 事件会自动触发新一轮 CI。
- **“绿色 CI 是否表示 CPU/GPU 比较完全一致？”** 不表示。构建是阻断项，运行测试是非阻断项；查看作业摘要和测试日志中的 `VERDICT`。此前曾出现 `bench_compare` 的 `MISMATCH`，它没有在本方案中被当作功能修复。
- **“FastPT 为什么能跑？”** [FastPT 的工作流](https://github.com/HYGON-AI/FastPT/blob/v2.12/.github/workflows/pr-test.yml)使用维护者标签配合 `pull_request_target`；PhysX-das 目前保留相同的主仓事件上下文，但改为自动触发。此前的 [临时 fork PR #4](https://github.com/HYGON-AI/PhysX-das/pull/4) 验证了标签版本能取得主仓变量并完成两套构建；自动版本以新的无标签 fork PR 验证记录为准。

工作流和 GitHub/组织策略以后若改变，应重新做一次真实 fork PR 验证。
