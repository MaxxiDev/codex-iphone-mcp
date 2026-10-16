import AppKit
import Foundation

func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(
        from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
    FileHandle.standardError.write(Data("[\(stamp)] \(message)\n".utf8))
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // The application delegate owns the controller for the whole process. A local
    // top-level variable can be released after startup, which closes its window.
    let windowController = ControlWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
