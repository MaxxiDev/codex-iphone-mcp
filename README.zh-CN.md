# iPhone Use — MaxxiDev 定制版

在 Mac 上查看和操作真实 iPhone，并通过本地 HTTP / MCP 接入 AI 工具。

**实验阶段 · 当前发布源码 · 真机验证尚未完成**

[English](README.md) · [修改记录](CHANGELOG.md) · [检查与测试说明](REVIEW-NOTES.md) · [安全说明](SECURITY.md)

本项目 fork 自 [YueChen-C/iPhone-use](https://github.com/YueChen-C/iPhone-use)，由 [MaxxiDev](https://github.com/MaxxiDev) 维护。USB 投屏、蓝牙输入、桌面界面及 MCP 基础由原作者实现；本分支增加接口认证、参数校验和回归测试。这不是从零原创的项目，也不是原作者或 Apple 的官方版本。

## 可以做什么

- 通过 USB 数据线显示已解锁 iPhone 的画面。
- 通过 Bluetooth LE 和辅助触控，发送鼠标及键盘操作。
- 通过 MCP 截图、点击、滑动、输入及导航。
- 适合有人监督的 App 测试、开发和个人自动化。
- iPhone 不需要越狱、不需要安装专用 App，也不需要付费开发者账号。

## 本分支增加的内容

| 项目 | 变化 |
| --- | --- |
| API 认证 | 读取设备、截图及控制接口需要随机 256 位 token |
| token 文件 | 只允许当前用户读取的 0600 文件；拒绝符号链接及异常权限 |
| 浏览器防护 | 检查 Host / Origin，拒绝跨站请求；预览页面不内嵌 token |
| HTTP 校验 | 拒绝负数、溢出、重复或过大的长度、异常 JSON 及不支持的传输编码 |
| 输入校验 | 检查坐标及图片尺寸，限制手势时长、相对移动和输入长度 |
| 客户端 | MCP 自动读取 token，Python 辅助脚本使用认证请求 |
| 应用名称 | 本地打包名称为 iPhoneUseReviewed.app；Reviewed 指本次有记录的检查，不代表安全认证 |

## 当前测试状态

截至 2026 年 10 月 24 日：

- 修改前：162 项 Swift 测试通过。
- 修改后：170 项 Swift 测试、46 项不需要网络监听的 Python 测试通过。
- 16 项 Python HTTP 集成测试因本地环境不允许绑定端口而被阻止，不能算通过。
- MCP 协议检查、Apple Silicon Release 编译及本地临时签名校验通过。
- 真机配对、投屏、指针精度、重连和 MCP 实际操作尚未验证。

**当前不发布 MaxxiDev 的二进制安装包。** GitHub Actions 检查结果与上述本地记录分别说明：[首次完整 CI](https://github.com/MaxxiDev/iphone-use/actions/runs/40089597349) 已通过 **170 项 Swift、全部 62 项 Python（包含 HTTP 集成）测试、Release 编译和 MCP 协议检查**。对应提交为 `55f7ea65c2cbd1544a38a403264c9653af2cfd47`。真机验收仍待完成。

## 构建与连接

需要 macOS 14+、Swift 6+、Bluetooth LE、已解锁 iPhone 和可传输数据的 USB 线。辅助脚本和测试需要 Python 3；可选录屏功能需要 ffmpeg。Swift 主程序没有第三方包依赖。

```sh
git clone https://github.com/MaxxiDev/iphone-use.git
cd iphone-use
swift test
swift build -c release
./scripts/build-app.sh
```

应用输出位置：`build/iPhoneUseReviewed.app`。打包脚本可能使用本机已有签名身份，否则退回临时签名；不会执行 Apple 公证。

1. 将应用放入 Applications，然后自行打开。
2. 连接并解锁 iPhone，完成“信任此电脑”。
3. 按需要授予 Mac 相机权限（USB 画面）和蓝牙权限（输入）。
4. 在 iPhone 开启“设置 → 辅助功能 → 触控 → 辅助触控”。
5. 在“辅助触控 → 设备 → 蓝牙设备”中与 iPhone Use / 界面显示的 Mac 名称配对。
6. 先在没有敏感内容的页面验证投屏和一次普通点击。

原版与本版不要同时运行，默认都使用 7390 端口。

## 接入 Codex / Claude Code

应用保持运行，再选择对应客户端执行：

```sh
codex mcp add iphone-use -- /Applications/iPhoneUseReviewed.app/Contents/MacOS/iphone-use mcp
# 或者
claude mcp add iphone-use -- /Applications/iPhoneUseReviewed.app/Contents/MacOS/iphone-use mcp
```

重启客户端或开启新会话加载工具。先列出设备、截图，确认目标手机。MCP 不会独立启动主程序。可选的上游 skill 保留在源码中，但不会自动安装。

## token 与隐私

首次运行时创建 `~/Library/Application Support/iPhoneUse/api-token`，MCP 自动读取。不要上传该文件、贴进聊天或公开 issue。

从源码目录查询状态：

```sh
python3 scripts/local_api.py http://127.0.0.1:7390/status
```

原版不带认证的 curl 示例在本版会返回 401。`IPHONE_USE_PORT` 可设置端口；若设置 `IPHONE_USE_AUTH_FILE`，应用和客户端必须使用同一个绝对路径。浏览器预览 `/viewer` 需要在本机输入 token，不会保存到 URL 或持久浏览器存储。

- 本地桥接不代表 AI 在本地运行；云端 AI 客户端可能将手机截图发送给模型服务商。
- token 不能隔离已经以同一 macOS 用户身份运行的恶意软件。
- 不要把 API 暴露到公网、隧道或反向代理。
- 手机需要保持解锁；目前以竖屏为主，直接输入限 US 键盘布局 ASCII。
- 发送消息、付款、删除等操作仍需人工监督；程序不会理解按钮的实际后果。
- 本次只是有范围的源码检查及加固，**不是完整安全审计或“保证没有问题”**。

开发命令和详细限制见 [English README](README.md)。原作者保有原有版权，本分支保留 [MIT License](LICENSE) 和来源说明。
