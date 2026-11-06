# Flint

轻量 Windows Agent，用于查询 Azure／Kubernetes 配置、查看本地文件和执行获准的修改。仅支持 **Windows PowerShell 5.1**，入口拒绝其他版本，允许 5.1 的系统补丁版本。支持 ConstrainedLanguage，语言模式由设备策略决定。

项目目录：`Q:\src\Flint`。

## 代码布局

`lib/` 放通用 Agent 框架，包括对话循环、会话、模型调用、权限机制、进程控制、日志和 UI。`tools/` 放具体工具及其注册和 worker 入口；Azure 专用代码集中在 `tools/azure/`：

| 文件 | 职责 | 加载进程 |
|---|---|---|
| `tools/azure/Auth.ps1` | Azure CLI 登录、身份检查、token 缓存与刷新 | 主进程 |
| `tools/azure/Controller.ps1` | Azure 调用授权、认证状态处理和 worker 调度 | 主进程 |
| `tools/azure/Http.ps1` | ARM 请求校验、共享 HTTP 执行和响应处理 | 主进程与 worker |
| `tools/azure/KeyVault.ps1` | Key Vault 元数据请求校验和响应字段筛选 | 主进程与 worker |

目录按功能职责组织。主进程在启动 worker 前完成授权，worker 只加载请求执行所需的模块。

## 启动

将项目中的 [.env.example](.env.example) 复制为同目录的 `.env`，填写：

```dotenv
AZURE_OPENAI_ENDPOINT="https://<resource>.services.ai.azure.com/openai/v1/responses"
AZURE_OPENAI_API_KEY="<your-key>"
AZURE_OPENAI_DEPLOYMENT="<your-deployment>"
```

Endpoint 必须是完整 HTTPS 地址，以 `/openai/v1/responses` 结尾，不含凭据、查询参数、fragment 或结尾斜杠。`.env` 必须存在；可用 `-EnvFile` 指定其他文件。文件中的值优先于同名环境变量，缺少配置时停止启动。

从希望处理文件的目录启动，**启动时的当前目录就是工作目录**：

```powershell
$flint = 'Q:\src\Flint\agent.ps1'
powershell.exe -NoProfile -File $flint

# Ask one question and exit.
powershell.exe -NoProfile -File $flint -Prompt 'Summarize the logs in this directory.'

# Resume from the original working directory using the saved session ID.
powershell.exe -NoProfile -File $flint -Resume '<session-id>'
```

文件工具无需额外模块。Azure 工具使用 PATH 中的 Azure CLI 完成认证，再通过 Windows PowerShell 5.1 原生 HTTP 客户端调用 Azure Resource Manager（ARM，Azure 资源管理接口）。Azure CLI 需支持 `az account get-access-token` 的 `expires_on` 字段。Kubernetes 使用 PATH 中已配置的 `kubectl`。设备需允许脚本、Azure CLI、`kubectl` 及 `taskkill.exe` 运行，并具备对应网络访问权限和 TLS 1.2 及以上支持。

## Azure 登录与访问范围

启动时先通过 `az account show` 读取 Azure CLI 当前用户身份，再用 `az account get-access-token --tenant <tenant> --resource https://management.azure.com/` 验证登录是否可用。可用时直接复用；需要认证时，在交互终端中最多执行一次 `az login --tenant <tenant> --allow-no-subscriptions`。Flint 直接调用安装好的 `az.cmd` 或 `az.exe`；登录状态由 Azure CLI 的标准缓存管理。

本次 Flint 运行固定使用启动时选定的账户和 tenant，认证独立于 subscription。token 在进程内复用，剩余有效期不足 5 分钟时按同一 tenant 从 CLI 缓存重新获取，并核对用户身份。CLI 默认订阅的变化不影响这个 token。若 MFA、Conditional Access 或登录撤销要求再次交互，Azure 工具返回 `authentication_required`，用户重新启动 Flint 完成登录；会话中途不调用 `az login`。Azure RBAC 权限不足返回 HTTP 403，保留当前登录。

启动参数 `-AzureTenant` 接受 tenant GUID 或完整域名，例如 `contoso.onmicrosoft.com`。省略时使用当前 CLI 用户记录中的 tenant；尚未登录时由登录流程确定 tenant。启动和刷新 token 均无需选择或校验 subscription；每次 ARM 请求在路径中指定目标订阅。

Flint 仅在执行登录命令时临时设置 `AZURE_CORE_LOGIN_EXPERIENCE_V2=off`，关闭 CLI 的订阅选择菜单；命令结束后恢复原环境变量。该设置不修改用户的全局 CLI 配置，CLI 自身仍可能在后台发现可访问的订阅。

```powershell
powershell.exe -NoProfile -File .\agent.ps1 -AzureTenant 'contoso.onmicrosoft.com'
powershell.exe -NoProfile -File .\agent.ps1 -AzureTenant '<tenant-guid>'

# Use only file and Kubernetes tools, without invoking Azure authentication.
powershell.exe -NoProfile -File .\agent.ps1 -NoAzure
```

缺少 Azure CLI、设备策略阻止 CLI 或用户取消登录时，Azure 工具不可用，文件和 Kubernetes 工具仍可使用。非交互启动只能复用有效登录。`/status` 显示 Azure 状态、账户和 tenant；`-Resume` 启动的新进程重新检查 CLI 登录。

`azure_request` 访问 Azure 公有云的 `https://management.azure.com`，用于查询或修改资源配置。例如 Key Vault 的位置、SKU、网络和访问策略属于**管理平面**。每个请求显式提供资源路径和 API version，同一 tenant 下访问其他订阅无需切换登录，仍由 Azure RBAC 校验权限。

`keyvault_list_secrets` 读取 Key Vault **数据平面的 secret 名称与元数据**。它只接受 `vault_name` 和 `next_link`，固定请求同一 vault 的 `/secrets` 列表接口，使用 API version `2025-07-01`；不接受单个 secret 的读取路径、HTTP method 或 body。首次调用传空 `next_link`，之后原样传入工具返回的分页链接。列表包含禁用的 secret，不包含已删除对象或各个版本。

每页最多 25 项，返回 `names`、`page_count`、`has_more`、`next_link` 和文件引用。只有第一页同时也是最后一页时才返回 `total_count`；多页列表必须读取全部页后汇总各页的 `page_count`，同一页只计数一次。写入文件前，工具只保留 `name`、`id`、`managed`、`enabled`、`created`、`updated`、`exp`、`nbf` 中类型符合要求的字段；secret 内容、自由文本标签和原始错误响应不进入文件或上下文。

Key Vault token 使用 audience `https://vault.azure.net`，与 ARM token 分开缓存，按需静默获取和刷新，工具调用期间不发起交互登录。该工具仍需要账户具备 `secrets/list` 权限，或在 RBAC 模式下具备 `Key Vault Reader` 等相应数据权限，同时满足 vault 的网络访问限制。

## Azure 响应文件

`azure_request` 取得 HTTP 响应正文后，将**完整正文先脱敏，再保存到工作目录的 `.flint/results/<session-id>/<result-id>.json`**。可解析的 JSON 对象或数组按缩进保存；其他正文使用 `.txt`，包括空响应和无法解析的错误正文。保存不受预览长度限制；文件中的凭据值已被替换为 `[redacted]`。HTTP 错误没有可读取的正文时，返回状态码及错误说明。`keyvault_list_secrets` 仅保存字段白名单内的元数据，复用同一结果目录和读取工具。

`azure_request` 向模型返回 HTTP 状态、`result_id`、`result_path`、文件大小、`content_chars`、`item_count`、`next_link` 和最多 **2,048 个字符的正文预览**。`preview_truncated` 只说明预览不完整；完整正文保留在文件中。History、轨迹和会话快照只记录这些小结果，不自动加入完整文件。

模型需要细节时调用 `read_result(result_id, start_line, start_column, max_lines)`，首次从第 1 行、第 1 列开始，通常读取 200 行。每次最多返回 32,768 个字符；按 `next_line`、`next_column` 继续读取。工具只能读取本 session 的结果 ID，普通文件工具仍不能读取或修改 `.flint`。`-Resume` 可以继续读取同一 session 的文件；文件在退出和 `/clear` 后保留，用户可自行清理。

**文件分页与服务分页分别处理。** `read_result` 翻阅已经保存的单次响应；`next_link` 指向服务的下一页，需要继续调用产生该结果的工具：ARM 使用 `azure_request`，secret 元数据使用 `keyvault_list_secrets`。`item_count` 只统计当前响应根数组或 `value` 数组的条目。ARM 超过 8,192 字符的分页链接保留在正文文件中，不额外放入返回字段；Key Vault 元数据工具拒绝超过此长度的分页链接。

读取保存结果不会重新发起 Azure 请求。响应文件写入失败时，工具保留已收到的 HTTP 状态并报告错误，Flint 不因此重复请求。编写解析脚本或自动化代码统一使用 **Windows PowerShell 5.1**，并兼容 ConstrainedLanguage；当前工具提供文件分页读取，通用脚本执行不在工具范围内。

## 工具与授权

| 工具 | 参数与用途 |
|---|---|
| `list_files` | `path`：列出一层目录，最多 200 项。 |
| `read_file` | `path`、`start_line`、`start_column`、`max_lines`：分页读取文本。 |
| `read_result` | `result_id`、`start_line`、`start_column`、`max_lines`：分页读取本 session 已保存的 Azure 响应。 |
| `write_file` | `path`、`content`：用完整内容新建或覆盖文件。 |
| `edit_file` | `path`、`old_str`、`new_str`：替换唯一匹配的非空文本，新旧文本须不同。 |
| `create_directory` | `path`：创建目录，已存在时成功返回；父目录必须存在。 |
| `run_command` | `executor`（`kubectl`）、`arguments`（字面参数数组）、`purpose`（用途说明）：执行命令。 |
| `azure_request` | `method`、`path`（含 `api-version` 的 ARM 路径）、`body`（JSON 字符串，无请求体时传空字符串）、`purpose`（用途说明）：发送 REST 请求，保存正文并返回预览与文件引用。 |
| `keyvault_list_secrets` | `vault_name`、`next_link`（第一页传空字符串）：分页列出 secret 名称、数量与元数据，禁止读取内容。 |

读取自动执行。工作目录及子目录内的文件写入直接执行，外部写入需要**目录及其子目录的本 session 授权**。Kubernetes 命令匹配 Git 中的只读规则时自动执行；Azure GET 和符合精确规则的 Resource Graph POST 查询自动执行。其他命令及请求需 `y/n` 确认，同一 session 仅复用完全相同调用的授权。Azure 授权还绑定账户和 tenant。新 session 不继承授权；需要确认但无法交互时返回 `approval_required`。匹配方式和配置位置见 [[ToolPermissions|工具调用与权限]]。

`run_command` 和 `azure_request` 每次调用都必须由模型提供 `purpose`：使用用户语言、单行、1～1,000 个字符，说明目标、想查询或修改的内容及预期影响；影响不明确时说明不确定性。审批界面先显示标为 `Purpose (model-provided)` 的说明，再显示完整命令或 HTTP 请求。只读分类由执行层规则决定，说明文字不授予权限，也不改变实际调用的授权匹配。

## 文件限制

文本通常从第 1 行、第 1 列读 200 行；`max_lines` 上限 2,000，单次最多 32,768 个 UTF-16 字符。`truncated` 为 true 时，按 `next_line`、`next_column` 续读。超过 256 KiB 的文件流式读取并将换行统一为 LF（`line_endings_normalized`）；小文件保留原始换行。读取仍受工具超时限制。

写入要求父目录存在，已有文件最多 256 KiB，最终内容最多 65,536 个字符。以 UTF-8 BOM 写入，不额外添加换行，写后重新读取校验。文件工具处理文本，不支持二进制文件。

路径支持相对路径和本地盘符绝对路径，输入及解析后的路径均最多 240 个字符。拒绝 UNC、通配符、NTFS 备用数据流、设备名、符号链接及 junction。凭据路径（如 `.env`、`.env.*`、`.ssh`、`.kube`、`.azure`、常见私钥）、`.git`、`.flint`、当前配置和轨迹路径受保护。Flint 自身的 `agent.ps1`、`lib/`、`tools/` 允许读取，禁止由文件工具改写；目录授权不能解除这些保护。

## 会话与运行限制

交互界面中，`Flint` 标签为金黄色，正文为亮白色，绿色专用于用户输入，回复中的代码为浅蓝色；恢复的历史对话沿用同一配色。颜色统一在 [lib/Console.ps1](lib/Console.ps1) 中维护。

`/help` 查看帮助，`/status` 查看详细状态，`/clear` 清空模型对话，`/exit` 退出。`Ctrl+C` 中止并退出，清理子进程、保存会话并显示 token 用量和继续命令。已经发生的写入会保留；结果不明确时先查询实际状态。

轨迹默认保存在**工作目录**的 `.flint/trajectories/`，记录对话、工具调用、授权、重试和用量。`-TrajectoryDirectory` 可更改位置。`-Resume` 沿用原 session ID，恢复对话与累计用量；`/clear` 保留轨迹、用量和授权。凭据在显示及记录前脱敏，当前 API Key 不写入快照；轨迹写入失败时停止后续动作。

Flint 目录的 `.env`、`.env.*` 和 `.flint/` 已被 Git 忽略，配置模板 `.env.example` 保留在仓库中。从其他仓库目录启动时，也需在该工作目录忽略 `.flint/`。`-TrajectoryDirectory` 只改变轨迹位置，Azure 响应文件始终保存在工作目录的 `.flint/results/`。

| 参数或限制 | 默认值／上限 |
|---|---|
| `-ReasoningEffort` | `medium` |
| `-MaxTurns`／`-MaxToolCalls` | 每次用户输入最多 20 轮、40 次工具调用 |
| `-RequestTimeoutSec`／`-ToolTimeoutSec` | 模型 180 秒、工具 30 秒；包括重试，授权等待不计入工具超时 |
| `-MaxOutputTokens`／`-ContextWindow` | 输出 4096 tokens；上下文 `0` 表示上限未知，可按部署设置 |
| 模型请求体／工具参数 JSON | 最多 500,000／131,072 个字符 |
| Azure 请求路径／JSON body | 最多 8,192／65,536 个字符 |
| Azure 响应预览／保存的 JSON 结构深度 | 最多 2,048 个字符／100 层；解析器无法读取的正文按文本保存 |
| 原生进程输出／模型可见工具输出 | 最多 1 MiB／32,768 个字符 |

文件、保存结果读取、Kubernetes 和 Azure HTTP 请求使用独立的 Windows PowerShell 5.1 进程，超时或取消时清理进程树。Azure worker 使用 `Invoke-WebRequest -UseBasicParsing`，固定请求 ARM 主机并禁用重定向。token 仅经启动该 worker 时的临时环境变量传递，worker 立即清除该变量；token 不写入参数、临时请求文件、轨迹或模型上下文。

HTTP 客户端在 worker 内存中缓冲完整响应，Flint 随后脱敏、保存并生成预览；响应落盘控制的是模型上下文大小，HTTP 正文没有 1 MiB 采集限制。CLI 登录和取 token 命令同步执行，等待由 CLI 自身控制；取 token 返回后若工具预算已耗尽，Flint 不发送 HTTP 请求。

模型请求、匹配 Git 只读规则的命令、Azure GET 和已审核的 Resource Graph POST 查询遇到可重试的临时错误时，Flint 按 1、2、4 秒退避，最多重试 3 次。Flint 不自动重试 session 授权的操作和文件写入。Azure HTTP 202 表示已接受请求，需继续查询状态才能确认完成；超时或取消的修改同样需先查询实际状态。达到上下文限制时停止，由用户缩小问题或 `/clear`。

## 验证

在 Flint 目录运行；测试使用临时文件和模拟响应，无需真实密钥，不访问 Azure 或集群：

```powershell
powershell.exe -NoProfile -NonInteractive -File .\tests\Run.Tests.ps1

# Optional offline terminal previews.
powershell.exe -NoProfile -File .\tests\Preview.Ui.ps1
powershell.exe -NoProfile -File .\tests\Preview.Exit.ps1
```

测试在 Windows PowerShell 5.1 的 ConstrainedLanguage 下覆盖入口版本、文件分页与权限、Azure CLI 登录复用、完整响应保存与分页读取、REST 授权、命令执行、重试、取消、退出和会话恢复。Azure 测试使用本地 CLI 启动器和模拟 HTTP 响应；设备自身的执行策略和真实登录行为仍需在目标环境验证。
