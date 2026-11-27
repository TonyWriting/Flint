# 开发

Flint 由入口脚本、运行机制和模型工具三部分组成。`lib/` 是 Agent 的运行机制，负责对话、会话、权限和进程控制；`tools/` 是模型可以调用的具体能力，例如 `read_file`、`run_command`、`azure_request`，一个工具可以由多个脚本协作实现。运行机制在调度工具时调用 `tools/` 中的注册和实现。

## 代码布局

| 位置 | 职责 |
|---|---|
| `agent.ps1` | CLI 入口、模块加载、交互命令和 `-Setup` 入口。 |
| `lib/` | 对话循环、会话与轨迹、模型调用、上下文预算、权限匹配、工具执行与并行调度、进程控制和终端界面。System prompt 在 `lib/Config.ps1`。 |
| `lib/Plugins.ps1`、`lib/Setup.ps1` | 插件的校验与加载；配置文件夹的校验和 `-Setup`。 |
| `tools/Registry.ps1` | 模型工具的名称、参数 schema、使用说明和参数校验。 |
| `tools/Files.ps1`、`Reading.ps1`、`Searching.ps1` | 文件操作、分页读取和文本搜索。 |
| `tools/Commands.ps1`、`tools/permissions/` | kubectl 执行、受保护资源的修改约束，以及标准 Kubernetes 只读规则。 |
| `tools/azure/` | Azure 认证、授权和 ARM 请求。 |
| `tools/Worker.ps1` | 工具子进程的入口，校验请求后分派到具体工具。`read_file` 读取不超过 256 KiB 的文件时在主进程中直接执行，不启动子进程；更大的文件、目录列表和搜索的工作量没有上限，仍在子进程中执行，受工具时限约束，也能立即中止。 |
| `tests/` | 离线测试，目录与代码对应。 |

判断代码归属时看它负责什么：Windows 进程参数转义属于 `lib/Runtime.ps1`，Azure token 获取属于 `tools/azure/Auth.ps1`，kubectl 参数约束属于 `tools/Commands.ps1`。工具专用的代码即使被多处调用，也放在对应的工具目录。

`run_command` 按执行器（executor）组织：每次调用写明要运行的程序，只读规则和会话内的批准都按执行器分开保存，这部分在 `lib/Permissions.ps1` 中与具体程序无关。目前唯一的执行器是 kubectl，程序查找、参数约束和登录检测都在 `tools/Commands.ps1` 中按 kubectl 实现，插件清单也只有 `kubectl` 一项。增加执行器时，除了在 `tools/Registry.ps1` 放开 `executor` 的取值，还要为新程序实现这几部分，并提供它自己的只读规则文件。

## 运行测试

在 Flint 目录运行：

```powershell
powershell.exe -NoProfile -NonInteractive -File .\tests\Run.Tests.ps1

# Run one area while developing, by suite path relative to tests\.
powershell.exe -NoProfile -NonInteractive -File .\tests\Run.Tests.ps1 -Filter 'tools\azure\*'
```

`Run.Tests.ps1` 自动发现 `tests\` 下所有 `*.Tests.ps1`，新增的套件放进对应目录即可。每个套件在独立的 Windows PowerShell 5.1 进程中以 ConstrainedLanguage 运行，使用临时目录和模拟的模型、Azure 与 kubectl，因此不需要真实密钥，也不访问网络。设备自身的执行策略和真实的 Azure 登录仍需在目标环境中验证。

## 手动预览

自动测试模拟退出流程；在真实控制台中按下 `Ctrl+C` 的效果，由一个离线预览手动检查：

```powershell
powershell.exe -NoProfile -File .\tests\previews\Preview.Exit.ps1
```

按提示输入一条消息，收到回答后按 `Ctrl+C`。预览随后检查会话和 token 用量已完整保存，通过时显示 `Console exit verification passed`。加 `-ResumeSaved` 时，预览先恢复一段保存的对话，检查恢复后退出仍沿用同一个会话 ID。

## 持续集成

GitHub Actions 在每个 PR 和每次推送到 `main` 时运行同一个 `tests\Run.Tests.ps1`。
