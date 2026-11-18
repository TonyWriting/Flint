# PR 自动测试与合并检查

[CI 工作流](../.github/workflows/ci.yml) 使用 GitHub Actions 的标准 `windows-2022` runner，通过 Windows PowerShell 5.1 调用 `tests/Run.Tests.ps1`，运行全部现有离线测试。测试中的 Flint 在 ConstrainedLanguage 下执行，测试辅助程序自行创建临时配置并模拟模型、Azure 和 kubectl，无需配置 GitHub Secrets。本地执行方式见 [[README#验证|本地测试入口]]。

## 何时运行

- 创建、重新打开 PR 或向 PR 推送新提交时。
- 向 `main` 推送提交时，包括合并 PR 后。
- 在 Actions 页面选择 CI，通过 Run workflow 手动触发时；手动入口需要工作流已存在于默认分支。

同一 PR 或分支的新任务会取消旧任务，每次测试最多运行 30 分钟。所有 PR 都运行测试，包括只改文档的 PR，确保必需检查始终产生结果。

## 合并前要求测试通过

工作流负责报告测试结果，分支规则负责阻止未通过检查的 PR 合并。将工作流提交并推送到 GitHub 后，完成以下配置：

1. 创建或更新一个 PR，在 Checks 中确认 `Windows PowerShell 5.1 tests` 成功运行。
2. 打开仓库的 [Settings → Rules → Rulesets](https://github.com/TonyWriting/Flint/settings/rules)，选择 New ruleset → New branch ruleset。
3. 为规则集命名，将 Enforcement status 设为 **Active**，Target branches 选择默认分支 `main`。
4. 勾选 **Require a pull request before merging**。如果只要求 CI，通过将 Required approvals 设为 `0`，即可保留无需他人审批的合并流程。
5. 勾选 **Require status checks to pass**，添加 **Windows PowerShell 5.1 tests**，来源选择 GitHub Actions；同时勾选 **Require branches to be up to date before merging**。
6. 保持 Bypass list 为空并保存，让规则覆盖所有普通合并操作。

配置后，PR 必须在与最新 `main` 同步的基础上通过检查才能合并。若列表里暂时找不到检查，先让工作流成功运行一次，再返回添加。这里的检查名称对应工作流的 job `name`，后续改名时同步更新规则集。

## 费用

`TonyWriting/Flint` 是公开仓库。本工作流使用的标准 GitHub 托管 Windows runner 免费，测试调用均为本地模拟。工作流只保留运行日志，不上传 artifacts 或设置额外缓存。

GitHub 对私有仓库提供按套餐划分的免费额度，超额使用按规则计费；大型 runner 另行计费。具体以 [GitHub Actions 收费说明](https://docs.github.com/en/billing/concepts/product-billing/github-actions) 为准。

规则集操作说明见 [GitHub 官方文档](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository)。
