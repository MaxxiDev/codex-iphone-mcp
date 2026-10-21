import Foundation

/// Strings for the browser viewer page served at GET /viewer. `jsDictionary`
/// carries everything the inline script needs; it is embedded as JSON so English
/// apostrophes can never break the JS string literals.
struct StringsWeb: LocalizedTable {
    let htmlLang: String
    let title: String
    let stateConnecting: String
    let deviceSelectLabel: String
    let deviceSearching: String
    let pauseButton: String
    let resumeButton: String
    let imgAlt: String
    let emptyTitle: String
    let emptyDetail: String
    let footerControl: String
    let usbFrame: String

    // JS-visible strings (embedded via jsDictionary)
    let jsDisconnectedPrefix: String
    let jsNoDevices: String
    let jsStateWaiting: String
    let jsDisconnectedTitle: String
    let jsWaitingDeviceTitle: String
    let jsDisconnectedDetail: String
    let jsWaitingDeviceDetail: String
    let jsStateOffline: String
    let jsOfflineTitle: String
    let jsOfflineDetail: String
    let jsStateLive: String
    let jsStateWaitingFrame: String
    let jsFrameFailTitle: String
    let jsFrameFailDetail: String
    let jsStateSwitching: String
    let jsSwitchingTitle: String
    let jsSwitchingDetail: String
    let jsStatePaused: String
    let jsPausedTitle: String
    let jsPausedDetail: String
    let jsResumingTitle: String
    let jsResumingDetail: String

    var jsDictionary: [String: String] {
        [
            "pauseButton": pauseButton,
            "resumeButton": resumeButton,
            "disconnectedPrefix": jsDisconnectedPrefix,
            "noDevices": jsNoDevices,
            "stateWaiting": jsStateWaiting,
            "disconnectedTitle": jsDisconnectedTitle,
            "waitingDeviceTitle": jsWaitingDeviceTitle,
            "disconnectedDetail": jsDisconnectedDetail,
            "waitingDeviceDetail": jsWaitingDeviceDetail,
            "stateOffline": jsStateOffline,
            "offlineTitle": jsOfflineTitle,
            "offlineDetail": jsOfflineDetail,
            "stateLive": jsStateLive,
            "stateWaitingFrame": jsStateWaitingFrame,
            "frameFailTitle": jsFrameFailTitle,
            "frameFailDetail": jsFrameFailDetail,
            "stateSwitching": jsStateSwitching,
            "switchingTitle": jsSwitchingTitle,
            "switchingDetail": jsSwitchingDetail,
            "statePaused": jsStatePaused,
            "pausedTitle": jsPausedTitle,
            "pausedDetail": jsPausedDetail,
            "resumingTitle": jsResumingTitle,
            "resumingDetail": jsResumingDetail,
        ]
    }

    static let zh = StringsWeb(
        htmlLang: "zh-CN",
        title: "iPhone Use · 实时画面",
        stateConnecting: "连接中",
        deviceSelectLabel: "选择 iPhone",
        deviceSearching: "正在查找 iPhone…",
        pauseButton: "暂停画面",
        resumeButton: "继续画面",
        imgAlt: "iPhone 实时画面",
        emptyTitle: "正在连接 iPhone Use",
        emptyDetail: "手机画面将在这里显示。",
        footerControl: "通过 Codex 聊天控制手机",
        usbFrame: "USB 画面",
        jsDisconnectedPrefix: "已断开 · ",
        jsNoDevices: "暂无连接的 iPhone",
        jsStateWaiting: "等待连接",
        jsDisconnectedTitle: "iPhone 已断开",
        jsWaitingDeviceTitle: "等待 iPhone 连接",
        jsDisconnectedDetail: "重新连接这台 iPhone 后，画面会自动恢复。也可以在上方选择其他手机。",
        jsWaitingDeviceDetail: "用 USB 连接 iPhone，解锁手机并选择“信任此电脑”。",
        jsStateOffline: "未连接",
        jsOfflineTitle: "无法连接 iPhone Use",
        jsOfflineDetail: "请确认 Mac 上的主程序仍在运行，连接恢复后会自动重试。",
        jsStateLive: "实时画面",
        jsStateWaitingFrame: "等待画面",
        jsFrameFailTitle: "暂时无法获取画面",
        jsFrameFailDetail: "请解锁 iPhone，确认 USB 连接和 Mac 的相机授权。",
        jsStateSwitching: "切换中",
        jsSwitchingTitle: "正在连接所选 iPhone",
        jsSwitchingDetail: "手机画面即将显示。",
        jsStatePaused: "已暂停",
        jsPausedTitle: "画面已暂停",
        jsPausedDetail: "点击“继续画面”恢复实时预览。",
        jsResumingTitle: "正在恢复画面",
        jsResumingDetail: "请稍候。")

    static let en = StringsWeb(
        htmlLang: "en",
        title: "iPhone Use · Live Screen",
        stateConnecting: "Connecting",
        deviceSelectLabel: "Select iPhone",
        deviceSearching: "Searching for iPhones…",
        pauseButton: "Pause video",
        resumeButton: "Resume video",
        imgAlt: "iPhone live screen",
        emptyTitle: "Connecting to iPhone Use",
        emptyDetail: "The phone screen will appear here.",
        footerControl: "Control the phone from the Codex chat",
        usbFrame: "USB video",
        jsDisconnectedPrefix: "Disconnected · ",
        jsNoDevices: "No iPhone connected",
        jsStateWaiting: "Waiting",
        jsDisconnectedTitle: "iPhone disconnected",
        jsWaitingDeviceTitle: "Waiting for iPhone",
        jsDisconnectedDetail:
            "Reconnect this iPhone and the screen will return automatically, or pick another phone above.",
        jsWaitingDeviceDetail: "Connect the iPhone over USB, unlock it, and choose \"Trust This Computer\".",
        jsStateOffline: "Offline",
        jsOfflineTitle: "Cannot reach iPhone Use",
        jsOfflineDetail: "Make sure the Mac app is still running; this page retries automatically.",
        jsStateLive: "Live",
        jsStateWaitingFrame: "Waiting for video",
        jsFrameFailTitle: "Cannot get the screen right now",
        jsFrameFailDetail: "Unlock the iPhone and check the USB connection and the Mac camera permission.",
        jsStateSwitching: "Switching",
        jsSwitchingTitle: "Connecting to the selected iPhone",
        jsSwitchingDetail: "The screen will appear in a moment.",
        jsStatePaused: "Paused",
        jsPausedTitle: "Video paused",
        jsPausedDetail: "Click \"Resume video\" to continue the live preview.",
        jsResumingTitle: "Resuming video",
        jsResumingDetail: "One moment.")
}
