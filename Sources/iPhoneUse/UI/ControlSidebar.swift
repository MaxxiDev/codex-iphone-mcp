import AppKit

/// A fixed-width sibling of the phone view, so toolbar clicks and its width never
/// participate in phone coordinate conversion.
final class ControlSidebar: NSView {
    static let width: CGFloat = 116
    private static let shortcutGroups: [(title: String, shortcuts: [ControlShortcut])] = [
        ("导航", [.home, .search]),
        ("输入", [.paste, .enter]),
        ("音量", [.volumeUp, .volumeDown]),
    ]

    var onAction: ((ControlShortcut) -> Void)?
    private var buttons: [ControlShortcut: NSButton] = [:]
    private let status = NSTextField(wrappingLabelWithString: "等待连接")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let stack = makeShortcutStack()
        configureStatusLabel()
        let divider = makeDivider()
        installConstraints(stack: stack, divider: divider)
    }

    func update(available: Set<ControlShortcut>, status text: String) {
        for (shortcut, button) in buttons { button.isEnabled = available.contains(shortcut) }
        status.stringValue = text
        status.toolTip = text
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        // AppKit can invalidate beyond a view's bounds. Do not paint over the
        // adjacent phone image when redrawing the sidebar.
        dirtyRect.intersection(bounds).fill()
    }

    private func makeShortcutStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for group in Self.shortcutGroups {
            addShortcutGroup(title: group.title, shortcuts: group.shortcuts, to: stack)
        }
        return stack
    }

    private func addShortcutGroup(title: String, shortcuts: [ControlShortcut], to stack: NSStackView) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        stack.addArrangedSubview(label)
        for shortcut in shortcuts {
            let button = makeButton(for: shortcut)
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            buttons[shortcut] = button
        }
        if let lastView = stack.arrangedSubviews.last {
            stack.setCustomSpacing(16, after: lastView)
        }
    }

    private func makeButton(for shortcut: ControlShortcut) -> NSButton {
        let button = NSButton(title: shortcut.title, target: self, action: #selector(activate(_:)))
        button.tag = shortcut.rawValue
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: shortcut.symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.font = .systemFont(ofSize: 12)
        button.toolTip = shortcut.help
        button.setAccessibilityLabel(shortcut.title)
        button.isEnabled = false
        return button
    }

    private func configureStatusLabel() {
        status.font = .systemFont(ofSize: 10)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 3
        status.translatesAutoresizingMaskIntoConstraints = false
        addSubview(status)
    }

    private func makeDivider() -> NSBox {
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)
        return divider
    }

    private func installConstraints(stack: NSStackView, divider: NSBox) {
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            status.topAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 16),
            status.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
        ])
    }

    @objc private func activate(_ sender: NSButton) {
        guard let shortcut = ControlShortcut(rawValue: sender.tag) else { return }
        onAction?(shortcut)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

enum ControlShortcut: Int, CaseIterable {
    case home, search, paste, enter, volumeUp, volumeDown

    var title: String {
        switch self {
        case .home: "Home"
        case .search: "搜索"
        case .paste: "粘贴"
        case .enter: "回车"
        case .volumeUp: "音量 +"
        case .volumeDown: "音量 −"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .search: "magnifyingglass"
        case .paste: "doc.on.clipboard"
        case .enter: "return"
        case .volumeUp: "speaker.plus"
        case .volumeDown: "speaker.minus"
        }
    }

    var help: String {
        switch self {
        case .home: "返回 iPhone 主屏幕"
        case .search: "打开 iPhone 搜索（⌘ Space）"
        case .paste: "在手机上粘贴（⌘ V）；粘贴 Mac 内容需启用通用剪贴板"
        case .enter: "发送回车键"
        case .volumeUp: "提高 iPhone 音量"
        case .volumeDown: "降低 iPhone 音量"
        }
    }

    var report: ReportID {
        switch self {
        case .home, .volumeUp, .volumeDown: .consumer
        case .search, .paste, .enter: .keyboard
        }
    }

    func isAvailable(on input: DeviceInput) -> Bool {
        guard input.isCurrentSession else { return false }
        return HIDPeripheral.shared.isReady(report: report, host: input.host, session: input.session)
    }

    func perform(on input: DeviceInput) throws {
        switch self {
        case .home: input.consumer(0x0223)
        case .search: try input.key("space", modifiers: ["cmd"])
        case .paste: try input.key("v", modifiers: ["cmd"])
        case .enter: try input.key("enter", modifiers: [])
        case .volumeUp: input.consumer(0x00E9)
        case .volumeDown: input.consumer(0x00EA)
        }
    }
}
