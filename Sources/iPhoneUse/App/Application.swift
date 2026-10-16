import AppKit
import Foundation

func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(
        from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
    FileHandle.standardError.write(Data("[\(stamp)] \(message)\n".utf8))
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Retain all device controllers for as long as their windows remain open.
    private let windows = ControlWindowCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
        windows.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windows.showAllDevices()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        windows.stop()
    }

    @objc private func showAllDevices(_ sender: Any?) { windows.showAllDevices() }

    private func installMenus() {
        let menu = NSMenu()
        let appMenu = NSMenu(title: "iPhone Use")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let quit = NSMenuItem(
            title: "退出 iPhone Use", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)

        let windowMenu = NSMenu(title: "窗口")
        let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        let showAll = NSMenuItem(title: "显示所有设备", action: #selector(showAllDevices(_:)), keyEquivalent: "")
        showAll.target = self
        windowMenu.addItem(showAll)
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            NSMenuItem(title: "最小化", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"))
        let bringToFront = NSMenuItem(
            title: "全部置于前台", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        bringToFront.target = NSApp
        windowMenu.addItem(bringToFront)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu
    }
}

/// Owns the startup sequence shared by SwiftPM and the packaged application.
/// MCP mode bypasses this path entirely and never starts AppKit or hardware.
enum Application {
    static func run() {
        let port = UInt16(ProcessInfo.processInfo.environment["IPHONE_USE_PORT"] ?? "") ?? 7390

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let appDelegate = AppDelegate()
        app.delegate = appDelegate

        DeviceRegistry.shared.start()
        HIDPeripheral.shared.start()
        ScreenCaptureManager.shared.start()
        let server = HTTPServer(port: port, handler: ControlAPI.handle)
        do {
            try server.start()
            log("listening on http://127.0.0.1:\(port)")
        } catch {
            log("http failed: \(error)")
            exit(1)
        }

        // NSApplication's delegate is weak. Retain both process-owned services until
        // the run loop exits, even when this entry point is optimized in release builds.
        withExtendedLifetime((appDelegate, server)) {
            app.run()
        }
    }
}
