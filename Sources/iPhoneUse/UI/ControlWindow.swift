import AppKit

final class ControlWindowController: NSWindowController, NSWindowDelegate {
    private let controlView: PhoneControlView
    private let sidebar: ControlSidebar

    init() {
        controlView = PhoneControlView(frame: NSRect(x: 0, y: 0, width: 390, height: 700))
        sidebar = ControlSidebar(frame: .zero)
        let content = ControlWindowContent(phoneView: controlView, sidebar: sidebar)
        let window = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "iPhone Use"
        window.contentView = content
        window.acceptsMouseMovedEvents = true
        window.contentMinSize = NSSize(width: 240 + ControlSidebar.width, height: 460)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.initialFirstResponder = controlView
        window.makeFirstResponder(controlView)
        sidebar.onAction = { [weak controlView] shortcut in
            controlView?.performShortcut(shortcut)
        }
        controlView.onShortcutStateChanged = { [weak sidebar] available, status in
            sidebar?.update(available: available, status: status)
        }
        controlView.onConnectionStateChanged = { [weak content] status in
            content?.updateConnectionState(status)
        }
        controlView.start()
    }

    func windowDidResignKey(_ notification: Notification) {
        controlView.cancelInteraction()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        controlView.cancelInteraction()
    }

    func windowWillClose(_ notification: Notification) {
        controlView.cancelInteraction()
        NSApplication.shared.terminate(nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Keeps the phone geometry separate from the sidebar and places the connection
/// overlay above both so disconnected input cannot reach either control surface.
private final class ControlWindowContent: NSView {
    private let phoneView: NSView
    private let connectionOverlay = ControlConnectionOverlay(frame: .zero)

    init(phoneView: NSView, sidebar: ControlSidebar) {
        self.phoneView = phoneView
        super.init(frame: NSRect(x: 0, y: 0, width: 390 + ControlSidebar.width, height: 700))
        phoneView.translatesAutoresizingMaskIntoConstraints = false
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(phoneView)
        addSubview(sidebar)
        connectionOverlay.translatesAutoresizingMaskIntoConstraints = false
        // Last sibling receives hit testing first while the overlay is visible.
        addSubview(connectionOverlay)
        NSLayoutConstraint.activate([
            phoneView.leadingAnchor.constraint(equalTo: leadingAnchor),
            phoneView.topAnchor.constraint(equalTo: topAnchor),
            phoneView.bottomAnchor.constraint(equalTo: bottomAnchor),
            phoneView.trailingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: ControlSidebar.width),
            sidebar.topAnchor.constraint(equalTo: topAnchor),
            sidebar.trailingAnchor.constraint(equalTo: trailingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            connectionOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            connectionOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            connectionOverlay.topAnchor.constraint(equalTo: topAnchor),
            connectionOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func updateConnectionState(_ status: ControlConnectionStatus) {
        connectionOverlay.update(status)
        window?.makeFirstResponder(status == .connected ? phoneView : connectionOverlay)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
