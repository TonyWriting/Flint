# 插件

Flint 自带通用能力：读写本地文件、调用 Azure Resource Manager、执行 kubectl 并自动放行标准 Kubernetes 资源的只读查询。特定平台还有自己的自定义资源（CRD）、运维流程和文档，这部分通过**插件**加入。

插件是一个**只包含数据的文件夹**，Flint 从不执行其中的任何内容。它为 Flint 提供三样东西：

1. **只读规则**：该平台资源的哪些查询可以自动执行；
2. **受保护资源**：哪些资源由控制器调谐，修改时必须使用更严格的 `patch` 格式；
3. **知识**：一份操作指南，让模型理解这个平台、知道该怎么查。

插件由使用者维护在自己的仓库中，安装到 Flint 目录下被 Git 忽略的 `plugins/`，因此 Flint 仓库本身不包含任何平台专有内容。

## 插件的组成

```
example/
  plugin.json                 清单（必需）
  guide.md                    操作指南（必需）
  permissions/kubectl.json    只读规则（可选）
```

```json
{
  "schema_version": 1,
  "name": "example",
  "version": "1.0.0",
  "summary": "Widgets platform: widgets are reconciled by the example controller.",
  "guide": "guide.md",
  "kubectl": {
    "rules": "permissions/kubectl.json",
    "guarded_patch_resources": ["widgets.example.io", "widgets"]
  }
}
```

| 字段 | 含义 |
|---|---|
| `schema_version` | 清单格式版本，当前为 `1`。Flint 拒绝不认识的版本。 |
| `name` | 2～32 个小写字母、数字或连字符，以字母开头；决定安装目录 `plugins/<name>/`。 |
| `version` | `MAJOR.MINOR.PATCH` 格式。恢复会话时用它判断插件是否变化。 |
| `summary` | 一行说明，1～400 个字符，告诉模型这个插件覆盖什么领域。 |
| `guide` | 指南文件的相对路径，必须是 `.md`。 |
| `kubectl.rules` | 可选，只读规则文件，格式与 `tools/permissions/kubectl.json` 相同。 |
| `kubectl.guarded_patch_resources` | 可选，受保护资源的名称，最多 64 个。同一资源的单数、复数、短名和带 API group 的写法要分别列出。 |

## 模型如何使用插件

会话启动时，Flint 在固定的系统提示之后列出已加载插件的名称、版本、`summary` 和指南路径。一个会话内这段内容保持不变，因此不影响 prompt cache。

模型处理某个插件领域的问题时，先用 `read_file` 读指南，再按指南操作。指南是用户安装的参考资料，模型遵循其中的流程；指南不能越过 Flint 的规则和审批。

指南写给模型看，是从平台文档中**提炼**出的一份自包含总结，而不是文档的拷贝：说清在哪个集群、用什么 kubectl 参数查哪种对象，读结果中的哪些字段，以及修改时的格式和边界。内容较多时可以拆出几个 `.md` 文件放在插件里，在指南中用相对于指南目录的路径提及，模型会按需读取。

## 只读规则

插件规则与安装目录的规则格式相同，加载后合并在一起，匹配方式见 [[ToolPermissions#什么是相同命令|什么是相同命令]]。每条规则都要通过同一条**底线**：只能是 `get`／`describe` 某种资源、`explain`、`api-resources` 等查询，不能读取 Secret，不能放行 `--raw`、`--server`、`--as` 这类选项，并且必须要求 `--context`。完整条件见 [[ToolPermissions#什么是相同命令|工具调用与权限]]。

## 受保护资源

有些资源的 `spec` 是期望状态，由控制器持续调谐，`status` 由控制器维护。修改这类资源时，基于旧数据的覆盖或对 `status` 的直接修改都会造成混乱。插件把它们列为受保护资源后，对它们的 `patch` 必须满足：

- 写明一个资源类型和一个资源名，不使用 `type/name` 或选择器；
- 只使用 `--context`、`--namespace`、`--type`、`--patch`、`--request-timeout`，且 `--type=json`；
- JSON Patch 的第一项测试刚读取的 `/metadata/resourceVersion`，后续各项只能 `test`、`add`、`replace` 或 `remove` `/spec/` 下的字段。

```json
[
  { "op": "test", "path": "/metadata/resourceVersion", "value": "<observed-version>" },
  { "op": "replace", "path": "/spec/replicas", "value": 6 }
]
```

第一项测试让修改建立在刚读到的版本上；资源在此期间被他人修改时，kubectl 报冲突，模型需要重新读取并提交新的修改。格式不符的请求在审批前就被拒绝；格式正确的请求仍需用户逐条批准。主进程和执行命令的 worker 各检查一次。

## 校验

`-ValidatePlugin` 和安装都会完整校验插件，Flint 每次启动加载插件时也会再次校验。发现的问题一次性全部列出。

- **清单**：字段齐全、类型正确，不允许未知字段；引用的文件存在于插件内，路径不含 `.` 或 `..`。
- **文件**：只允许 `.md`、`.json`、`.txt`；不允许符号链接、junction 以及 `.env`、`.git`、私钥等受保护的名称；单个文件不超过 1 MiB，总量不超过 16 MiB，最多 2,000 个文件；插件内相对路径不超过 120 个字符。
- **规则**：符合规则格式和上面的底线。

启动时校验失败的插件不会加载，Flint 照常启动，启动界面提示哪个插件被跳过，`/status` 显示具体原因。

```powershell
powershell.exe -NoProfile -File .\agent.ps1 -ValidatePlugin .\path\to\plugin
```

## 安装与更新

`-InstallPlugin` 接受三种来源，不需要 `.env`：

```powershell
# An Azure DevOps folder URL, copied from the folder view in the browser.
powershell.exe -NoProfile -File .\agent.ps1 -InstallPlugin 'https://dev.azure.com/contoso/Project/_git/Repo?path=/plugins/example'

# A downloaded .zip, or a local folder.
powershell.exe -NoProfile -File .\agent.ps1 -InstallPlugin 'C:\Downloads\example.zip'
powershell.exe -NoProfile -File .\agent.ps1 -InstallPlugin 'C:\src\Repo\plugins\example'
```

**Azure DevOps URL** 支持 `https://dev.azure.com/<organization>/<project>/_git/<repository>` 和 `https://<organization>.visualstudio.com/[DefaultCollection/]<project>/_git/<repository>` 两种形式。`?path=` 指向插件文件夹本身，即 `plugin.json` 所在的目录；`version=GB<分支>` 或 `version=GT<标签>` 选择分支或标签，省略时使用默认分支。在 Azure DevOps 网页上切换到目标分支、打开插件文件夹后，直接复制地址栏即可：编码过的 `path`（如 `%2Fplugins%2Fexample`）和带斜杠的分支名（如 `version=GBusers%2Falias%2Ffeature`）都能识别。浏览器 URL 中的其他参数会被忽略，URL 中的用户名不会传给 git。

Flint 用 PATH 中的 `git.exe` 做一次浅克隆，只下载这个文件夹（`--depth 1 --filter=blob:none --sparse` 加上 `sparse-checkout`），认证沿用 Git Credential Manager 的登录。登录失败时，可以先在终端运行一次 `git clone <仓库地址>` 完成登录，或在 Azure DevOps 网页上用 "Download as Zip" 下载文件夹后安装 zip。

**zip** 的根目录可以直接包含 `plugin.json`，也可以只有一个顶层文件夹（Azure DevOps 下载的格式）。解压使用 Windows 自带的 `tar.exe`。

安装过程如下，任何一步失败都不影响已安装的版本：

1. 把来源拿到临时目录并校验；
2. 拷贝到 `plugins/` 下的临时目录，再校验一次；
3. 用重命名替换 `plugins/<name>/`；
4. 写入 `plugins/<name>.source.json`，记录来源、分支、路径、commit 和安装时间，`/status` 会显示这些信息。

**更新**时重新运行同一条安装命令。**删除**时移除 `plugins/<name>/` 和 `plugins/<name>.source.json`。新会话才会加载变更；用 `-Resume` 恢复的会话也使用当前安装的插件，插件有变化时，Flint 会在界面和对话中说明变化，提醒模型重新阅读指南。

`plugins/` 与 Flint 的运行代码一样受写保护，模型的文件工具无法修改已安装的插件，也就无法改写自己的规则。

## 维护插件

指南从平台文档提炼而来。每节末尾可以注明依据的原始文档，方便维护者在文档更新后核对；这些出处只供人阅读，不随插件分发。

发布新版本前：更新指南或规则，提升 `version`，运行 `-ValidatePlugin`，再提交到插件所在的仓库。
