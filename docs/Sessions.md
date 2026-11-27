# 会话

每次启动 Flint 都会开始一个**会话**（session）。会话有一个 ID，保存从第一个问题起的完整对话：你的提问、模型的回答，以及每次工具调用的结果。模型服务本身不保存对话，Flint 每次请求模型时都把这段对话一起发送。退出时，Flint 显示 token 用量和继续这个会话的 `-Resume` 命令。

## 中止与继续

Flint 工作时，进度行显示 `Working (12s · s to stop · Ctrl+C to exit)`。按 `s` 只中止**当前这一轮**，会话保留并回到输入提示：

- 读取类工具和模型请求立即中止，并结束对应的子进程。文件读取和目录列表在主进程中执行，每次只读一页，读完这一页再中止。
- 正在执行的写操作（文件写入、修改类的 kubectl 命令和 Azure 请求）先执行完，期间进度行显示 `Stopping after the current step`。这样每个修改的结果都是明确的。
- 同一批中尚未开始的工具调用不再执行，结果记为 `skipped`。

按 `Ctrl+C` 则立即中止并退出：Flint 结束所有子进程，保存会话，显示 token 用量和继续用的 `-Resume` 命令。正在执行的写操作可能已经生效，也可能没有，它的结果记为未确认。

中止后对话保持完整。Flint 在对话中为模型记下这一轮被用户中止，以及哪些结果已经确认、哪些没有。之后你可以直接输入新的指令改变方向，也可以输入 `/c`，让模型先核实未确认步骤的实际状态，再接着完成原任务。`Ctrl+C` 中断的那一轮同样留有这条记录，所以用 `-Resume` 恢复会话后也可以用 `/c` 继续。

`s` 不区分大小写。Flint 工作期间按下的其他键都会被丢弃，因此不能提前输入下一条消息。审批提示、Azure 登录期间以及非交互模式下，`s` 不起作用。

## 上下文预算

对话越长，每次发给模型的请求越大，单次请求最多 2,000,000 个字符。请求超过这个上限的 60% 时，Flint 从最早的工具结果开始，把模型已经读过的较大结果替换为占位，终端显示一行 `Context trimmed`。占位告诉模型怎样找回原文：保存在 `.flint/results/` 中的 Azure 和 kubectl 结果可以用 `read_file` 原样重新读取，普通文件也可以重新读取，但内容可能已经改变。替换只影响发给模型的内容，轨迹仍保留完整结果。替换之后请求仍接近上限时，Flint 提示一次 `Context is nearly full`，建议完成当前任务后开始新会话；请求超过上限时，这一轮以错误结束，需要缩小问题范围、开始新会话。`/status` 显示当前请求的字符数和已替换的结果数。

## 工具并行执行

模型可以在一次回复中提出多个工具调用。同一批中连续的只读调用（文件读取与搜索、Azure GET、符合规则的 Resource Graph 查询、匹配只读规则的 kubectl 命令）分组并行执行，每组默认最多 4 个，`-MaxParallelTools` 可设为 1～8，设为 1 时全部串行。写入和其他需要审批的调用按顺序执行，并等前面的读取完成。例如“读取 A、读取 B、修改 A、再次读取 A”中，前两个读取并行，修改等它们结束，最后的读取等修改完成。哪些调用可以并行由 Flint 的[权限规则](ToolPermissions.md)决定，每个工具在独立的 Windows PowerShell 5.1 进程中运行，一个工具失败或超时不影响同组其他工具的结果。

## 轨迹

Flint 把会话记录为**轨迹**，默认保存在工作目录的 `.flint/trajectories/`，每个会话一个文件，每行一个事件，只追加不修改。轨迹记录对话、工具调用、审批、重试和 token 用量；凭据在写入前脱敏，API key 不会写入。`-TrajectoryDirectory` 可以更改轨迹位置，Azure 和 kubectl 的结果文件仍保存在工作目录的 `.flint/results/`。轨迹无法写入时，Flint 停止后续动作。`-Resume <session-id>` 从轨迹恢复对话和用量，需要在原来的工作目录中运行；恢复的会话使用当前安装的插件，并且不带之前的审批。工作目录是 Git 仓库时，把 `.flint/` 加入它的 `.gitignore`。

每个事件都带时间戳。`model_response` 和 `tool_finished` 事件另有一个与 `data` 并列的 `timing` 字段，记录耗时分解，用来判断慢在哪一步：

| 事件 | 字段 | 含义 |
|---|---|---|
| `model_response` | `attempt_ms` | 这次请求的全程；`duration_ms` 还包括之前失败的尝试和重试等待 |
| | `prepare_ms` | 生成请求并写入临时文件 |
| | `process_ms` | 模型请求子进程从启动到输出收齐 |
| | `worker.load_ms`、`worker.request_ms` | 子进程加载 Flint 脚本、读取请求 |
| | `worker.serialize_ms`、`worker.http_ms` | 序列化请求、等待模型服务返回 |
| | `read_ms` | 读取并解析响应 |
| `tool_finished` | `total_ms` | 工具调用全程，包括等待审批 |
| | `process_ms` | 工具子进程从启动到输出收齐 |
| | `worker.load_ms`、`worker.run_ms` | 子进程加载 Flint 脚本、执行工具，包括保存结果 |
| | `worker.call_ms` | 其中 kubectl 进程或 Azure HTTP 请求本身 |
| | `read_ms` | 读取子进程返回的结果 |
| | `in_process_ms` | `read_file` 和 `list_files` 在主进程中执行的时间；它们不启动子进程，所以没有上面几项 |

启动进程、退出和等待检测的开销，对工具调用是 `process_ms - worker.load_ms - worker.run_ms`，`worker.call_ms` 已包含在 `worker.run_ms` 中；对模型调用是 `process_ms - worker.load_ms - worker.request_ms - worker.serialize_ms - worker.http_ms`。没有交互终端时，模型请求在主进程中完成，`serialize_ms` 和 `http_ms` 直接位于 `timing` 下。

## 命令行参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `-ReasoningEffort` | `medium` | 推理强度：`none`、`low`、`medium`、`high`、`xhigh` 或 `max`。 |
| `-MaxTurns` | `20` | 每次输入最多的模型轮数，1～1000。 |
| `-MaxToolCalls` | `40` | 每次输入最多的工具调用次数，1～200。 |
| `-MaxParallelTools` | `4` | 每组并行的只读工具数，1～8。 |
| `-RequestTimeoutSec` | `180` | 一次模型请求的时限（秒，含重试），1～300。 |
| `-ToolTimeoutSec` | `30` | 一次工具调用的时限（秒，含重试，不含等待审批），1～300。 |
| `-MaxOutputTokens` | `4096` | 每次模型回复最多的 token 数，256～32768。 |
| `-ContextWindow` | `0` | 模型部署的上下文 token 上限；设置后，估算的请求加上输出预留超过它时停止。`0` 表示不检查。 |
| `-TrajectoryDirectory` | `.flint/trajectories/` | 轨迹保存位置，默认在工作目录下。 |
| `-NoAzure` | 关闭 | 跳过 Azure 登录，只使用文件和 Kubernetes 工具。 |

退出时显示的 `-Resume` 命令会带上与默认值不同的参数。
