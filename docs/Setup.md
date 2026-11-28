# 配置

Flint 从 `agent.ps1` 旁边的 `flint.ini` 读取模型配置。一个人使用时，可以照着 `flint.example.ini` 手动填写。同一个团队的成员通常使用同一个模型和同一组[插件](Plugins.md)，团队可以把这些共享内容放进内部仓库的一个**配置文件夹**，成员运行一条 `-Setup` 命令，Flint 就会生成本机的 `flint.ini`，并装好团队的插件。API key 不放进共享文件夹，也不在终端输入：`-Setup` 在 `flint.ini` 中留出空的 `api_key`，由每个人自己填入。

## flint.ini

```ini
[model]
endpoint = https://<resource>.services.ai.azure.com/openai/v1/responses
deployment = <deployment>
context_window = <tokens>
reasoning_effort = high
api_key = <key>
api_key_help = Copy the API key from <where your team keeps it>.
```

- `endpoint`：Azure AI Foundry Responses 接口的完整 HTTPS 地址，以 `/openai/v1/responses` 结尾，不含凭据、查询参数、fragment 或结尾斜杠。
- `deployment`：模型的部署名。
- `context_window`：这个部署的上下文窗口，单位是 token，包括请求和回答，4096～999999999 之间的整数，以模型的规格为准。Flint 按它限制每次请求的大小，见[上下文预算](Sessions.md#上下文预算)。
- `reasoning_effort`：推理强度，可选 `none`、`low`、`medium`、`high`、`xhigh` 或 `max`，不区分大小写。强度越高，模型回答前思考得越久。可用的值取决于模型部署：部署不支持时，模型服务返回 HTTP 400 并列出它支持的值。
- `api_key`：API key。
- `api_key_help`：可选，最多 400 个字符，写明去哪里取 key。`-Setup` 结束时、`api_key` 还没填就启动时、模型拒绝 key（HTTP 401，通常是 key 已轮换）时，Flint 都会显示它。

注释单独成行，以 `;` 或 `#` 开头；值从等号后取到行尾，可以用一对引号括起。Flint 只读取这个文件，不读取环境变量。遇到未知的节或设置、重复的设置或缺少必填项时，Flint 停止启动并指出所在行，报错中不显示设置的值。

## 配置文件夹

```
Flint/                      配置文件夹，名字任意
  flint.ini                 共享配置（必需），不含 api_key
  README.md                 可选，给维护者看的说明
  Plugins/                  可选，每个子文件夹是一个插件
    Example/
      plugin.json
      guide.md
      permissions/kubectl.json
```

共享的 `flint.ini` 与上面的格式相同，只是不能写 `api_key`：

```ini
[model]
endpoint = https://<resource>.services.ai.azure.com/openai/v1/responses
deployment = <deployment>
context_window = <tokens>
reasoning_effort = high
api_key_help = Copy the API key from <where your team keeps it>.
```

`Plugins/` 下的每个子文件夹是一个插件，文件夹名与插件的 `name` 相同，不区分大小写。配置文件夹中只能有 `flint.ini`、`Plugins/` 和 `.md` 说明文件，`Plugins/` 中只能有插件文件夹和 `.md` 文件，不允许符号链接或 junction。

## 运行 -Setup

`-Setup` 接受三种来源，运行前不需要 `flint.ini`：

```powershell
# An Azure DevOps folder URL, copied from the folder view in the browser.
powershell.exe -NoProfile -File .\agent.ps1 -Setup 'https://dev.azure.com/contoso/Project/_git/Repo?path=/team/flint'

# A downloaded .zip, or a local folder.
powershell.exe -NoProfile -File .\agent.ps1 -Setup 'C:\Downloads\flint.zip'
powershell.exe -NoProfile -File .\agent.ps1 -Setup 'C:\src\Repo\team\flint'
```

Flint 先完整校验 `flint.ini` 和每个插件，发现问题就列出全部原因并停止，本机不做任何改动。校验通过后，Flint 列出模型和插件，把插件同步到 Flint 目录下的 `plugins/`，配置文件夹中已经没有的插件会从本机删除；然后生成 `flint.ini`，第一行注明来源。本机 `flint.ini` 中已经填了 `api_key` 时保留它，否则 `api_key` 留空；`reasoning_effort` 同样保留本机的值，本机没有有效的值时使用配置文件夹中的值；`endpoint`、`deployment` 和 `context_window` 描述团队的模型部署，总是使用配置文件夹中的值。最后 Flint 显示启动命令并退出；`api_key` 为空时，还会先显示 `api_key_help` 和 key 要粘贴的位置。`/status` 显示每个插件的来源和安装时间。

团队更新了模型或插件后，重新运行同一条命令即可同步，已经填好的 key 会保留；现有的 `flint.ini` 无法读取时，`-Setup` 在改动任何内容之前停止，说明哪一行有问题，修好或删掉这个文件后再运行即可。key 轮换时，直接编辑 `flint.ini` 中的 `api_key`。插件在 Flint 启动时加载，同步之后启动的 Flint，包括用 `-Resume` 恢复的会话，都使用新装的插件。

**Azure DevOps URL** 支持 `https://dev.azure.com/<organization>/<project>/_git/<repository>` 和 `https://<organization>.visualstudio.com/[DefaultCollection/]<project>/_git/<repository>` 两种形式。`?path=` 指向配置文件夹本身，即 `flint.ini` 所在的目录；`version=GB<分支>` 或 `version=GT<标签>` 选择分支或标签，省略时使用默认分支，不支持指向单个 commit 的 URL。在 Azure DevOps 网页上切换到目标分支、打开配置文件夹后，直接复制地址栏即可：编码过的 `path`（如 `%2Fteam%2Fflint`）和带斜杠的分支名（如 `version=GBusers%2Falias%2Ffeature`）都能识别，URL 中的其他参数会被忽略。

Flint 用 PATH 中的 `git` 只下载这个文件夹，认证沿用 Git Credential Manager 的登录。找不到 `git` 时，先从 Software Center 安装 Git for Windows。安装后在新的终端中重新运行 `-Setup`，新终端才能读到更新后的 PATH。登录失败时，可以先在终端运行一次 `git clone <仓库地址>` 完成登录，或者在 Azure DevOps 网页上用 "Download as Zip" 下载文件夹，再把 zip 传给 `-Setup`。

**zip** 的根目录可以直接包含 `flint.ini`，也可以只有一个顶层文件夹，Azure DevOps 下载的就是这种格式。

## 维护配置文件夹

发布前修改 `flint.ini` 或插件；插件内容有变化时，提升该插件的 `version`。然后校验整个文件夹，再提交到团队仓库：

```powershell
powershell.exe -NoProfile -File .\agent.ps1 -ValidateSetup .\path\to\setup
```
