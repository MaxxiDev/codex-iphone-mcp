import AppKit
import CoreImage
import CoreVideo

/// A lightweight scrcpy-style window. The screen is drawn directly from the latest
/// CVPixelBuffer and mouse events are sent to the phone's HID input queue.
final class PhoneControlView: NSView {
    private var binding: ControlDeviceBinding
    private var timer: Timer?
    private var tracking: NSTrackingArea?
    private var device: Device?
    private var input: DeviceInput?
    private var dragging = false
    private var mousePosition = ControlMousePosition()
    private var pointerReady = false
    private let inputQueue = DispatchQueue(label: "iphone-use.window-input-resolution")
    private let shortcutQueue = DispatchQueue(label: "iphone-use.window-shortcuts")
    private var activeShortcut: ControlShortcut?
    private var shortcutFeedback: (text: String, expires: Date)?
    private var lastShortcutState: (available: Set<ControlShortcut>, status: String)?
    var onShortcutStateChanged: ((Set<ControlShortcut>, String) -> Void)?
    private var connectionStatus: ControlConnectionStatus?
    var onConnectionStateChanged: ((ControlConnectionStatus) -> Void)?

    private var canSendWindowInput: Bool {
        binding.acceptsEvents(isKeyWindow: window?.isKeyWindow == true)
            && connectionStatus == .connected && input?.isBluetoothReady == true
    }

    // MARK: View lifecycle and rendering

    init(deviceID: String?, frame: NSRect) {
        binding = ControlDeviceBinding(deviceID: deviceID)
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        // The image rectangle changes on resize. End a drag and let the next
        // sample position the pointer using the new geometry.
        cancelInteraction()
        super.setFrameSize(newSize)
    }

    func start() {
        guard timer == nil else { return }
        binding.start()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.refreshDevice()
            self?.synchronizeMousePosition()
            self?.needsDisplay = true
        }
        self.timer = timer
        // Keep refreshing during AppKit's mouse tracking modes as well.
        RunLoop.main.add(timer, forMode: .common)
        refreshDevice()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        binding.stop()
        cancelInteraction()
        device = nil
        input = nil
        pointerReady = false
        activeShortcut = nil
        shortcutFeedback = nil
        connectionStatus = nil
        lastShortcutState = nil
    }

    deinit { timer?.invalidate() }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.intersection(bounds).fill()
        guard let buffer = device?.screen.frame() else {
            ControlScreenRenderer.drawWaitingMessage(in: bounds)
            return
        }
        ControlScreenRenderer.draw(buffer, in: bounds)
    }

    // MARK: AppKit input events

    override func mouseMoved(with event: NSEvent) {
        recordMousePosition(event, clampToImage: false)
    }

    override func mouseEntered(with event: NSEvent) {
        if !dragging { mousePosition.reset() }
        recordMousePosition(event, clampToImage: dragging)
        flushMousePosition()
    }

    override func mouseExited(with event: NSEvent) {
        if !dragging {
            flushMousePosition()
            mousePosition.reset()
        }
    }

    override func mouseDown(with event: NSEvent) {
        // A subscription can become ready between timer ticks. Complete that
        // transition before starting a gesture so the next tick cannot cancel it.
        updatePointerReadiness()
        guard canSendWindowInput, activeShortcut == nil, pointerReady, let device, let input,
            let position = normalizedPoint(event.locationInWindow, device: device)
        else { return }
        window?.makeFirstResponder(self)
        if ProcessInfo.processInfo.environment["IPHONE_USE_TRACE_POINTER"] == "1" {
            log(
                "mouse down window=\(event.locationInWindow) normalized=\(position) sessionCurrent=\(input.isCurrentSession)"
            )
        }
        dragging = true
        mousePosition.markSubmitted(position)
        // Always position from this click's coordinates, even if an enter or
        // hover event arrived before Bluetooth became ready.
        input.press(x: position.x, y: position.y)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        recordMousePosition(event, clampToImage: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        guard canSendWindowInput, let device, let input,
            let position = normalizedPoint(event.locationInWindow, device: device, clamp: true)
        else {
            cancelInteraction()
            return
        }
        mousePosition.markSubmitted(position)
        input.release(x: position.x, y: position.y)
        dragging = false
    }

    override func keyDown(with event: NSEvent) {
        guard canSendWindowInput, let input else { return }
        switch ControlKeyboardEvent(event).command {
        case .key(let key, let modifiers):
            _ = input.keyFromKeyboard(key, modifiers: modifiers)
        case .text(let text, let modifiers):
            if !input.typeFromKeyboard(text, modifiers: modifiers) { NSSound.beep() }
        case nil:
            break
        }
    }

    // AppKit may handle Command-V as a local key equivalent before keyDown is
    // delivered. Forward it explicitly so the phone receives the native paste
    // shortcut and can use Universal Clipboard when available.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true else { return super.performKeyEquivalent(with: event) }
        if ControlKeyboardEvent.isPasteShortcut(event) {
            guard canSendWindowInput, let input else { return true }
            _ = input.keyFromKeyboard("v", modifiers: ["cmd"])
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Gesture and shortcut coordination

    func cancelInteraction() {
        dragging = false
        mousePosition.reset()
        input?.cancelPointer()
    }

    func performShortcut(_ shortcut: ControlShortcut) {
        refreshDevice()
        guard canSendWindowInput, activeShortcut == nil, let input, shortcut.isAvailable(on: input) else { return }
        window?.makeFirstResponder(self)
        // Release any window drag before entering the same input queue used by
        // pointer tracking and HTTP gestures. Keep synchronous HID work off AppKit.
        cancelInteraction()
        activeShortcut = shortcut
        shortcutFeedback = nil
        updateShortcutState()
        let generation = binding.generation
        shortcutQueue.async { [weak self] in
            let feedback: String
            do {
                if input.isBluetoothReady, shortcut.isAvailable(on: input) {
                    try shortcut.perform(on: input)
                    feedback =
                        shortcut.isAvailable(on: input)
                        ? "已发送\(shortcut.title)" : "连接已断开，请重试"
                } else {
                    feedback = "连接未就绪，请重试"
                }
            } catch {
                log("window shortcut \(shortcut.title) failed: \(error)")
                feedback = "操作失败，请重试"
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.binding.isCurrent(generation), self.input === input else { return }
                self.activeShortcut = nil
                self.shortcutFeedback = (feedback, Date().addingTimeInterval(3))
                self.refreshDevice()
            }
        }
    }

    private func updateShortcutState() {
        var available: Set<ControlShortcut> = []
        let status: String
        if connectionStatus != .connected {
            status = device == nil ? "等待 iPhone 连接" : "等待蓝牙连接"
        } else if let activeShortcut {
            status = "正在发送\(activeShortcut.title)…"
        } else if let input, input.isCurrentSession {
            available = Set(ControlShortcut.allCases.filter { $0.isAvailable(on: input) })
            if available.isEmpty {
                status = "等待蓝牙连接"
            } else if let shortcutFeedback, shortcutFeedback.expires > Date() {
                status = shortcutFeedback.text
            } else {
                status = input.isPointerReady ? "已连接" : "指针尚未就绪"
            }
        } else {
            status = device == nil ? "等待 iPhone 连接" : "等待蓝牙连接"
        }
        guard lastShortcutState?.available != available || lastShortcutState?.status != status else { return }
        lastShortcutState = (available, status)
        onShortcutStateChanged?(available, status)
    }

    // MARK: Device and connection transitions

    private func refreshDevice() {
        guard binding.isRunning else { return }
        // Publish connection changes first: they can cancel a gesture and clear
        // shortcut feedback before the sidebar computes its next visible state.
        defer {
            updateConnectionState()
            updateShortcutState()
        }
        // A window never follows a similarly named phone or an ID prefix. A USB
        // reconnect is a new capture object even when the stable ID is unchanged.
        let current = binding.deviceID.flatMap { id in
            DeviceRegistry.shared.all().first { $0.id == id }
        }
        let connection = current.map { device in
            ControlDeviceBinding.Connection(
                deviceID: device.id, captureID: ObjectIdentifier(device.screen), host: device.host,
                session: device.host.flatMap { HIDPeripheral.shared.connectionSession(for: $0) })
        }
        if binding.observe(connection) {
            cancelInteraction()
            input?.invalidatePointerEstimate()
            input = nil
            activeShortcut = nil
            shortcutFeedback = nil
        }
        device = current
        // Matching an unknown Bluetooth host can probe several screens. Resolve
        // it outside AppKit and keep only one outstanding attempt per window.
        if input == nil, let current, let request = binding.beginInputRequest(at: Date()) {
            inputQueue.async { [weak self] in
                let resolved = Self.resolveInput(for: current)
                DispatchQueue.main.async { [weak self] in
                    self?.completeInputRequest(request, input: resolved)
                }
            }
        }
        updatePointerReadiness()
    }

    private static func resolveInput(for device: Device) -> DeviceInput? {
        let registry = DeviceRegistry.shared
        if device.host == nil { registry.match() }
        // The public registry lookup accepts names and prefixes. A window must
        // reselect the exact capture after matching, including during USB removal.
        guard let current = registry.all().first(where: { $0.id == device.id && $0.screen === device.screen }),
            current.host != nil
        else { return nil }
        return try? registry.input(for: current)
    }

    private func completeInputRequest(_ request: ControlDeviceBinding.Request, input resolved: DeviceInput?) {
        // Read fresh USB/BLE state before accepting the result. Closing, restarting,
        // rematching or reconnecting the window invalidates its old request token.
        refreshDevice()
        guard
            binding.finishInputRequest(
                request, host: resolved?.host, session: resolved?.session,
                isCurrentSession: resolved?.isCurrentSession == true)
        else { return }
        input = resolved
        updatePointerReadiness()
        updateConnectionState()
        updateShortcutState()
    }

    private func updateConnectionState() {
        let status: ControlConnectionStatus
        if device == nil {
            status = .waitingForDevice
        } else if let input, input.isCurrentSession {
            status = input.isBluetoothReady ? .connected : .connecting
        } else {
            status = .disconnected
        }
        guard connectionStatus != status else { return }
        cancelInteraction()
        if status != .connected { input?.invalidatePointerEstimate() }
        shortcutFeedback = nil
        connectionStatus = status
        onConnectionStateChanged?(status)
    }

    private func updatePointerReadiness() {
        let ready = input?.isPointerReady == true
        guard ready != pointerReady else { return }
        // Keyboard subscriptions can arrive before the pointer reports. Reset
        // the observed position so readiness triggers fresh positioning.
        cancelInteraction()
        if !ready { input?.invalidatePointerEstimate() }
        pointerReady = ready
    }

    // MARK: Pointer sampling and coordinate conversion

    /// AppKit can omit an enter/move event while activating the window. Polling
    /// also submits the latest changed position at 30 Hz. A stationary mouse
    /// never overrides a position submitted through the API.
    private func synchronizeMousePosition() {
        guard canSendWindowInput, activeShortcut == nil, let window, window.isKeyWindow, let device, let input,
            input.isPointerReady
        else {
            mousePosition.reset()
            return
        }
        // A newly connected phone can appear above the key window without taking
        // focus. Sampling that covered window would steer the wrong phone. During
        // an existing drag, keep tracking beyond the window and clamp to its image.
        let isTopmostWindow =
            dragging
            || NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber
        guard
            binding.acceptsPointerSample(
                isKeyWindow: window.isKeyWindow, isTopmostWindow: isTopmostWindow, isDragging: dragging)
        else {
            mousePosition.reset()
            return
        }
        if let point = normalizedPoint(window.mouseLocationOutsideOfEventStream, device: device, clamp: dragging) {
            mousePosition.update(point)
            flushMousePosition()
        } else {
            flushMousePosition()
            mousePosition.reset()
        }
    }

    private func recordMousePosition(_ event: NSEvent, clampToImage: Bool) {
        guard binding.acceptsEvents(isKeyWindow: window?.isKeyWindow == true) else {
            mousePosition.reset()
            return
        }
        updatePointerReadiness()
        guard canSendWindowInput, activeShortcut == nil, window?.isKeyWindow == true, pointerReady, let device,
            let point = normalizedPoint(event.locationInWindow, device: device, clamp: clampToImage)
        else {
            flushMousePosition()
            mousePosition.reset()
            return
        }
        mousePosition.update(point)
        // Calibrated DeviceInput already coalesces and paces its Bluetooth reports.
        // Forward events immediately; native absolute reports retain the timer
        // throttle so high-frequency mice cannot flood that unpaced path.
        if input?.calibration != nil { flushMousePosition() }
    }

    private func flushMousePosition() {
        guard canSendWindowInput, activeShortcut == nil, let input, input.isPointerReady,
            let position = mousePosition.takePosition()
        else { return }
        if dragging {
            input.drag(x: position.x, y: position.y)
        } else {
            input.positionPointer(x: position.x, y: position.y)
        }
    }

    /// Fractions of the phone image, independent of capture and Retina scale.
    private func normalizedPoint(
        _ windowPoint: NSPoint, device: Device, clamp: Bool = false
    ) -> CGPoint? {
        let point = convert(windowPoint, from: nil)
        guard let size = device.screen.size,
            let layout = ControlImageLayout(screenSize: size, bounds: bounds)
        else { return nil }
        return layout.normalizedPoint(point, clamp: clamp)
    }
}

/// Main-thread state for a window's immutable USB identity and asynchronous input
/// lookup. Keeping this independent of AppKit and hardware makes reconnect races
/// testable without starting capture sessions or requesting Bluetooth permission.
struct ControlDeviceBinding {
    struct Connection: Equatable {
        let deviceID: String
        let captureID: ObjectIdentifier
        let host: UUID?
        let session: UUID?
    }

    struct Request: Equatable {
        let generation: UInt64
        let connection: Connection
    }

    let deviceID: String?
    private(set) var isRunning = false
    private(set) var generation: UInt64 = 0
    private var connection: Connection?
    private var pendingRequest: Request?
    private var lastInputAttempt = Date.distantPast

    init(deviceID: String?) {
        self.deviceID = deviceID
    }

    mutating func start() {
        guard !isRunning else { return }
        isRunning = true
        generation &+= 1
    }

    mutating func stop() {
        isRunning = false
        connection = nil
        generation &+= 1
        lastInputAttempt = .distantPast
        // An already-running lookup still occupies the background queue. Retain
        // its token until completion so stop/start cannot queue duplicate probes.
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        isRunning && self.generation == generation
    }

    func acceptsEvents(isKeyWindow: Bool) -> Bool {
        isRunning && connection != nil && isKeyWindow
    }

    func acceptsPointerSample(isKeyWindow: Bool, isTopmostWindow: Bool, isDragging: Bool) -> Bool {
        acceptsEvents(isKeyWindow: isKeyWindow) && (isDragging || isTopmostWindow)
    }

    /// Foreign IDs, including a longer prefix match, are treated as disconnected.
    @discardableResult
    mutating func observe(_ candidate: Connection?) -> Bool {
        let current = candidate.flatMap { $0.deviceID == deviceID ? $0 : nil }
        guard connection != current else { return false }
        connection = current
        generation &+= 1
        lastInputAttempt = .distantPast
        return true
    }

    mutating func beginInputRequest(at now: Date) -> Request? {
        guard isRunning, let connection, pendingRequest == nil,
            now.timeIntervalSince(lastInputAttempt) >= 1
        else { return nil }
        lastInputAttempt = now
        let request = Request(generation: generation, connection: connection)
        pendingRequest = request
        return request
    }

    mutating func finishInputRequest(
        _ request: Request, host: UUID?, session: UUID?, isCurrentSession: Bool
    ) -> Bool {
        guard pendingRequest == request else { return false }
        pendingRequest = nil
        guard isCurrent(request.generation), connection == request.connection,
            let host, let session, isCurrentSession
        else { return false }
        return connection?.host == host && connection?.session == session
    }
}

/// Owns the shared image context; the view keeps frame acquisition and redraw timing.
private enum ControlScreenRenderer {
    private static let context = CIContext()

    static func draw(_ buffer: CVPixelBuffer, in bounds: CGRect) {
        let image = CIImage(cvPixelBuffer: buffer)
        let source = image.extent
        guard let layout = ControlImageLayout(screenSize: source.size, bounds: bounds) else { return }
        // Rendering through the view's CGContext is more reliable than relying on
        // CIContext's implicit current-context selection in a regular NSView.
        guard let cgImage = context.createCGImage(image, from: source),
            let cgContext = NSGraphicsContext.current?.cgContext
        else { return }
        cgContext.interpolationQuality = .high
        cgContext.draw(cgImage, in: layout.imageRect)
    }

    static func drawWaitingMessage(in bounds: CGRect) {
        let text = "等待 iPhone 画面…\n请解锁手机并确认已配对 Bluetooth"
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.8),
            .font: NSFont.systemFont(ofSize: 16), .paragraphStyle: style,
        ]
        (text as NSString).draw(in: bounds.insetBy(dx: 20, dy: bounds.height / 2 - 30), withAttributes: attributes)
    }
}
