# Flint

Flint 是一个轻量的 AI Agent，在受限的 Windows 设备上查询 Azure 和 Kubernetes 配置、查看本地文件，并执行你批准的修改。它只需要 Windows PowerShell 5.1，可以在 ConstrainedLanguage 下运行；除了工作目录内的文件写入，每项修改都先经过你批准，凭据在显示和记录前会被脱敏。

## 快速开始

运行 Flint 需要：

- Windows PowerShell 5.1，即系统自带的 `powershell.exe`。Flint 只支持这个版本。
- 使用 Azure 工具时：Azure CLI，或 Azure PowerShell 的 `Az.Accounts` 模块。Flint 启动时复用它们已有的登录，需要时在终端中登录一次。
- 使用 Kubernetes 工具时：PATH 中有 `kubectl`，并已配置好 kubeconfig。

```powershell
git clone https://github.com/TonyWriting/Flint.git
cd Flint
```

### 配置模型

Flint 调用 Azure AI Foundry 的 Responses 接口，模型配置写在 `agent.ps1` 旁边的 `flint.ini` 中。

团队提供了[配置文件夹](docs/Setup.md#配置文件夹)时，用它运行一次 `-Setup`。Flint 会生成 `flint.ini`、安装团队的插件，然后提示去哪里取 API key；把 key 粘贴到 `flint.ini` 中 `api_key =` 之后即可。

```powershell
powershell.exe -NoProfile -File .\agent.ps1 -Setup 'https://dev.azure.com/contoso/Project/_git/Repo?path=/team/flint'
```

没有团队配置时，把 `flint.example.ini` 复制为 `flint.ini`，填写 Foundry 的 endpoint、部署名和 API key：

```ini
[model]
endpoint = https://<resource>.services.ai.azure.com/openai/v1/responses
deployment = <your-deployment>
context_window = <deployment-context-window-tokens>
reasoning_effort = high
api_key = <your-key>
```

### 启动

```powershell
powershell.exe -NoProfile -File .\agent.ps1
```

**启动时的当前目录就是工作目录**：Flint 在这里读写文件，并把会话数据保存到其中的 `.flint/`。要在其他目录工作，先进入该目录，再用 `agent.ps1` 的路径启动。

```powershell
# Ask one question and exit.
powershell.exe -NoProfile -File .\agent.ps1 -Prompt 'Summarize the logs in this directory.'

# Resume a saved session from the same working directory.
powershell.exe -NoProfile -File .\agent.ps1 -Resume '<session-id>'

# Use only file and Kubernetes tools, without Azure sign-in.
powershell.exe -NoProfile -File .\agent.ps1 -NoAzure
```

## 使用

- `/help`：列出命令。
- `/status`：查看模型、Azure 登录、上下文用量、插件和轨迹位置。
- `/continue`（简写 `/c`）：继续被中止的任务。
- 粘贴多行文本（如报错或日志）时，整段作为一条消息发送；最后一行没有换行时，按 Enter 发送。
- `/exit`：退出。
- `s`：Flint 工作时按下，停止当前任务，保留对话。
- `Ctrl+C`：停止并退出，保存会话并显示继续用的 `-Resume` 命令。

## 能做什么

| 工具 | 用途 |
|---|---|
| `list_files` | 分页列出目录 |
| `read_file` | 分页读取文本文件 |
| `search_text` | 在文件中搜索关键词 |
| `write_file` | 新建或覆盖文本文件 |
| `edit_file` | 替换文件中唯一匹配的一段文本 |
| `create_directory` | 创建目录 |
| `run_command` | 执行 `kubectl` 命令；目前只支持 kubectl，不运行其他程序或 shell 命令 |
| `azure_request` | 调用 Azure Resource Manager REST API |

读取类操作自动执行：文件读取与搜索、Azure GET、符合规则的 Resource Graph 查询，以及匹配已审核只读规则的 kubectl 命令。工作目录内的文件写入直接执行；其他修改，包括工作目录外的写入、其余的 kubectl 命令和 Azure 请求，都先展示完整内容，由你回答 `y/n`。凭据文件和 Flint 自身的代码受保护，模型无法改写。

## 文档

- [配置](docs/Setup.md)：`flint.ini` 的格式，团队配置文件夹与 `-Setup`。
- [插件](docs/Plugins.md)：为特定平台补充只读规则、受保护资源和操作指南。
- [工具与权限](docs/ToolPermissions.md)：自动执行与审批、kubectl、Azure 登录、受保护的路径。
- [会话](docs/Sessions.md)：中止与继续、上下文预算、并行执行、轨迹和命令行参数。
- [开发](docs/Development.md)：代码布局和测试。

## 测试

测试离线运行，不需要真实密钥，也不访问 Azure 或集群；运行方式见[开发](docs/Development.md#运行测试)。
