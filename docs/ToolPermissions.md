# 工具与权限

Flint 的工具由模型提出调用，Flint 在执行前检查权限：只读操作和工作目录内的文件写入自动执行，其他修改需要你批准，凭据和 Flint 自身的代码始终受保护。判断只看实际调用，模型无法自行声明某个调用是只读的。工具按模型给出的参数原样执行，Flint 不改写其中的内容；参数里出现 Flint 自己的 API key 或 Azure token 时，这次调用不执行。屏幕显示和轨迹中的凭据照常脱敏。下面先说明审批怎样生效，再分别说明 Kubernetes、Azure 和本地文件哪些调用自动执行。

## 审批

不在自动执行范围内的调用，Flint 会先暂停并展示它：先是模型给出的用途说明 `Purpose (model-provided)`，再是完整的命令或 HTTP 请求，最后询问 `y/n`（默认 `n`）。用途说明帮助你理解请求，是否需要审批仍由 Flint 按实际调用判断。等待确认的时间不计入工具超时；无法交互时调用不执行，模型收到 `approval_required`。

一次批准只对完全相同的调用生效：

- kubectl 命令：参数及其顺序、工作目录、kubectl 程序路径，以及 `KUBECONFIG`、`KUBERNETES_MASTER` 环境变量都相同；
- Azure 请求：账户、tenant、HTTP method、完整 URI 和 body 都相同；
- 工作目录外的写入：批准的是目标目录，覆盖其中的文件和子目录，不覆盖相邻目录。

批准只保存在内存中，在这次 Flint 运行内有效。Flint 退出后批准全部失效，用 `-Resume` 恢复的会话也从没有批准开始。批准过的修改不会变成只读规则，失败时也不会自动重试。

## Kubernetes

`run_command` 目前只执行 kubectl：调用中的 `executor` 只能是 `kubectl`，其他程序和 shell 命令都会被拒绝。它使用 PATH 中的 `kubectl.exe` 和已有的 kubeconfig，集群认证由 kubeconfig 决定，与 Azure 登录无关。参数按字面值传给 kubectl，不经过 shell。每个请求都写明 `--context`，命名空间资源同时写明 `--namespace`，因此不需要切换全局 context。交互式的 `kubectl edit` 不可用。

kubectl 的输出和 Azure 响应一样保存为结果文件（见[响应文件与异步修改](#响应文件与异步修改)）。修改命令退出成功只说明修改已提交，实际状态需要再次查询确认。kubectl 超时时，Flint 在停止它之前留出几秒，把它已经打印的内容（例如连接错误）返回给模型。

### 交互式登录

有些 kubeconfig 通过凭据插件获取 token，插件在登录过期时会要求设备码登录：提示打开一个网页并输入代码，然后一直等待。kubectl 在后台进程中运行，这条提示没人看得到，所以 Flint 一检测到它就停止 kubectl。接下来：

- 只读命令：Flint 在终端询问是否现在登录。回答 `y`，Flint 在前台把这条命令再运行一次，插件的登录提示直接显示在终端，命令的输出丢弃。在浏览器中完成登录后，Flint 按正常流程重新运行这条命令，作为调用的结果。登录期间按 `s` 取消。回答 `n` 或无法交互时，调用以 `sign_in_required` 结束，模型会请你先登录。
- 修改命令：Flint 不会为了登录而重跑它，那等于再修改一次。模型收到的结果说明修改很可能没有发出，它会先读取实际状态，这次读取会请你登录。
- 并行执行的只读命令：调用以 `sign_in_required` 结束，模型单独重试其中一条时，Flint 再询问登录。

插件会缓存登录结果，之后的调用不再询问，直到登录过期。等待登录的时间不计入工具超时。`exec`、`attach`、`run`、`debug` 以及带 `--` 的命令不做这项检测，因为容器里的程序也可能打印同样的提示；这类命令需要登录时会等到超时，模型能在返回的输出中看到提示。

### 只读规则

匹配**只读规则**的 kubectl 命令自动执行，其他命令都需要审批。规则有两个来源，在会话启动时加载一次：

- `tools/permissions/kubectl.json`：随 Flint 提供的标准资源规则，包括 Pod、Event、Deployment 等的 `get`／`describe`（一次最多指定 10 个对象名），单个 Pod 最近日志的 `logs`，以及 `config get-contexts`、`api-resources`、`explain`。
- 已安装[插件](Plugins.md)中的规则：平台自定义资源（CRD）的查询。

`tools/permissions/kubectl.json` 损坏或含有非只读规则时，Flint 无法启动；插件的规则无效时，只跳过这个插件，启动界面和 `/status` 会说明原因。

规则按命令结构匹配：命令词在开头，之后的选项可以换顺序，也可以写成 `--name=value`；每个参数值都要满足规则，出现未登记或重复的选项、缺少必填选项时不匹配。下面的规则允许查询 `cluster` 中 `ns` 命名空间的 Pod：

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

`values` 限定固定值，`pattern` 用正则表达式检查可变值，`switch: true` 表示不带值的开关；命令后的位置参数由 `positionals.max` 和 `positionals.pattern` 限定。每条规则都必须标明 `read_only: true`。

### 规则底线

所有规则，无论来自 Flint 还是插件，加载时都要通过同一条底线：

- 命令只能是 `get <资源>`、`describe <资源>`、`explain`、`api-resources`、`version`、`logs`、`config get-contexts` 或 `config current-context`；`get` 和 `describe` 必须写明一种资源类型。
- 资源不能是 Secret（`secret`、`secrets` 及其带 API group 的写法）。
- 选项只能使用 `--context`、`--namespace`、`--all-namespaces`、`--output`、`--selector`、`--field-selector`、`--request-timeout`、`--api-group`、`--api-version`、`--recursive`、`--namespaced`、`--client`、`--chunk-size`。因此 `--raw`、`--kubeconfig`、`--server`、`--token`、`--as`、`--watch` 这类改变连接目标、身份或执行方式的选项无法被规则放行。
- `get`、`describe`、`explain`、`api-resources` 和 `logs` 规则必须把 `--context` 设为必填，避免命令落到当前默认集群。
- `logs` 只读取一个指定 Pod 最近的输出：选项只能使用 `--context`、`--namespace`、`--container`、`--previous`、`--timestamps`、`--tail`、`--since`、`--request-timeout`；`--namespace` 和 `--tail` 必填，`--tail` 最多 1,000 行，`--since` 最多 1 小时。日志可能包含业务数据，读取结果和其他输出一样经过凭据脱敏后发送给模型。
- 跨 namespace 的查询只能是 `get`，`--all-namespaces` 与 `--selector` 都必须是必填项，并且不能再带 `--namespace`。按标签查找对象分布在哪些 namespace 可以自动执行，整个集群的无筛选列表仍需审批。

这条底线让插件只能扩展只读查询的范围，修改命令始终逐条审批。插件额外能做的，是把某些资源列为[受保护资源](Plugins.md#受保护资源)，要求对它们的 `patch` 使用更严格的格式。

## Azure

### 登录

Flint 借助一个**认证来源**登录 Azure 并获取 token，请求本身由 Flint 的 HTTP 客户端发送。启动时按以下顺序选择认证来源：

1. PATH 中有 Azure CLI（`az.cmd` 或 `az.exe`）时，使用 Azure CLI；
2. 否则导入 Azure PowerShell 的 `Az.Accounts` 模块，只需这一个模块，不需要完整的 `Az`；
3. 两者都没有时，Azure 工具不可用。

选择只看是否安装，一次运行中不再改变。Flint 先复用认证来源已有的登录；需要登录时，在终端中登录一次，无法交互时只能复用已有的登录。登录成功后显示 `Signed in to Azure as <account> (tenant <tenant>, via Azure CLI)`。

一次运行固定使用一个账户和 tenant：Azure CLI 取默认订阅所在的 tenant，Azure PowerShell 取当前 context 的 tenant。要换 tenant，先在终端登录目标 tenant，再启动 Flint：

```powershell
az login --tenant 'contoso.onmicrosoft.com' --allow-no-subscriptions
# With Azure PowerShell: Connect-AzAccount -Tenant 'contoso.onmicrosoft.com'
powershell.exe -NoProfile -File .\agent.ps1
```

登录不绑定 subscription：每个请求在路径中写明订阅，同一 tenant 下访问不同订阅无需重新登录，权限由 Azure RBAC 检查，不足时返回 HTTP 403。运行中途若 MFA 或 Conditional Access 要求重新登录，Azure 工具返回 `authentication_required`，重新启动 Flint 即可登录。

认证来源需要足够新的版本：Azure CLI 的 `az account get-access-token` 输出包含 `expires_on`，`Az.Accounts` 的 `Get-AzAccessToken` 支持 `-TenantId` 和 `-ResourceUrl`。`Az.Accounts` 还必须被设备策略信任，例如 WDAC 允许 Microsoft 签名的代码，或 AppLocker 允许模块所在目录（`Install-Module Az.Accounts -Scope AllUsers` 会安装到 Program Files）；否则 Flint 报告模块 `could not be loaded`。

认证来源缺失、被设备策略阻止或登录被取消时，只有 Azure 工具不可用，文件和 Kubernetes 工具照常工作。不需要 Azure 时用 `-NoAzure` 启动，跳过登录。`/status` 显示 Azure 状态、认证来源、账户和 tenant。

### 自动执行的请求

`azure_request` 只访问 Azure 公有云的 `https://management.azure.com`（Azure Resource Manager，ARM），每个请求写明资源路径和 `api-version`。认证统一来自上面的登录，模型不能自带认证 header 或凭据。

GET 请求自动执行。POST 中只有 Resource Graph 资源查询自动执行，并且必须精确符合规则：路径为 `/providers/Microsoft.ResourceGraph/resources?api-version=<version>`，版本为 `2021-03-01`、`2022-10-01` 或 `2024-04-01`，不带其他 URL 参数或子路径；body 是 JSON 对象，`query` 为非空字符串，其他顶层字段只能是 `subscriptions`、`managementGroups`、`options`、`facets`。判断只看这些结构，与 KQL 内容和用途说明无关。其他 POST，以及 PUT、PATCH、DELETE，都需要审批。

### 响应文件与异步修改

Azure 响应的完整正文先脱敏，再保存到工作目录的 `.flint/results/<session-id>/`，kubectl 的输出也保存在这里。kubectl 的 JSON 输出没有内容需要脱敏时按原文保存，预览、搜索结果和行号都与 kubectl 的输出一致；有内容被脱敏时，保存为重新生成的 JSON。不超过 16,384 个字符的结果直接完整交给模型；更长的结果，模型先收到前 16,384 个字符的预览，需要细节时用 `read_file` 和 `search_text` 读取这些文件，不会重新发送请求。`read_file` 带上 `json_path`（例如 `status` 或 `items[0].status.conditions`）时，只返回 JSON 中的这一段，压缩成一行，不用先搜索行号。当前会话的结果目录自动允许读取；文件在 Flint 退出后保留，可以自行清理。

Azure 可能先接受修改，再在后台执行。这时第一次响应只说明请求已被接受，工具返回“处理中”；模型随后用 GET 查询操作状态，Flint 遵守服务给出的查询间隔，服务报告成功才算完成，报告失败或取消时作为错误返回。状态查询不会重复执行修改；超过工具时限仍未完成时，可以稍后用 `/c` 继续查询。

## 本地文件

`list_files`、`read_file` 和 `search_text` 自动执行。`write_file`、`edit_file` 和 `create_directory` 在工作目录及其子目录中直接执行；写入工作目录以外的位置需要批准目标目录（见[审批](#审批)），创建目录时父目录必须已经存在。文件工具只处理文本：写入时已有文件最多 256 KiB，写入后的内容最多 65,536 个字符，以带 BOM 的 UTF-8 保存。

### 受保护的路径

凭据和内部路径禁止读写：`.env`、`.env.*`、`.ssh`、`.kube`、`.azure`、`credentials`、`credentials.*`、`id_rsa`、`id_ed25519`，扩展名为 `.pem`、`.pfx`、`.p12`、`.key` 的文件，`.git`、`.flint`，以及 `flint.ini` 和轨迹目录。读取有两个例外：Flint 安装目录（`agent.ps1` 所在目录）中的文本文件可以读取和搜索，包括 `.git`，但 `flint.ini` 和上面列出的凭据文件除外；当前会话的结果目录也可以读取。

写入时还额外保护 Flint 的 `agent.ps1`、`lib/`、`tools/` 和 `plugins/`，因此模型无法改写 Flint 的代码和规则，目录批准也不能解除这些保护。

路径可以是相对路径或本地盘符的绝对路径，最多 240 个字符。UNC 路径、通配符、NTFS 备用数据流、设备名、符号链接和 junction 都会被拒绝。
