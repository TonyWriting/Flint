# 团队配置

同一个团队的成员通常使用同一个模型和同一组[[Plugins|插件]]。团队把这些共享内容放进内部仓库的一个**配置文件夹**，成员运行一条 `-Setup` 命令，Flint 就会生成本机的 `flint.ini`，并装好团队的插件。API key 不放进共享文件夹，由每个人在运行 `-Setup` 时自己粘贴。

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

`flint.ini` 与[[README#启动|本机配置]]的格式相同，只是不能写 `api_key`：

```ini
[model]
endpoint = https://<resource>.services.ai.azure.com/openai/v1/responses
deployment = <deployment>
api_key_help = Copy the key from <where your team keeps it>.
```

`api_key_help` 可选。运行 `-Setup` 时，它显示在粘贴 key 的提示之前；以后模型拒绝 key（HTTP 401，通常是 key 已轮换）时，Flint 也会在错误信息中显示它，告诉用户去哪里取新 key。

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

Flint 依次完成以下步骤：

1. **取得并校验**：完整校验 `flint.ini` 和每个插件，发现问题就列出全部原因并停止，本机不做任何改动。
2. **显示内容**：列出模型、插件和 `api_key_help`。
3. **读取 key**：粘贴 key 时不回显，只有 key 通过管道输入时才按普通文本读取。本机已有 `flint.ini` 时，直接按回车沿用当前的 key。
4. **暂存配置**：把新的 `flint.ini` 写成同一目录下的临时文件。目录无法写入时在这一步失败，本机不做任何改动。
5. **同步插件**：每个插件先拷贝到 `plugins/` 下的临时目录再校验一次，然后用重命名替换旧版本；配置文件夹中已经没有的插件会被删除。每个插件旁边写入 `plugins/<name>.source.json`，记录来源、分支、路径、commit 和安装时间，`/status` 会显示这些信息。插件同步失败时，原来的 `flint.ini` 保持不变。
6. **替换配置**：用重命名替换 `flint.ini`，第一行注明来源，然后显示启动命令。

`-ConfigFile` 可以把配置写到其他位置：相对路径以当前目录为准，所在目录必须已经存在，这两项在取得配置文件夹之前就会检查；完成后显示的启动命令会带上这个路径。团队更新了模型或插件后，重新运行同一条命令即可同步，按回车保留原来的 key。key 轮换时，重新运行并粘贴新 key，或者直接编辑 `flint.ini`。

新会话才会加载插件的变化。用 `-Resume` 恢复的会话同样使用当前安装的插件；插件有变化时，Flint 会在界面和对话中说明变化，提醒模型重新阅读指南。

**Azure DevOps URL** 支持 `https://dev.azure.com/<organization>/<project>/_git/<repository>` 和 `https://<organization>.visualstudio.com/[DefaultCollection/]<project>/_git/<repository>` 两种形式。`?path=` 指向配置文件夹本身，即 `flint.ini` 所在的目录；`version=GB<分支>` 或 `version=GT<标签>` 选择分支或标签，省略时使用默认分支。在 Azure DevOps 网页上切换到目标分支、打开配置文件夹后，直接复制地址栏即可：编码过的 `path`（如 `%2Fteam%2Fflint`）和带斜杠的分支名（如 `version=GBusers%2Falias%2Ffeature`）都能识别。浏览器 URL 中的其他参数会被忽略，URL 中的用户名不会传给 git。

Flint 用 PATH 中的 `git.exe` 做一次浅克隆，只下载这个文件夹（`--depth 1 --filter=blob:none --sparse` 加上 `sparse-checkout`），认证沿用 Git Credential Manager 的登录。登录失败时，可以先在终端运行一次 `git clone <仓库地址>` 完成登录，或者在 Azure DevOps 网页上用 "Download as Zip" 下载文件夹后传入 zip。

**zip** 的根目录可以直接包含 `flint.ini`，也可以只有一个顶层文件夹（Azure DevOps 下载的格式）。解压使用 Windows 自带的 `tar.exe`。

## 维护配置文件夹

发布前修改 `flint.ini` 或插件；插件内容有变化时，提升该插件的 `version`。然后校验整个文件夹，再提交到团队仓库：

```powershell
powershell.exe -NoProfile -File .\agent.ps1 -ValidateSetup .\path\to\setup
```
