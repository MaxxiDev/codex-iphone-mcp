# 代码结构与维护约束

本项目通过 USB 采集 iPhone 画面，通过 Bluetooth LE HID 发送输入。窗口、HTTP API 和 MCP 最终使用同一个手机输入队列；重构或扩展功能时，应以这一共享状态为基础。

## 入口与模块

| 目录 | 主要文件与职责 |
| --- | --- |
| 根目录、`App/` | `main.swift` 选择启动模式；`Application.swift` 持有应用级对象并协调启动顺序 |
| `UI/` | `ControlWindow.swift` 管理窗口布局；`PhoneControlView.swift` 协调画面、设备与交互；`ControlInput.swift` 集中坐标/鼠标/键盘转换；侧栏和连接蒙层分别维护 |
| `Devices/` | `DeviceRegistry.swift` 管理设备模型、配对与会话输入缓存；`DevicePairing.swift` 集中配对文件和探测评分 |
| `Capture/` | `ScreenCapture.swift` 包含 `ScreenCaptureManager`（设备发现）与 `ScreenCaptureSession`（单设备帧采集） |
| `Bluetooth/` | `HIDPeripheral.swift` 管理 GATT；`HIDConnectionState.swift` 管理连接和背压；`HIDReports.swift` 定义描述符与报告字节 |
| `Input/` | `DeviceInput.swift` 管理每台手机的输入队列；`KeyboardMap.swift` 定义键盘映射；`RelativePointerCalibration.swift` 定义模型和位移算法，`+Storage.swift` 处理文件兼容与迁移 |
| `API/` | `HTTPServer.swift` 包含传输及请求/响应编解码；`ControlAPI.swift` 包含路由与坐标换算 |
| `MCP/` | `MCPServer.swift` 包含 JSON-RPC 分派和私有 HTTP 客户端；`MCPTools.swift` 定义工具目录与参数映射 |

以上目录位于 `Sources/iPhoneUse/`，共 21 个 Swift 文件。`scripts/calibrate-pointer.py` 负责通过 Safari 测量指针曲线。

## 文件组织原则

同一业务职责中一起变化的小型类型放在同一文件：例如窗口内容容器跟随窗口控制器、画面渲染器跟随手机视图、HTTP 消息模型跟随服务器。仅单文件使用的实现声明为 private；需要独立测试的纯模型保留模块内可见性。

文件按职责拆分，不要求每个类型都有独立文件。状态复杂或有明确独立边界的模块继续分开，例如蓝牙连接状态与 CoreBluetooth 传输、校准计算与配置持久化。类型名描述具体角色，使用 `DeviceRegistry`、`DeviceInput`、`ScreenCaptureManager` 和 `ScreenCaptureSession` 区分管理器、输入执行器和采集会话。

测试位于 `Tests/iPhoneUseTests/`，按 UI、Devices、Bluetooth、Input、API、MCP 分目录。密切相关的小型测试类共享文件，输入跟踪和校准等较大的测试套件保留独立文件。

## 队列和状态归属

- **AppKit 主线程**处理窗口事件与 30 Hz 刷新。键盘和快捷操作异步交给输入队列，避免阻塞事件循环。
- **每个 DeviceInput 的串行队列**拥有按钮状态、窗口拖拽状态和估计位置。HTTP 手势同步执行，窗口事件异步执行。不要把队列内部操作再次同步派发到同一队列。
- **运动序号的锁**用于让新目标打断旧的鼠标跟随。取消的是未发送的轨迹，已发送报告产生的位置必须保留。
- **Bluetooth 队列**拥有 GATT 对象、订阅、会话令牌和待发送报告。DeviceInput 中保存的令牌必须与当前连接匹配，防止重连后发送旧操作。
- **DeviceRegistry 的状态锁**保护配对关系和延迟匹配标记；**输入缓存锁**单独保护 DeviceInput 创建，因为创建过程中会同步读取 Bluetooth 队列。不能把两把锁随意合并。
- **设备匹配队列**串行执行探测。尚未确认的候选屏幕不能绑定旧校准文件。
- **采集队列**写入单个 ScreenCaptureSession 的最新帧，读取方同步取得帧后再渲染；设备发现使用独立锁，变更通知在解锁后发出。

## 保持现有行为时需要核对的边界

1. HTTP 返回字段、错误文案、状态码、默认参数和校验先后顺序都属于接口行为。坐标支持完整屏幕尺寸、缩放截图尺寸以及 fraction；显式 width/height 的覆盖顺序必须保留。
   `swipe` 的 HTTP/MCP 参数统一为至少两个 `{x, y}` 对象的 `points` 数组与可选 `duration`（默认 0.3 秒）。`SwipeRequest` 在发送输入前校验整条路径，并用同一画面尺寸转换所有点；底层在一次串行手势中按下、经过全部点、释放，段间不能松手。分段移动等待时长按屏幕像素距离分配，总和为 duration，额外准备、释放及校准耗时不计入该值。
2. MCP 成功执行动作后等待 0.6 秒再截图。工具目录、参数映射、截图尺寸说明及错误封装都需要兼容现有客户端。
3. GATT 服务/特征的发布顺序、UUID、权限、描述符及 HID 字节布局涉及手机端缓存，不能当作普通内部实现任意调整。
4. 蓝牙背压只能合并相邻、同设备、同按钮状态的绝对位置报告；按键、按钮变化和相对位移必须按顺序发送。
5. 拖拽期间 API 坐标手势返回冲突。失焦、释放、取消和重连时，要保留原有的按钮释放及位置失效顺序。
6. 校准计算中的取整、候选遍历顺序、单轴/向量模型、报告间隔和归位条件都会影响真实落点。修改结构时应保持这些表达式与顺序。
7. `pairings.json` 和指针校准 JSON 属于用户已有数据。手机 USB 身份、Bluetooth host、分辨率与迁移规则必须一起检查。

## Swift 代码风格

使用 Swift 工具链自带的 `swift format`，配置统一保存在仓库根目录 `.swift-format`：4 空格缩进、120 字符目标行宽、最多一个连续空行，其余采用工具默认 Swift 规则。格式化覆盖 Package.swift、业务源码和 Swift 测试，不扫描构建产物。

```sh
swift format format --in-place --recursive Package.swift Sources Tests/iPhoneUseTests
swift format lint --strict --recursive Package.swift Sources Tests/iPhoneUseTests
```

## 验证

```sh
swift test
swift build -c release
python3 -B -m unittest discover -s Tests/PythonTests -p 'test_*.py'
```

Swift 测试通过注入报告发送器和纯状态模型覆盖输入时序、断线重连、位置追踪、校准迁移和窗口几何，并覆盖协议解析、键盘映射与配对文件兼容性。Python 测试使用模拟移动和页面事件，避免控制真实手机。

自动化测试不能替代真机验收。涉及硬件的改动还需要检查配对/重连、USB 拔插、窗口点击拖拽和失焦释放、HTTP/MCP 手势，以及校准后的实际落点。
