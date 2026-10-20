import AppKit
import IOBluetooth

enum ControlConnectionStatus {
    case waitingForDevice, disconnected, connecting, connected
}

/// Covers the complete content area, including shortcuts, while keeping the
/// captured screen visible underneath. Window input is also gated at its source.
final class ControlConnectionOverlay: NSView {
    private let title = NSTextField(labelWithString: "蓝牙未连接")
    private let message = NSTextField(wrappingLabelWithString: "")
    private var hasConnected = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("连接提示")

        let card = makeMessageCard()
        let icon = makeIconAndConfigureLabels()
        let instructions = makePairingInstructions()
        let help = makeTroubleshootingLabel()
        let stack = makeMessageStack(
            card: card, icon: icon, instructions: instructions, help: help)
        installConstraints(card: card, stack: stack, icon: icon, instructions: instructions, help: help)
        update(.disconnected)
    }

    private func makeMessageCard() -> NSView {
        let card = ConnectionMessageCard()
        card.wantsLayer = true
        card.layer?.cornerRadius = 16
        card.layer?.masksToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        return card
    }

    private func makeIconAndConfigureLabels() -> NSImageView {
        let icon = NSImageView(
            image: NSImage(
                systemSymbolName: "antenna.radiowaves.left.and.right.slash",
                accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .systemOrange
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        title.alignment = .center
        message.font = .systemFont(ofSize: 13)
        message.alignment = .center
        message.textColor = .secondaryLabelColor
        return icon
    }

    private func makePairingInstructions() -> NSTextField {
        let advertisedName = HIDPeripheral.shared.localName
        // The advertising name does not give this app a separate Bluetooth
        // identity. iOS may show the Mac's controller name instead.
        let controllerName = IOBluetoothHostController.default()?.nameAsString()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceNames: String
        if let controllerName, !controllerName.isEmpty, controllerName != advertisedName {
            deviceNames = "选择「\(advertisedName)」；也可能显示为本机名称「\(controllerName)」。"
        } else {
            deviceNames = "选择「\(advertisedName)」；也可能显示为这台 Mac 的蓝牙名称。"
        }
        let instructions = NSTextField(
            wrappingLabelWithString: """
                1. 在 Mac 和 iPhone 上开启蓝牙。

                2. 在 iPhone 打开「设置 → 辅助功能 → 触控 → 辅助触控」，开启辅助触控。

                3. 进入「设备 → 蓝牙设备」，\(deviceNames)

                4. 在两端按提示确认配对；已配对时在此页面点按重新连接。蒙层消失后即可操作。
                """)
        instructions.font = .systemFont(ofSize: 12)
        return instructions
    }

    private func makeTroubleshootingLabel() -> NSTextField {
        let help = NSTextField(
            wrappingLabelWithString:
                "连接失败时，可打开 Mac「系统设置 → 蓝牙」检查状态及配对提示，再从 iPhone 重试。若找不到设备，请检查 Mac「隐私与安全性 → 蓝牙」中 iPhone Use 的权限。")
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        return help
    }

    private func makeMessageStack(
        card: NSView, icon: NSImageView, instructions: NSTextField, help: NSTextField
    ) -> NSStackView {
        let stack = NSStackView(views: [icon, title, message, instructions, help])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        return stack
    }

    private func installConstraints(
        card: NSView, stack: NSStackView, icon: NSImageView,
        instructions: NSTextField, help: NSTextField
    ) {
        let preferredWidth = card.widthAnchor.constraint(equalToConstant: 420)
        preferredWidth.priority = NSLayoutConstraint.Priority(500)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            preferredWidth,
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
            icon.heightAnchor.constraint(equalToConstant: 32),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
            instructions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            help.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    func update(_ status: ControlConnectionStatus) {
        if status == .connected { hasConnected = true }
        isHidden = status == .connected
        switch status {
        case .waitingForDevice:
            title.stringValue = "等待 iPhone 画面"
            message.stringValue = "当前无法操作。请通过 USB 连接并解锁一台 iPhone，确认信任此 Mac。"
        case .disconnected:
            title.stringValue = hasConnected ? "蓝牙已断开" : "蓝牙未连接"
            message.stringValue = "当前无法操作 iPhone，请先连接蓝牙。"
        case .connecting:
            title.stringValue = "蓝牙连接尚未就绪"
            message.stringValue = "当前无法操作 iPhone，正在等待连接完成。"
        case .connected:
            break
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {}

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.45).setFill()
        dirtyRect.fill(using: .sourceOver)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class ConnectionMessageCard: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16).fill()
    }
}
