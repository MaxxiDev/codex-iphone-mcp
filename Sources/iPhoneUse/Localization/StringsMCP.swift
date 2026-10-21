import Foundation

/// Strings for the stdio MCP process: initialize instructions, tool catalog
/// descriptions, and MCP-layer errors. There is deliberately no `current` —
/// the MCP subprocess never reads AppLanguageStore (a different process); it
/// passes the language it fetched from GET /config explicitly. Tool and
/// parameter names stay English in both languages for client compatibility.
struct StringsMCP: LocalizedTable {
    let instructions: String
    let deviceParam: String
    let xPixels: String
    let yPixels: String
    let holdSeconds: String
    let swipePointsDesc: String
    let swipeDurationDesc: String

    // Tool descriptions (MCPTools.swift)
    let toolListDevices: String
    let toolScreenshot: String
    let toolMovePointer: String
    let toolAdjustPointer: String
    let toolClickPointer: String
    let toolTap: String
    let toolLongPress: String
    let toolSwipe: String
    let toolTypeText: String
    let toolPressKey: String
    let toolKeyboardSequence: String
    let toolHome: String

    // MCPToolRequest / MCPKeyboardSequence validation
    let unknownTool: (String) -> String
    let coordinateFinite: (String) -> String
    let hidCountRange: (String) -> String
    let parameterRequired: (String) -> String
    let keyboardSequenceRange: String
    let kbStepLabel: (Int) -> String
    let kbAscii: (String) -> String
    let kbExpected: (String) -> String
    let kbUnknownModifier: (String) -> String

    // MCPServer
    let invalidDeviceList: String
    let expectedOneMatch: (Int) -> String
    let keyboardStopped: (Int, Int, String) -> String
    let screenshotCaption: (String, String, String) -> String
    let noResponse: String
    let appNotRunning: (String) -> String

    // MCPAccess lock errors
    let lockStateDirAbsolute: String
    let lockOpenFailed: (Int32) -> String
    let lockAcquireFailed: (Int32) -> String
    let lockServiceBusy: String
    let lockDeviceBusy: String

    static let zh = StringsMCP(
        instructions:
            "控制真实 iPhone。先截图，再按该手机最新截图的像素坐标点按。连接多台手机时，先调用 list_devices 并给每个工具传入 device。各会话连接独立。每一步操作及其确认截图按手机串行执行；其他会话可能在两次调用之间改变屏幕。",
        deviceParam: "目标 iPhone（list_devices 返回的 id 或名称）。连接多台时才需要传入。",
        xPixels: "截图像素坐标 X",
        yPixels: "截图像素坐标 Y",
        holdSeconds: "长按时长（秒，默认 1）",
        swipePointsDesc: "滑动路径的有序点（截图像素）",
        swipeDurationDesc: "整条路径的移动时长（秒，默认 0.3）",
        toolListDevices: "列出当前连接的 iPhone。",
        toolScreenshot: "截取 iPhone 当前屏幕。",
        toolMovePointer:
            "移动指针但不点击，随后返回截图以便检查实际落点。坐标为最新截图的像素。校准后的点按出现偏移时有用。",
        toolAdjustPointer:
            "在不点击的前提下微调当前指针并返回截图。dx/dy 是相对 HID 计数而非像素；请小幅修正并检查实际落点。不会修改已保存的校准。",
        toolClickPointer:
            "在当前指针位置点击（不移动指针），随后返回截图。请先用 move_pointer 或 adjust_pointer 确认指针位于目标上。其他会话可能在两次调用之间移动指针。",
        toolTap: "点按 iPhone 屏幕上的一个点。坐标为最新截图的像素。",
        toolLongPress: "长按某个点，例如打开上下文菜单。",
        toolSwipe: "沿至少两个点的有序路径持续拖动，直到最后一个点才抬起。坐标为最新截图的像素。",
        toolTypeText: "通过蓝牙键盘在当前聚焦的输入框中输入文字（美式布局，仅 ASCII）。",
        toolPressKey:
            "按下按键，可带修饰键。按键：enter、escape、backspace、tab、space、up、down、left、right 或单个字符。修饰键：cmd、shift、alt、ctrl。cmd+space 打开聚焦搜索。",
        toolKeyboardSequence:
            "在当前应用中执行一段简短、已知的键盘序列，最后返回一张截图。所有步骤在输入前完成校验；同一手机的 MCP 锁覆盖整个序列。出错即停止且不会重放。需要查看中间画面时请拆分为多次调用。最多 16 步、文字总量 256 字符；仅支持美式键盘 ASCII。",
        toolHome: "回到主屏幕。",
        unknownTool: { "未知工具 \($0)" },
        coordinateFinite: { "\($0) 必须是有限且非负的截图坐标" },
        hidCountRange: { "\($0) 必须是 -32...32 内的整数 HID 计数" },
        parameterRequired: { "缺少 \($0)" },
        keyboardSequenceRange: "keyboard_sequence 需要 1...16 个步骤和可选的 device ID",
        kbStepLabel: { "keyboard_sequence 第 \($0) 步" },
        kbAscii: { "\($0)：文字必须使用美式 ASCII 键盘；文字总量上限 256" },
        kbExpected: { "\($0)：需要文字，或一个受支持的按键（可带修饰键）" },
        kbUnknownModifier: { "\($0)：未知的修饰键" },
        invalidDeviceList: "应用返回的设备列表无效",
        expectedOneMatch: { "期望匹配到一台 iPhone，实际 \($0) 台。请调用 list_devices 并传入完整 device ID。" },
        keyboardStopped: { step, count, error in
            "键盘序列在第 \(step)/\(count) 步停止：\(error)。之前的输入可能已执行；继续前请重新截图。"
        },
        screenshotCaption: { "\($0) 的截图，\($1)x\($2) 像素。点按与滑动请使用这些像素坐标。" },
        noResponse: "无响应",
        appNotRunning: { "iPhone Use 应用未运行（\($0)）" },
        lockStateDirAbsolute: "IPHONE_USE_STATE_DIR 必须是所有客户端共享的绝对路径。",
        lockOpenFailed: { "无法打开 MCP 协调锁：\($0)" },
        lockAcquireFailed: { "无法获取 MCP 协调锁：\($0)" },
        lockServiceBusy: "另一个会话正在恢复服务；恢复后请重试。",
        lockDeviceBusy: "设备正被其他会话占用；继续前请重新截图。")

    static let en = StringsMCP(
        instructions:
            "Controls real iPhones. Take a screenshot first, then tap using pixel coordinates from the most recent screenshot of that phone. With several phones connected, call list_devices and pass device to every tool. Sessions have independent connections. Each action and its confirmation screenshot are serialized per phone; other sessions can change the screen between calls.",
        deviceParam: "Which iPhone (id or name from list_devices). Only needed when several are connected.",
        xPixels: "X in screenshot pixels",
        yPixels: "Y in screenshot pixels",
        holdSeconds: "How long to hold (default 1)",
        swipePointsDesc: "Ordered points of the swipe path in screenshot pixels",
        swipeDurationDesc: "Movement duration in seconds for the entire path (default 0.3)",
        toolListDevices: "List the connected iPhones.",
        toolScreenshot: "Take a screenshot of the iPhone screen.",
        toolMovePointer:
            "Move the pointer without clicking, then return a screenshot to inspect the actual landing. Coordinates are pixels of the latest screenshot. Useful when a calibrated tap drifts.",
        toolAdjustPointer:
            "Nudge the current pointer without clicking and return a screenshot. dx and dy are relative HID counts, not pixels; use small corrections and inspect the actual landing. Does not change the saved calibration.",
        toolClickPointer:
            "Click at the current pointer position without moving it, then return a screenshot. First verify the pointer over the intended target with move_pointer or adjust_pointer. Other sessions may move it between calls.",
        toolTap: "Tap a point on the iPhone screen. Coordinates are pixels of the latest screenshot.",
        toolLongPress: "Press and hold a point, e.g. to open a context menu.",
        toolSwipe:
            "Drag continuously through an ordered path of at least two points, keeping contact until the last point. Coordinates are pixels of the latest screenshot.",
        toolTypeText:
            "Type text into the focused field with the Bluetooth keyboard (US layout, ASCII only).",
        toolPressKey:
            "Press a key, optionally with modifiers. Keys: enter, escape, backspace, tab, space, up, down, left, right, or a character. Modifiers: cmd, shift, alt, ctrl. cmd+space opens Spotlight.",
        toolKeyboardSequence:
            "Run a short, known keyboard sequence in the current app with one final screenshot. All steps are validated before input; the same-phone MCP lock covers the whole sequence. Stops on error without replay. Use separate calls when an intermediate screen needs inspection. Up to 16 steps and 256 total text characters; US keyboard ASCII only.",
        toolHome: "Go to the Home Screen.",
        unknownTool: { "unknown tool \($0)" },
        coordinateFinite: { "\($0) must be a finite, nonnegative screenshot coordinate" },
        hidCountRange: { "\($0) must be an integer HID count in -32...32" },
        parameterRequired: { "\($0) is required" },
        keyboardSequenceRange: "keyboard_sequence requires 1...16 steps and an optional device ID",
        kbStepLabel: { "keyboard_sequence step \($0)" },
        kbAscii: { "\($0): text must use the US ASCII keyboard; total text limit is 256" },
        kbExpected: { "\($0): expected text or a supported key with optional modifiers" },
        kbUnknownModifier: { "\($0): unknown keyboard modifier" },
        invalidDeviceList: "Invalid device list from the app",
        expectedOneMatch: {
            "Expected one matching iPhone, found \($0). Call list_devices and pass its full device ID."
        },
        keyboardStopped: { step, count, error in
            "Keyboard sequence stopped at step \(step)/\(count): \(error). Earlier input may have executed; take a fresh screenshot before continuing."
        },
        screenshotCaption: { "Screenshot of \($0), \($1)x\($2) px. Use these pixels for tap and swipe." },
        noResponse: "no response",
        appNotRunning: { "iPhone Use app is not running (\($0))" },
        lockStateDirAbsolute: "IPHONE_USE_STATE_DIR must be an absolute path shared by all clients.",
        lockOpenFailed: { "Cannot open MCP coordination lock: \($0)" },
        lockAcquireFailed: { "Cannot acquire MCP coordination lock: \($0)" },
        lockServiceBusy: "Another session is recovering the service; retry after recovery.",
        lockDeviceBusy: "Device busy in another session; take a fresh screenshot before continuing.")
}
