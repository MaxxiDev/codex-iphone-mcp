import AppKit
import CoreGraphics

/// The same aspect-fit rectangle is used for drawing and input conversion.
struct ControlImageLayout {
    let imageRect: CGRect

    init?(screenSize: CGSize, bounds: CGRect) {
        guard screenSize.width.isFinite, screenSize.height.isFinite,
            bounds.width.isFinite, bounds.height.isFinite,
            screenSize.width > 0, screenSize.height > 0,
            bounds.width > 0, bounds.height > 0
        else { return nil }
        let scale = min(bounds.width / screenSize.width, bounds.height / screenSize.height)
        let imageSize = CGSize(width: screenSize.width * scale, height: screenSize.height * scale)
        imageRect = CGRect(
            x: bounds.midX - imageSize.width / 2, y: bounds.midY - imageSize.height / 2,
            width: imageSize.width, height: imageSize.height)
    }

    /// AppKit view coordinates start at the bottom-left; HID fractions start at
    /// the top-left. Black bars have no phone position unless a drag is clamped.
    func normalizedPoint(_ point: CGPoint, clamp: Bool = false) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        guard
            clamp
                || (point.x >= imageRect.minX && point.x <= imageRect.maxX
                    && point.y >= imageRect.minY && point.y <= imageRect.maxY)
        else { return nil }
        let x = max(imageRect.minX, min(imageRect.maxX, point.x))
        let y = max(imageRect.minY, min(imageRect.maxY, point.y))
        return CGPoint(
            x: (x - imageRect.minX) / imageRect.width,
            y: (imageRect.maxY - y) / imageRect.height)
    }
}

/// Submit only changed positions. Retaining the observed position after a flush
/// lets API gestures move the phone independently while the Mac mouse stays still.
struct ControlMousePosition {
    private var position: CGPoint?
    private var pending: CGPoint?

    mutating func update(_ point: CGPoint) {
        guard position != point else { return }
        position = point
        pending = point
    }

    mutating func takePosition() -> CGPoint? {
        defer { pending = nil }
        return pending
    }

    /// Click and release submit their event position directly, superseding a
    /// hover update that has not reached the next display tick yet.
    mutating func markSubmitted(_ point: CGPoint) {
        position = point
        pending = nil
    }

    mutating func reset() {
        position = nil
        pending = nil
    }
}

/// Separates AppKit event interpretation from sending input to a live phone.
/// Key commands ignore the return value; text commands can request an error beep.
enum ControlKeyboardCommand: Equatable {
    case key(String, modifiers: [String])
    case text(String, modifiers: [String])
}

struct ControlKeyboardEvent {
    let keyCode: UInt16
    let modifierFlags: NSEvent.ModifierFlags
    let characters: String?
    let charactersIgnoringModifiers: String?

    init(_ event: NSEvent) {
        self.init(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers)
    }

    init(
        keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags = [],
        characters: String? = nil, charactersIgnoringModifiers: String? = nil
    ) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
    }

    var isPasteShortcut: Bool {
        modifierFlags.contains(.command) && charactersIgnoringModifiers?.lowercased() == "v"
    }

    static func isPasteShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "v"
    }

    var command: ControlKeyboardCommand? {
        let modifiers = modifierNames
        if let key = Self.specialKeys[keyCode] {
            return .key(key, modifiers: modifiers)
        }
        // Native paste deliberately sends only Command, even if another modifier
        // was held. Both keyDown and AppKit key equivalents use this same rule.
        if isPasteShortcut { return .key("v", modifiers: ["cmd"]) }

        let hasShortcutModifier = modifiers.contains { ["cmd", "alt", "ctrl"].contains($0) }
        let text = (hasShortcutModifier ? charactersIgnoringModifiers : characters) ?? ""
        guard !text.isEmpty else { return nil }
        // Shift is already represented in ordinary typed characters. Forward
        // modifiers separately only for shortcuts, preserving keyboard semantics.
        return .text(text, modifiers: hasShortcutModifier ? modifiers : [])
    }

    private var modifierNames: [String] {
        var names: [String] = []
        if modifierFlags.contains(.command) { names.append("cmd") }
        if modifierFlags.contains(.shift) { names.append("shift") }
        if modifierFlags.contains(.option) { names.append("alt") }
        if modifierFlags.contains(.control) { names.append("ctrl") }
        return names
    }

    private static let specialKeys: [UInt16: String] = [
        0x24: "enter", 0x4C: "enter", 0x30: "tab", 0x31: "space",
        0x33: "backspace", 0x75: "forwarddelete", 0x35: "escape",
        0x7B: "left", 0x7C: "right", 0x7D: "down", 0x7E: "up",
        0x73: "home", 0x77: "end", 0x74: "pageup", 0x79: "pagedown",
    ]
}
