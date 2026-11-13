# 工具调用与权限

[[README#工具与授权|Flint 的工具]] 由模型提出调用，Harness（实际执行工具的程序）检查权限。Azure GET 和符合精确规则的 Resource Graph POST 查询自动执行；Kubernetes 命令的只读分类由 Git 中的规则决定。

**入口仅限制 Windows PowerShell 5.1，不检查或强制设置语言模式**。权限校验、进程调度和工具实现使用 ConstrainedLanguage 下可用的能力，语言模式由运行环境和设备策略决定。

并行资格复用这些执行层规则：固定文件读取工具、Key Vault 元数据查询和匹配只读规则的请求可以并行。session 批准的未分类操作继续串行，模型提供的 `purpose` 不改变分类。写操作和 Azure 异步状态轮询会等待前面的读取组完成；审批和日志由主进程统一管理。并发上限与终端显示见 [[README#工具并行执行|工具并行执行]]。

## 授权存在哪里

以下路径均相对于 Flint 项目目录：

| 位置 | 内容与范围 |
|---|---|
| `tools/permissions/kubectl.json` | 提交到 Git，只能包含已审核的只读规则，必须标明 `read_only: true`。 |
| `.flint/permissions/<session-id>/kubectl.json` | 被 Git 忽略，保存本 session 批准的完整命令。 |
| `.flint/permissions/<session-id>/azure.json` | 被 Git 忽略，保存本 session 批准的账户、tenant、HTTP method、完整 URI 和 body。 |
| `.flint/permissions/<session-id>/files.json` | 被 Git 忽略，保存本 session 获准写入的目录。 |

命令匹配只读规则时自动执行；规则文件损坏或含非只读规则时停止。其他命令先查本 session 授权，没有匹配项就展示完整调用并询问 `y/n`：`y` 保存并执行，`n` 不保存、不执行。无法交互时返回 `approval_required`；等待确认不占执行超时。

**新 session 不继承授权。** `-Resume` 沿用同一 ID 时可复用。批准过的写命令可以在本 session 内重复执行，但不会成为只读规则，也不自动重试。

## 什么是相同命令

**Git 规则按已知结构匹配。** 命令词必须在开头，之后的选项可以换顺序，也支持 `--name=value`。参数值需满足规则；未登记、重复或缺少必填参数都不能命中。例如下面的规则允许查询 cluster 的 ns namespace 下的 pods：

```json
{
  "version": 1,
  "executor": "kubectl",
  "rules": [{
    "command": ["get", "pods"],
    "read_only": true,
    "options": {
      "--context": {"required": true, "values": ["cluster"]},
      "--namespace": {"required": true, "values": ["ns"]}
    }
  }]
}
```

`values` 限定固定值，`pattern` 用正则检查可变值，`switch: true` 表示无值开关。命令后的位置参数由 `positionals.max` 和 `positionals.pattern` 限定。

**session 授权要求完整调用一模一样。** Kubernetes 的执行工具、参数值及顺序、工作目录、解析后的程序路径、相关环境变量均须相同。引用文件的内容不额外比较。

Azure 只接受 `https://management.azure.com` 下的 ARM 路径，必须含一个明确的 `api-version`。Resource Graph 的只读 POST 规则精确匹配 `/providers/Microsoft.ResourceGraph/resources?api-version=<version>`，允许版本为 `2021-03-01`、`2022-10-01`、`2024-04-01`，不允许附加 URL 参数、编码路径或子路径。body 必须是 JSON 对象，`query` 为非空字符串；其他顶层字段只允许 `subscriptions`、`managementGroups`、`options`、`facets`，并检查其基本类型。

该接口执行资源查询。保存、修改或删除查询定义使用其他专用接口，继续要求审批；其他 POST、PUT、PATCH、DELETE 同样要求授权。判断不依赖 KQL 中的关键词或模型提供的说明。授权绑定账户、tenant、method、URI 和 body 的原始字符串；任何一项变化都重新确认。GET 与 DELETE 的 body 必须为空。工具拒绝模型提供的认证 header 或凭据；认证统一由 [[README#Azure 登录与访问范围|启动时的 Azure 登录]] 提供。

异步操作的 `poll_path` 经过同样的 ARM 路径和 API version 校验。状态查询复用自动获准的 GET，保持账户和 tenant 不变；执行层根据已保存的工具结果识别轮询方式并遵循等待时间。每次查询都单独记录，不重复原始修改，也不会因响应头指向其他主机而扩大访问范围。详见 [[README#Azure 异步修改|Azure 异步修改]]。

`keyvault_list_secrets` 是独立的固定只读工具，自动执行。它使用 Key Vault audience 的 token，只能访问指定 vault 的 `/secrets` 列表接口；分页 URL 必须保持同一主机、同一路径和允许的查询参数。工具 schema 不包含单个 secret 名称、HTTP method 或 body。成功响应经字段白名单筛选后才写入结果文件，错误响应正文不保存。Azure 的数据访问权限和网络规则继续生效。

## 审批说明

模型在 `run_command` 和 `azure_request` 的 `purpose` 字段中提供请求用途、目标和预期影响，使用用户语言，限制为 1～1,000 个字符的非空单行文本。缺失字段、纯空白、超长内容或控制字符会在审批前被拒绝。

需要审批时，界面展示 `Purpose (model-provided)` 和实际请求，轨迹同时记录说明。说明只供用户理解，不参与只读判断，不传给原生程序或 Azure HTTP API；session 授权仍按实际调用匹配，单纯改写说明不会改变授权范围。

## Azure 响应文件权限

响应正文经脱敏后由 Harness 保存到工作目录的 `.flint/results/<session-id>/`；模型提供的参数不能指定保存位置。`read_file` 和 `search_text` 直接使用返回的 `result_path`。执行层根据工作目录和当前 session ID 自动允许读取、搜索和列出这个结果目录，恢复相同 session 后授权范围保持一致。路径仍拒绝符号链接、junction 和备用数据流，规范化后的路径不能越出允许范围。

Flint 仓库内所有文件的读取授权继续适用，包括其他 session 的结果；仓库外其他 session 的结果、轨迹及权限文件继续受保护。写操作始终禁止改写 `.flint`。返回字段与分页方式见 [[README#Azure 响应文件|Azure 响应文件]]。

## 文件读取与搜索

`read_file`、`list_files` 和 `search_text` 自动执行，统一使用路径参数。Flint 安装目录及当前 session 结果目录内的所有普通文本文件均可读取；现有输出脱敏规则继续适用。范围由执行层根据实际安装目录、当前 session 和解析后的目标路径判断，符号链接、junction、备用数据流及其他受限路径语法仍被拒绝。其他位置沿用原有凭据和内部文件保护。文件名过滤、目录分页和关键词搜索见 [[README#文件查找与关键词搜索|文件查找与关键词搜索]]。

## 本地目录写授权

读取文件和列目录自动执行。`write_file`、`edit_file`、`create_directory` 在启动时的工作目录及其子目录内直接执行。

外部写入需批准**目标目录及其子目录**，授权覆盖其中的不同文件，不覆盖相邻目录。创建外部目录时，授权范围是新目录及其子目录，父目录必须存在。写操作对凭据、运行代码和权限文件的保护始终有效，具体限制见 [[README#文件限制|文件限制]]。

## 维护入口

`tools/Registry.ps1` 注册工具并校验参数；`lib/Permissions.ps1` 匹配 Kubernetes 规则并保存授权。Azure 专用代码集中在 `tools/azure/`：`Auth.ps1` 负责选择 Azure CLI 或 Azure PowerShell 认证来源、登录、身份检查和 token 缓存，`Controller.ps1` 负责授权及 worker 调度，`Http.ps1` 校验 ARM 请求并执行 HTTP 调用，`KeyVault.ps1` 校验元数据列表请求并筛选响应字段。`tools/Results.ps1` 负责响应脱敏、落盘和结果目录定位。worker 会再次检查请求与获准调用是否一致。

主进程加载 Azure 的四个模块；worker 只加载 `Http.ps1` 和 `KeyVault.ps1`，登录与授权逻辑由主进程执行。完整目录职责见 [[README#代码布局|代码布局]]。

`tools/Searching.ps1` 与读取工具共用路径校验，执行有界的文本关键词搜索；`tools/Files.ps1` 负责文件名过滤、目录分页和读取授权。

`lib/Parallel.ps1` 负责只读调用分组、重试调度和结果配对；`lib/Runtime.ps1` 共用进程启动、轮询与清理逻辑。并行调度使用现有工具，不增加模型可调用的工具名。

`tools/Commands.ps1` 将参数按字面值交给 `kubectl` 原生程序，不执行 shell 命令字符串。参数数组为 1～128 项，每项最多 16,384 个字符。Azure 由 `azure_request` 直接调用 REST API。

新增已有工具的只读命令，修改对应 JSON；新增执行工具，还需修改注册、权限校验及执行代码。文件工具不能修改这些规则或 session 授权。
