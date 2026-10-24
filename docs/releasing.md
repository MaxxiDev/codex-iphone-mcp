> **Fork status:** No MaxxiDev binary release is published yet. The upstream release workflow is removed from this fork. This historical guide is retained for reference; consult the root README and CONTRIBUTING.md before planning a reviewed build release. The current app name is iPhoneUseReviewed.app.

# 发布 GitHub Releases

项目提供 [GitHub Actions 工作流](../.github/workflows/release.yml)和[发布脚本](../scripts/release.sh)。推送版本标签后，GitHub 的 macOS runner 会测试、编译并上传安装包，本地无需 Xcode 或 Swift。

## 自动发布

1. 将工作流、脚本及待发布代码提交并推送到 GitHub 默认分支。仓库需要允许 GitHub Actions 运行；工作流使用自动提供的 `GITHUB_TOKEN` 和 `contents: write` 权限，无需添加个人访问令牌。
2. 在要发布的提交上创建并推送标签，例如：

   ```sh
   git tag -a v0.2.0 -m "Release v0.2.0"
   git push origin v0.2.0
   ```

3. 在 GitHub 的 **Actions → Release** 中查看运行结果。成功后，可在 [Releases](https://github.com/YueChen-C/iPhone-use/releases) 下载附件。

标签格式为 `v主版本.次版本.修订号`，也支持 `v0.2.0-beta.1` 等预发布标签。带后缀的版本会标记为 GitHub prerelease。

也可以在 **Actions → Release → Run workflow** 中输入已存在的标签，手动执行或重试。手动执行仍会检出该标签，不会发布当前所选分支的其他提交。不要移动或覆盖已发布的标签；修订版本请使用新标签。

## 发布产物

| 附件 | 内容 |
| --- | --- |
| `iPhoneUse-v0.2.0-macOS-universal.zip` | 同时包含 arm64 与 x86_64 的 `iPhoneUse.app`，支持 Apple Silicon 和 Intel Mac |
| `SHA256SUMS.txt` | ZIP 文件的 SHA-256 校验值 |

应用要求 macOS 14 或更高版本。版本号写入生成的应用包，不修改仓库中的 `Resources/Info.plist`；预发布标签的应用版本只取数字部分，例如 `v0.2.0-beta.1` 对应 `0.2.0`。构建号默认取 GitHub Actions 的运行编号，本地默认取 `1`。

解压后将 `iPhoneUse.app` 移到“应用程序”并打开，再完成相机/蓝牙授权、USB 信任和辅助触控配对。使用者无需安装编译工具。

下载 ZIP 和校验文件到同一目录后，可以运行：

```sh
shasum -a 256 -c SHA256SUMS.txt
```

工作流也会将发布文件保存在 Actions 的 `release-files` artifact 中，保留 7 天。上传失败但安装包已生成时，可从这里获取文件。

## 验证与失败处理

发布脚本依次执行 Swift 测试、Python 测试、Release Universal 构建、双架构检查、签名检查和包内 MCP 协议自检。任一步失败都会停止，不会公开 Release；这些检查不发送真机输入。

使用 `--publish` 时，脚本额外要求：

- 工作区干净，包括没有未跟踪的源码文件。
- 当前提交与本地标签一致，GitHub 上的标签也解析到同一提交。
- 同标签的 Release 尚不存在，或仍为草稿。

安装包和校验文件会先上传到草稿，全部成功后才公开。失败留下的草稿可通过重跑恢复；已公开版本会拒绝覆盖。同标签的 Actions 运行会排队，避免并发发布。

源码测试失败时，应修复后创建新的发布标签；发布脚本不跳过失败的测试。

## 本地打包与发布

本地构建 Universal 包需要 macOS、包含 Swift 6 或更高版本的 Xcode，以及 Python 3。仅打包，不连接 GitHub：

```sh
./scripts/release.sh v0.2.0
```

产物位于 `build/releases/v0.2.0/`。本地预览打包允许未提交的修改；只有显式传入 `--publish` 才会访问 GitHub 并发布。

本地发布还需要安装并登录 GitHub CLI、检出已推送的目标标签，并保持工作区干净：

```sh
gh auth login
git switch --detach v0.2.0
./scripts/release.sh v0.2.0 --publish
```

脚本不创建或推送标签。目标仓库默认由 `gh` 从当前仓库推断；CI 使用 `GITHUB_REPOSITORY`。

## 签名与公证

自动发布默认使用临时签名（ad hoc），不需要 Apple 开发者账号或证书 Secrets，**不执行 Apple 公证**。临时签名能验证包的完整性，但不能让 Gatekeeper 将下载的应用视为已受信任的开发者应用。

如果 macOS 阻止打开，使用者应先确认下载来源，再按“系统设置 → 隐私与安全性”的提示允许打开；无需关闭系统整体安全检查。

如需使用自己的签名身份，本地可执行：

```sh
CODESIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  ./scripts/release.sh v0.2.0
```

显式指定的身份签名失败时，脚本会停止，不会自动降级到临时签名。要实现签名、公证均自动完成的正式分发，还需单独接入证书导入和 Apple 公证流程；当前工作流没有包含这些步骤。

## 下载版的 MCP 配置

安装到 `/Applications/iPhoneUse.app` 后，Codex 用户可以直接注册包内的可执行文件，无需运行默认会编译的源码安装脚本：

```sh
codex mcp add iphone-use -- /Applications/iPhoneUse.app/Contents/MacOS/iphone-use mcp
```

其他 MCP 客户端同样将 `command` 指向该可执行文件，`args` 设置为 `["mcp"]`。保持 GUI 主程序运行，重新加载客户端的 MCP 工具后即可操作手机。

仓库中的可选 `$iphone-use` 技能及恢复脚本仍以源码仓库的 `.build` 目录为基础；下载版建议先使用上述 MCP 直连方式。
