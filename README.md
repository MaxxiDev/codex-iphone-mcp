# iPhone Use

在 Mac 上查看并操作真实 iPhone，也可以通过 MCP 让 AI Agent 使用手机。

项目通过 **USB 采集屏幕**，通过 **Bluetooth LE HID 发送鼠标和键盘输入**。手机端无需安装应用，无需越狱，也不需要 Apple 开发者账号。

**本地使用直接运行 Swift 可执行文件即可，无需先打包 `.app`，无需开发者证书或手动签名。** 相机与蓝牙权限仍需按 macOS 提示授权。

## 相较于 Apple「iPhone 镜像」的优势

本项目在投屏与操控方面，主要适合不同账号的手机、多台测试设备，以及需要直接在手机上参与操作的场景。

| 核心优势 | iPhone Use | Apple「iPhone 镜像」 |
| --- | --- | --- |
| **不要求同一 Apple 账户或双重认证** | 核心投屏与控制通过 USB 信任和蓝牙配对建立连接，不要求两端使用同一 Apple 账户，也不要求开启 Apple 双重认证 | 两端必须登录同一 Apple 账户，并开启双重认证 |
| **支持多台 iPhone 连接与控制** | 同一 Mac 可连接多台手机，通过 API/MCP 按设备 ID 分别截图和控制，每台手机有独立的采集会话与输入队列 | 一次只能与一台 Mac 和一台 iPhone 配合使用 |
| **方便手机端与 Mac 端交替操作** | 手机保持解锁，可直接查看和触摸手机，再继续通过 Mac 操作，适合现场演示和联调 | 手机保持锁定，解锁手机会停止镜像 |

本项目使用 **USB 传输画面、蓝牙传输输入**，需要数据线、USB“信任此电脑”、蓝牙配对和 AssistiveTouch；部分手机还需要指针校准。
当前多设备操作通过 API/MCP 提供，控制窗口仍只支持单设备。通用剪贴板等 Apple 连续互通功能仍需满足其账户与设置要求。

Apple 侧的使用条件参见 [官方「iPhone 镜像」说明](https://support.apple.com/zh-cn/120421)。

## 工作方式

```text
Mac 控制窗口 ─────────────┐
                        ├── iphone-use ── Bluetooth LE HID ──→ iPhone 输入
脚本 ── HTTP API ────────┤        ↑
                        │        └──────── USB ────────────── iPhone 画面
AI Agent ── MCP ── HTTP ─┘
```

- **控制窗口**：实时画面、鼠标点击与拖动、键盘输入，以及 Home、搜索、粘贴、回车和音量快捷按钮。
- **HTTP API**：截图、点击、长按、滑动、移动指针、输入文字和设备管理，默认监听 `127.0.0.1:7390`。
- **MCP**：通过标准输入输出连接 Agent，将工具调用转发给本机 HTTP API。
- **指针校准**：对绝对坐标定位不正常的手机，提供基于 Safari 实测的相对位移校准。
- **多设备**：HTTP API 和 MCP 支持指定手机；每台手机有独立的采集会话和输入队列。

## 环境要求

| 项目 | 要求 |
| --- | --- |
| Mac | macOS 14 或更高版本，支持 Bluetooth LE，并开启蓝牙 |
| Swift | Swift 6.0 或更高版本，可使用包含该工具链的 Xcode 或 Command Line Tools |
| iPhone | 保持解锁，信任此 Mac，并开启辅助触控（AssistiveTouch） |
| 连接 | 可传输数据的 USB 线；蓝牙负责控制，USB 负责画面 |
| 可选工具 | Python 3 用于指针校准；`ffmpeg` 用于录屏 |

Swift 主程序使用系统框架，没有第三方 Swift 包依赖。不同 iPhone、iOS 版本和指针设置的定位效果可能不同；项目未声明覆盖所有机型的兼容性。

## 快速开始

### 1. 获取代码并启动

```sh
git clone https://github.com/YueChen-C/iPhone-use.git
cd iPhone-use
swift run -c release iphone-use
```

也可以使用仓库提供的启动脚本，默认同样采用 Release 配置：

```sh
./scripts/run.sh
```

首次启动会编译项目，随后打开控制窗口并启动 HTTP 服务。保持进程运行；在启动它的终端按 `Ctrl-C`，或关闭控制窗口，即可退出。

如果希望先编译再运行：

```sh
swift build -c release
.build/release/iphone-use
```

以上是三种启动方式，选择一种即可。不要同时启动多个使用相同端口的主程序。

### 2. 连接手机并授权

1. 用 USB 数据线连接 iPhone，解锁并选择“信任此电脑”。如果 Mac 提示允许配件连接，选择允许。
2. 按 macOS 提示允许**相机**和**蓝牙**访问。相机权限用于通过 AVFoundation 读取 iPhone 的 USB 画面。
3. 在 iPhone 的“设置 → 蓝牙”中选择 **iPhone Use**，并确认两端的配对提示。iOS 也可能显示 Mac 的蓝牙名称，控制窗口的连接提示会列出该名称。
4. 在 iPhone 的“设置 → 辅助功能 → 触控 → 辅助触控”中开启 **AssistiveTouch**。
5. 等待画面与控制连接就绪。若能看到画面但无法操作，继续检查蓝牙、辅助触控和指针状态。

从终端启动时，权限可能归属于启动进程的终端应用，以系统提示显示的名称为准。拒绝过权限时，在“系统设置 → 隐私与安全性 → 相机 / 蓝牙”中检查对应应用，再重新启动。

### 3. 检查状态

在另一个终端执行：

```sh
curl -s http://127.0.0.1:7390/status
curl -s http://127.0.0.1:7390/devices
```

`/status` 包含整体蓝牙状态、`devices` 和尚未匹配的 `unmatchedHosts`。重点检查：

| 字段 | 含义 |
| --- | --- |
| `devices[].id` | USB 设备 ID，供 API、MCP 和校准脚本选择手机 |
| `devices[].bluetooth` | 手机已匹配到当前连接的蓝牙 host；不代表所有控制报告都已就绪 |
| `devices[].width` / `height` | USB 画面的原始像素尺寸 |
| `devices[].pointer.ready` | 当前是否具备坐标定位条件，不代表已验证实际落点精度 |
| `devices[].pointer.calibration.mode` | `absolute`、`relative-calibrated` 或 `calibration-unavailable` |

## 使用控制窗口

鼠标在手机画面内移动、点击或拖动时，会转发为手机输入；窗口黑边和右侧按钮区域不参与坐标换算。窗口获得焦点后，可以输入 ASCII 字符和常用功能键。

右侧提供 **Home、搜索、粘贴、回车、音量 +、音量 −**。`Command+V` 和“粘贴”按钮发送的是手机端原生粘贴快捷键；如需粘贴 Mac 剪贴板里的内容，需要配置两端的 Handoff 与通用剪贴板。项目本身不传输剪贴板内容。

窗口与 API 共用手机输入队列和指针位置状态。窗口拖拽尚未结束时，API 坐标操作返回 HTTP `409`；释放后即可继续。窗口失焦、关闭或取消交互时会释放按钮。

当前窗口只支持连接**一台**手机的场景，没有设备切换界面。连接多台手机时，请通过 HTTP API 或 MCP 指定设备。

## 接入 AI Agent：MCP

同一个可执行文件有两个运行模式：

| 命令 | 作用 |
| --- | --- |
| `iphone-use` | 启动控制窗口、USB 采集、蓝牙控制和 HTTP 服务 |
| `iphone-use mcp` | 启动 stdio MCP 服务，连接已经运行的 HTTP 服务 |

**先启动主程序，再让 MCP 客户端启动 `mcp` 进程。** MCP 模式不会自动启动控制窗口或连接硬件。建议先用 `swift build -c release` 生成可执行文件，再配置客户端直接使用它。

通用 MCP 配置示例，将路径替换为本机仓库的绝对路径：

```json
{
  "mcpServers": {
    "iphone-use": {
      "command": "/absolute/path/to/iPhone-use/.build/release/iphone-use",
      "args": ["mcp"]
    }
  }
}
```

Claude Code 可在仓库根目录执行：

```sh
claude mcp add iphone-use -- "$PWD/.build/release/iphone-use" mcp
```

| 工具 | 参数 | 用途 |
| --- | --- | --- |
| `list_devices` | 无 | 列出已连接的手机 |
| `screenshot` | 无必填参数 | 获取截图 |
| `tap` | `x`, `y` | 点击 |
| `long_press` | `x`, `y`；可选 `seconds`，默认 `1` | 长按 |
| `swipe` | `points` 坐标对象数组；可选 `duration`，默认 `0.3` 秒 | 连续多点滑动 |
| `type_text` | `text` | 输入 US 键盘布局支持的 ASCII 文字 |
| `press_key` | `key`；可选 `modifiers` | 发送按键或组合键 |
| `home` | 无必填参数 | 返回主屏幕 |

除 `list_devices` 外，每个工具都可传 `device`，值为设备 ID 或名称；连接多台手机时必须指定，建议使用完整 ID。

MCP 截图为 JPEG，长边最多 **1200 像素**。点击、长按和滑动坐标使用该手机最近一次 MCP 截图的像素坐标。动作成功后等待约 **0.6 秒**再获取截图并返回，供 Agent 检查结果。

`swipe` 在 MCP 和 HTTP 中都使用 `points` 与 `duration`，例如：

```json
{
  "points": [
    {"x": 200, "y": 800},
    {"x": 240, "y": 500},
    {"x": 400, "y": 300}
  ],
  "duration": 0.6
}
```

至少提供两个点，每个点包含数值型 `x`、`y`，各点必须位于画面范围内。两点表示直线滑动，多点按数组顺序连接成折线；全程保持按下，经过最后一点后释放。`duration` 必须大于 `0`，表示整条路径的移动等待时长，各段按屏幕像素距离分配。按下与释放前后的固定等待、蓝牙传输和校准移动可能增加实际耗时。原来的四坐标参数和 MCP `swipe.seconds` 已移除。

`press_key` 支持 `enter`、`escape`、`backspace`、`tab`、`space`、方向键或单个字符；修饰键为 `cmd`、`shift`、`alt`、`ctrl`。例如 `space` + `cmd` 可打开 Spotlight，然后输入应用名并回车。

## HTTP API

默认地址为 `http://127.0.0.1:7390`。POST 请求体使用 JSON；针对单台手机的请求可在请求体传 `device`，GET 请求使用 `?device=<id>`。

### 常用示例

```sh
# 保存原始尺寸截图；默认 JPEG，也可使用 ?format=png
curl -s http://127.0.0.1:7390/screenshot -o screen.jpg

# 点击画面中心，使用 0～1 的相对坐标
curl -s http://127.0.0.1:7390/tap \
  -H 'Content-Type: application/json' \
  -d '{"x":0.5,"y":0.5,"fraction":true}'

# 从下向上滑动
curl -s http://127.0.0.1:7390/swipe \
  -H 'Content-Type: application/json' \
  -d '{"points":[{"x":0.5,"y":0.8},{"x":0.5,"y":0.2}],"fraction":true,"duration":0.4}'

# 输入文字 / 打开 Spotlight / 返回主屏幕
curl -s http://127.0.0.1:7390/type \
  -H 'Content-Type: application/json' -d '{"text":"hello"}'
curl -s http://127.0.0.1:7390/key \
  -H 'Content-Type: application/json' -d '{"key":"space","modifiers":["cmd"]}'
curl -s -X POST http://127.0.0.1:7390/home
```

### 接口与坐标

| 方法 | 路径 | 参数 / 行为 |
| --- | --- | --- |
| GET | `/status`，或 `/` | 蓝牙、设备与指针状态 |
| GET | `/devices` | 设备列表 |
| GET | `/screenshot` | 可选 `format=png`、`maxEdge`、`maxWidth`、`device` |
| POST | `/tap` | `x`, `y`；可选 `hold`，按住秒数，默认 `0.08`；长按也使用此接口 |
| POST | `/swipe` | `points: [{"x":数值,"y":数值}, ...]`，至少两个点；可选 `duration`，默认 `0.3` 秒 |
| POST | `/move` | `x`, `y`，仅移动指针 |
| POST | `/nudge` | `dx`, `dy`，原始 HID 相对位移；可选 `click`，默认 `false` |
| POST | `/type` | `text`，ASCII 文字 |
| POST | `/key` | `key`；可选 `modifiers` 数组 |
| POST | `/home` | 返回主屏幕 |
| POST | `/match` | 可选 `force`、`probe`，重新匹配屏幕与蓝牙连接 |
| POST | `/pair` | `device`, `host`，手动指定对应关系 |

`/tap`、`/move`、`/swipe` 支持以下坐标方式，原点均为画面左上角：

- 默认使用原始屏幕像素坐标。
- 若基于缩放图片选点，传入该图片的 `width`、`height`；也可传入截图时相同的 `maxEdge`。使用 `maxWidth` 缩放时，请传回图片的宽高。
- 使用 `"fraction": true` 时，坐标为 `0`～`1` 的相对位置，无需传图片尺寸。

`swipe.points` 中的所有点共用请求顶层的坐标设置，点内只填写 `x`、`y`。使用 MCP 时直接传截图像素；使用 HTTP 的缩放截图时，需要传入对应尺寸或 `maxEdge`。

截图响应头包含 `X-Device`、`X-Screen-Width`、`X-Screen-Height`、`X-Image-Width` 和 `X-Image-Height`，用于区分原始画面与返回图片的尺寸。

HTTP 动作成功时返回 `{"ok":true,"device":"..."}`，**不会自动附带截图**。`/nudge` 的数值不是屏幕像素，它会使已有指针位置估计失效，主要供校准使用。

## 指针校准

默认定位模式为 `absolute`。如果手机已连接、辅助触控已开启，但指针无法按坐标准确移动，可以使用相对位移校准。校准通过 Safari 鼠标事件测量 HID 位移与屏幕位移的关系，窗口和 API 随后共用该校准。

1. 保持主程序运行，确认 USB 画面可用且手机已匹配蓝牙连接。
2. 让 iPhone 能通过局域网访问 Mac，通常将两者连接到同一 Wi-Fi。
3. 在仓库根目录运行以下脚本，仅依赖 Python 标准库：

   ```sh
   python3 scripts/calibrate-pointer.py
   ```

4. 在 iPhone 的 **Safari** 打开终端打印的完整网址。保持手机竖屏、关闭页面缩放，并开启辅助触控。
5. 等待终端提示保存成功；测量期间不要移动 Mac 鼠标或操作手机。脚本只发送移动，不执行点击。
6. 重启 `iphone-use`，再次查看 `/status`。

成功加载时，`pointer.calibration.mode` 为 `relative-calibrated`，`loaded`、`screenMatches` 与 `pointer.ready` 应为 `true`。

多设备、指定网络地址或自定义 API 端口时：

```sh
python3 scripts/calibrate-pointer.py \
  --device '<完整设备ID>' \
  --address '<Mac的局域网IP>' \
  --api http://127.0.0.1:7400
```

`--device` 必须是 `/devices` 返回的完整 ID。脚本默认连接 API 端口 `7390`，**不读取 `IPHONE_USE_PORT`**，自定义端口需使用 `--api`。临时校准网页默认使用端口 `7391`，可通过 `--listen-port` 修改；测量结束或失败后关闭网页服务。

相对定位是近似估计，可能积累误差。首次定位、重连或原始位移使估计失效后，会先归到左上角恢复原点。改变跟踪速度、指针设置或显示缩放后，应重新校准。已要求校准的设备若文件无效或画面尺寸不匹配，坐标操作会报错。

## 多设备与配对

每台手机都需要 USB 连接、蓝牙配对并开启辅助触控。单手机与单蓝牙连接默认直接建立对应关系；多设备时通过移动指针并比较画面变化进行匹配，结果保存到本机。

通过 `list_devices` 或 `/devices` 获取 ID，再为操作指定 `device`。当前控制窗口不提供多设备选择。

需要重新匹配时：

```sh
# 重新匹配当前屏幕，并强制通过指针探测确认对应关系
curl -s http://127.0.0.1:7390/match \
  -H 'Content-Type: application/json' -d '{"force":true,"probe":true}'

# 手动关联：host 取自 /status 的 unmatchedHosts
curl -s http://127.0.0.1:7390/pair \
  -H 'Content-Type: application/json' \
  -d '{"device":"<完整设备ID>","host":"<蓝牙host UUID>"}'
```

`force` 会重新尝试匹配当前屏幕，并非清空全部历史数据；没有找到新匹配的屏幕会保留原映射。

## 配置、数据与录屏

| 配置 | 默认值 | 用途 |
| --- | --- | --- |
| `IPHONE_USE_PORT` | `7390` | 主程序、MCP 和录屏脚本使用的 HTTP 端口 |
| `IPHONE_USE_TRACE_POINTER` | 未开启 | 设为 `1` 输出指针调试日志 |
| `CONFIG` | `release` | `scripts/run.sh` 与 `scripts/build-app.sh` 的构建配置 |

例如 `IPHONE_USE_PORT=7400 ./scripts/run.sh`。使用自定义端口时，MCP 进程也必须获得相同环境变量；可在 MCP 配置的 `iphone-use` 对象中添加 `"env": {"IPHONE_USE_PORT": "7400"}`。

持久化数据位于 `~/Library/Application Support/iPhoneUse/`：

- `pairings.json`：USB 设备与蓝牙 host 的映射。
- `pointer-calibration/<host>.json`：绑定 USB 设备身份与分辨率的校准文件。同一手机重新配对后可复用匹配的校准，不按机型共享。

录屏需要安装 `ffmpeg`，并保持主程序运行：

```sh
brew install ffmpeg
./scripts/record.sh demo.mp4
# 可选参数：输出文件、采样帧率、设备 ID
./scripts/record.sh demo.mp4 8 '<完整设备ID>'
```

按 `Ctrl-C` 结束采集后生成 MP4。脚本默认以约 8 FPS 请求最大宽度为 590 像素的截图，按实际收到的帧率生成视频，不录制音频。

## 可选：打包为 macOS 应用

直接运行可执行文件已经包含完整的控制窗口、HTTP 和蓝牙功能。需要 `.app` 目录结构及独立的应用标识、权限用途说明，或希望通过 Finder 启动时，再执行：

```sh
./scripts/build-app.sh
open build/iPhoneUse.app
```

该脚本会复制可执行文件与 `Resources/Info.plist`，然后执行代码签名。默认尝试使用本机的 Apple Development 或 Developer ID Application 身份；没有可用身份或签名失败时退回临时签名（ad hoc）。可以通过 `CODESIGN_IDENTITY` 指定签名身份。脚本不执行公证。

因此，**“无需额外签名”不等于“二进制一定没有签名”**：Apple Silicon 上的 Swift 工具链通常会为可执行文件自动生成链接器临时签名。日常本地运行无需手动执行 `codesign`，也无需购买开发者账号。`.app` 打包不是使用前置步骤。

## 常见问题与限制

| 现象 | 检查方式 |
| --- | --- |
| 没有手机画面 | 确认数据线可传输数据、手机已解锁并信任 Mac、Mac 已允许配件连接和相机访问 |
| 有画面但不能操作 | 检查蓝牙配对、两端确认提示、辅助触控，以及 `/status` 的指针状态 |
| 找不到 “iPhone Use” | 查看 iPhone 蓝牙列表中的 Mac 名称，并对照窗口提示；必要时打开 Mac 蓝牙设置检查连接 |
| API 返回 `409` | 先结束窗口拖拽，再执行坐标操作 |
| API 返回 `503` | 查看响应错误：可能尚无画面，或鼠标订阅、校准尚未就绪 |
| MCP 提示主程序未运行 | 先启动不带 `mcp` 参数的主程序，确认 `/status` 可访问，并检查两端端口配置 |
| 校准网页打不开 | 检查 iPhone 到 Mac 的局域网连通性、`--address` 和网页端口，注意防火墙是否允许访问 |
| 校准后点击仍偏移 | 保持校准时的方向、跟踪速度和显示设置；相对定位不能保证逐像素精度 |

其他使用边界：

- 手机需要保持解锁；长时间操作时请自行调整自动锁定设置。
- 文字输入使用 US 键盘布局，直接输入仅支持 ASCII；中文等内容可借助已配置的通用剪贴板粘贴。
- iOS 没有通用 Back 键，请使用应用内返回按钮，或在支持的页面执行从左缘向右的返回手势。
- 当前使用与校准流程以竖屏为主，未保证横屏和动态旋转行为。
- HTTP API 只监听本机回环地址，没有提供认证或远程访问配置。

## 开发与验证

业务代码位于 `Sources/iPhoneUse/`，按 App、UI、Devices、Capture、Bluetooth、Input、API 和 MCP 分目录。Swift 测试按对应职责组织在 `Tests/iPhoneUseTests/`，校准脚本测试位于 `Tests/PythonTests/`。

模块边界、队列归属和维护约束见 [架构说明](docs/architecture.md)。Swift 格式由 [.swift-format](.swift-format) 统一配置：4 空格缩进、120 字符目标行宽。

```sh
# 格式化与检查
swift format format --in-place --recursive Package.swift Sources Tests/iPhoneUseTests
swift format lint --strict --recursive Package.swift Sources Tests/iPhoneUseTests

# 测试与 Release 构建
swift test
swift build -c release
python3 -B -m unittest discover -s Tests/PythonTests -p 'test_*.py'
```

自动化测试覆盖输入、连接状态、校准、设备匹配、HTTP/MCP 协议与窗口输入模型。涉及硬件行为的修改仍需在真机上验证配对、USB 重连、实际落点和窗口交互。

## 许可
采用 [MIT License](LICENSE)。
