import Foundation

/// Turns taps, swipes and text into HID reports for one phone. Each phone has its own
/// serial queue, so gestures never interleave and phones work in parallel.
final class DeviceInput {
    let host: UUID
    let session: UUID?

    var isCurrentSession: Bool {
        guard let session else { return false }
        return hid.connectionSession(for: host) == session
    }

    /// Transport readiness is independent of pointer calibration. A missing or
    /// mismatched calibration must not be presented as a Bluetooth disconnect.
    var isBluetoothReady: Bool {
        let reports: [ReportID] =
            calibration != nil
            ? [.keyboard, .relativeMouse, .consumer]
            : [.keyboard, .absolutePointer, .relativeMouse, .consumer]
        return reports.allSatisfy { hid.isReady(report: $0, host: host, session: session) }
    }

    var isPointerReady: Bool {
        coordinateMappingAvailable
            && (calibration != nil || hid.isReady(report: .absolutePointer, host: host, session: session))
            && hid.isReady(report: .relativeMouse, host: host, session: session)
    }

    // Gesture state is confined to this queue. Only motion supersession is
    // accessed from both the caller's thread and the queue, through its lock.
    private let queue: DispatchQueue
    private let hid = HIDPeripheral.shared
    private var buttons: UInt8 = 0
    private let reportSender: (ReportID, [UInt8]) -> Void
    private let sleep: (TimeInterval) -> Void
    private var windowDragging = false
    let calibration: RelativePointerCalibration?
    private var estimatedPosition: CGPoint?
    private var lastTrackingMovement: RelativePointerCalibration.Movement?
    private let motionSequence = PointerMotionSequence()
    private let calibrationRequired: Bool
    private let calibrationFilePresent: Bool
    private let screenSize: (() -> CGSize?)?

    /// A compact snapshot for `/status`; this is deliberately read-only and does
    /// not expose the calibration curve itself.
    var pointerStatus: [String: Any] {
        let currentSize = screenSize?()
        let mode: String
        if calibration != nil {
            mode = "relative-calibrated"
        } else if calibrationRequired {
            mode = "calibration-unavailable"
        } else {
            mode = "absolute"
        }
        var calibrationInfo: [String: Any] = [
            "filePresent": calibrationFilePresent,
            "loaded": calibration != nil,
            "mode": mode,
        ]
        if let currentSize {
            calibrationInfo["screenWidth"] = Int(currentSize.width)
            calibrationInfo["screenHeight"] = Int(currentSize.height)
        }
        if let calibration {
            calibrationInfo["calibratedWidth"] = calibration.screenWidth
            calibrationInfo["calibratedHeight"] = calibration.screenHeight
            calibrationInfo["screenMatches"] = currentSize.map(calibration.matches) ?? false
            calibrationInfo["vectorModel"] = calibration.vectorModel?.rawValue ?? "single-axis"
        } else {
            calibrationInfo["screenMatches"] = false
        }
        return [
            "ready": isPointerReady,
            "sessionCurrent": isCurrentSession,
            "coordinateMappingAvailable": coordinateMappingAvailable,
            "calibration": calibrationInfo,
        ]
    }

    private var coordinateMappingAvailable: Bool {
        if calibrationRequired && calibration == nil { return false }
        if let calibration, let screenSize {
            guard let size = screenSize(), calibration.matches(size) else { return false }
        }
        return true
    }

    init(
        host: UUID,
        session: UUID?,
        calibration: RelativePointerCalibration? = nil,
        calibrationRequired: Bool = false,
        calibrationFilePresent: Bool? = nil,
        screenSize: (() -> CGSize?)? = nil,
        sleep: @escaping (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
        reportSender: ((ReportID, [UInt8]) -> Void)? = nil
    ) {
        self.host = host
        self.session = session
        self.calibration = calibration
        self.calibrationRequired = calibrationRequired
        self.calibrationFilePresent = calibrationFilePresent ?? calibrationRequired
        self.screenSize = screenSize
        self.sleep = sleep
        self.reportSender =
            reportSender ?? { id, bytes in
                HIDPeripheral.shared.send(id, bytes, to: host, session: session)
            }
        queue = DispatchQueue(label: "iphone-use.input.\(host)")
    }

    /// Seconds between reports. BLE connection intervals are ~15-30 ms.
    var step: TimeInterval = 0.03

}

// MARK: - Pointer gestures

extension DeviceInput {
    /// Coordinates are fractions of the screen, 0...1 from the top-left corner.
    func tap(x: Double, y: Double, hold: TimeInterval = 0.08) throws {
        try performCoordinateGesture {
            pointer(x, y)
            pause(step * 2)
            button(down: true)
            pause(hold)
            button(down: false)
            pause(step)
        }
    }

    /// Follow a polyline with one press and release. `duration` is the total
    /// movement wait; positioning, button pacing and calibrated HID reports
    /// retain their own intervals. Segment waits follow physical screen distance.
    func swipe(points: [(Double, Double)], duration: TimeInterval) throws {
        try performCoordinateGesture {
            guard points.count >= 2,
                points.allSatisfy({ x, y in
                    x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y)
                })
            else { throw InputError.invalidSwipe("points must contain at least two finite coordinates in 0...1") }
            guard duration.isFinite, duration > 0 else {
                throw InputError.invalidSwipe("duration must be a finite positive number")
            }
            // Validate before any reports: converting an infinite or out-of-range
            // report count to Int would trap, including when a caller sets step=0.
            let reportCount = duration / step
            guard step.isFinite, step > 0, (step * 2).isFinite,
                reportCount.isFinite, reportCount < Double(Int.max)
            else { throw InputError.invalidSwipe("duration and report interval produce an invalid report count") }

            let durations = swipeSegmentDurations(points: points, duration: duration)
            pointer(points[0].0, points[0].1)
            pause(step * 2)
            button(down: true)
            pause(step)
            for (index, segmentDuration) in durations.enumerated() {
                let from = points[index]
                let to = points[index + 1]
                // Two-point paths retain the original interpolation and pacing.
                // Even a very short segment reaches its endpoint before the turn.
                let steps = max(2, Int(segmentDuration / step))
                for i in 1...steps {
                    let t = Double(i) / Double(steps)
                    pointer(from.0 + (to.0 - from.0) * t, from.1 + (to.1 - from.1) * t)
                    pause(segmentDuration / Double(steps))
                }
            }
            button(down: false)
            pause(step)
        }
    }

    private func swipeSegmentDurations(points: [(Double, Double)], duration: TimeInterval) -> [TimeInterval] {
        let fallback =
            calibration.map { CGSize(width: $0.screenWidth, height: $0.screenHeight) }
            ?? CGSize(width: 1, height: 1)
        let size = screenSize?() ?? fallback
        // Only the aspect ratio matters. Scaling first avoids overflow for large
        // dimensions while preserving distances measured in physical pixels.
        let longestSide = max(size.width, size.height)
        let width = size.width / longestSide
        let height = size.height / longestSide
        let lengths = zip(points, points.dropFirst()).map { from, to in
            hypot((to.0 - from.0) * width, (to.1 - from.1) * height)
        }
        let total = lengths.reduce(0, +)
        // A stationary path is still a held gesture for the requested duration.
        return lengths.map { duration * (total > 0 ? $0 / total : 1 / Double(lengths.count)) }
    }

    func move(x: Double, y: Double) throws {
        try performCoordinateGesture {
            pointer(x, y)
            pause(step)
        }
    }

    func positionPointer(x: Double, y: Double) {
        let sequence = motionSequence.advance()
        queue.async {
            guard self.coordinateMappingAvailable else { return }
            // Calibrated movement may take several connection intervals. Drop
            // old hover targets instead of replaying a growing mouse backlog.
            guard self.motionSequence.isCurrent(sequence) else { return }
            self.pointer(x, y, sequence: sequence)
        }
    }

    /// Begin a pointer gesture. Follow with `drag` calls and finish with `release`.
    /// These small operations are intentionally separate so a real mouse drag can be
    /// forwarded while it is happening instead of being buffered as one long swipe.
    func press(x: Double, y: Double) {
        discardPendingMotion()
        queue.async {
            guard !self.windowDragging, self.coordinateMappingAvailable else { return }
            self.windowDragging = true
            self.pointer(x, y)
            // Use the same positioning interval as the coordinate tap API.
            self.pause(self.step * 2)
            self.button(down: true)
        }
    }

    func drag(x: Double, y: Double) {
        let sequence = motionSequence.advance()
        queue.async {
            guard self.windowDragging,
                self.motionSequence.isCurrent(sequence)
            else { return }
            self.pointer(x, y, sequence: sequence)
        }
    }

    func release(x: Double, y: Double) {
        discardPendingMotion()
        queue.async {
            guard self.windowDragging else { return }
            self.pointer(x, y)
            self.button(down: false)
            self.windowDragging = false
        }
    }

    /// Always clear the phone-side button state when the window loses focus or
    /// the mouse interaction is cancelled outside the view.
    func cancelPointer() {
        discardPendingMotion()
        queue.async {
            self.windowDragging = false
            guard self.buttons != 0 else { return }
            self.button(down: false)
        }
    }

    /// A report subscription can disappear while a calibrated movement is being
    /// sent. Drop the predicted landing so the first movement after reconnect
    /// establishes a fresh origin instead of trusting reports that were lost.
    func invalidatePointerEstimate() {
        discardPendingMotion()
        queue.async {
            self.clearPointerEstimate()
        }
    }

    private func discardPendingMotion() {
        motionSequence.advance()
    }

    /// Relative mouse, for testing hosts that ignore the absolute pointer.
    func nudge(dx: Int, dy: Int, click: Bool) throws {
        try queue.sync {
            try requireIdlePointer()
            if dx != 0 || dy != 0 { estimatedPosition = nil }
            var remainingX = dx
            var remainingY = dy
            while remainingX != 0 || remainingY != 0 {
                let sx = max(-127, min(127, remainingX))
                let sy = max(-127, min(127, remainingY))
                send(.relativeMouse, HIDReportPayload.relativeMouse(buttons: 0, dx: sx, dy: sy))
                remainingX -= sx
                remainingY -= sy
                pause(step)
            }
            if click {
                send(.relativeMouse, HIDReportPayload.relativeMouse(buttons: 1))
                pause(0.08)
                send(.relativeMouse, HIDReportPayload.relativeMouse(buttons: 0))
                pause(step)
            }
        }
    }

}

// MARK: - Keyboard and consumer controls

extension DeviceInput {
    /// Keyboard events originating in the control window are asynchronous so text
    /// entry never blocks AppKit's event loop while BLE reports are sent.
    func typeFromKeyboard(_ text: String, modifiers: [String] = []) -> Bool {
        guard let modifierMask = KeyboardMap.modifierMask(for: modifiers) else { return false }
        let strokes = text.compactMap { KeyboardMap.stroke(for: $0) }.map {
            KeyboardMap.Stroke(code: $0.code, modifiers: $0.modifiers | modifierMask)
        }
        guard strokes.count == text.count else { return false }
        queue.async {
            for stroke in strokes { self.press(stroke) }
        }
        return true
    }

    func keyFromKeyboard(_ name: String, modifiers: [String] = []) -> Bool {
        guard let code = KeyboardMap.code(for: name),
            let modifierMask = KeyboardMap.modifierMask(for: modifiers)
        else { return false }
        queue.async {
            self.press(KeyboardMap.Stroke(code: code, modifiers: modifierMask))
        }
        return true
    }

    func type(_ text: String) throws {
        let strokes = try text.map { character -> KeyboardMap.Stroke in
            guard let stroke = KeyboardMap.stroke(for: character) else { throw InputError.untypeable(character) }
            return stroke
        }
        queue.sync {
            for stroke in strokes {
                press(stroke)
            }
        }
    }

    /// A named key with optional modifiers, e.g. key("h", modifiers: ["cmd"]).
    func key(_ name: String, modifiers: [String]) throws {
        guard let code = KeyboardMap.code(for: name)
        else { throw InputError.unknownKey(name) }
        var mask: UInt8 = 0
        for modifier in modifiers {
            guard let bit = KeyboardMap.modifierBit(for: modifier) else { throw InputError.unknownKey(modifier) }
            mask |= bit
        }
        queue.sync { press(KeyboardMap.Stroke(code: code, modifiers: mask)) }
    }

    func consumer(_ usage: UInt16) {
        queue.sync {
            send(.consumer, HIDReportPayload.consumer(usage))
            pause(0.08)
            send(.consumer, HIDReportPayload.consumer(0))
            pause(step)
        }
    }

}

// MARK: - Serialized report generation

extension DeviceInput {
    // Modifier reports must surround the key press/release. Combining these
    // reports changes how hosts interpret shortcuts over BLE intervals.
    fileprivate func press(_ stroke: KeyboardMap.Stroke) {
        if stroke.modifiers != 0 {
            send(.keyboard, HIDReportPayload.keyboard(modifiers: stroke.modifiers))
            pause(step)
        }
        send(.keyboard, HIDReportPayload.keyboard(modifiers: stroke.modifiers, code: stroke.code))
        pause(step)
        send(.keyboard, HIDReportPayload.keyboard(modifiers: stroke.modifiers))
        pause(step)
        if stroke.modifiers != 0 {
            send(.keyboard, HIDReportPayload.keyboard())
            pause(step)
        }
    }

    /// Window and API share either native absolute reports or the host's measured
    /// relative curve. Never mix those motion modes within one input session.
    fileprivate func pointer(_ x: Double, _ y: Double, sequence: UInt64? = nil) {
        if let calibration {
            moveCalibratedPointer(x, y, calibration: calibration, sequence: sequence)
        } else {
            moveAbsolutePointer(x, y, sequence: sequence)
        }
    }

    fileprivate func moveCalibratedPointer(
        _ x: Double, _ y: Double,
        calibration: RelativePointerCalibration, sequence: UInt64?
    ) {
        if estimatedPosition == nil { homeRelativePointer() }
        let target = CGPoint(x: x * Double(calibration.screenWidth), y: y * Double(calibration.screenHeight))
        // Window and API move from the same predicted landing. Only unknown
        // positions need homing. API gestures finish on this serial queue;
        // window tracking can be superseded before its next report.
        while shouldContinueMotion(sequence) {
            guard
                let movement = calibration.trackingStep(
                    from: estimatedPosition ?? .zero, to: target, after: lastTrackingMovement)
            else { break }
            relative(movement.report.dx, movement.report.dy)
            estimatedPosition = movement.position
            lastTrackingMovement = movement.report
            pause(calibration.reportInterval)
        }
    }

    fileprivate func moveAbsolutePointer(_ x: Double, _ y: Double, sequence: UInt64?) {
        guard shouldContinueMotion(sequence) else { return }
        let max = Double(HIDReportMap.absoluteMax)
        let px = UInt16(Swift.max(0, Swift.min(max, (x * max).rounded())))
        let py = UInt16(Swift.max(0, Swift.min(max, (y * max).rounded())))
        send(.absolutePointer, HIDReportPayload.absolutePointer(buttons: buttons, x: px, y: py))
    }

    fileprivate func shouldContinueMotion(_ sequence: UInt64?) -> Bool {
        // Synchronous API gestures have no supersession token and must finish.
        guard let sequence else { return true }
        return motionSequence.isCurrent(sequence)
    }

    fileprivate func homeRelativePointer() {
        guard let calibration else { return }
        // Recover an unknown origin on first use or after invalidation.
        // Never home while a button is held.
        guard buttons == 0 else { return }
        for report in calibration.homingReports {
            relative(report.dx, report.dy)
            pause(calibration.reportInterval)
        }
        estimatedPosition = .zero
        lastTrackingMovement = nil
    }

    fileprivate func relative(_ dx: Int, _ dy: Int) {
        send(.relativeMouse, HIDReportPayload.relativeMouse(buttons: buttons, dx: dx, dy: dy))
    }

    fileprivate func button(down: Bool) {
        buttons = down ? 1 : 0
        send(.relativeMouse, HIDReportPayload.relativeMouse(buttons: buttons))
    }

    /// Coordinate APIs share the same validation order and queue boundary.
    /// Keep pacing inside the operation so a complete gesture stays serialized.
    fileprivate func performCoordinateGesture(_ gesture: () throws -> Void) throws {
        try queue.sync {
            try requireIdlePointer()
            try requireCoordinateMapping()
            try gesture()
        }
    }

    fileprivate func clearPointerEstimate() {
        estimatedPosition = nil
        lastTrackingMovement = nil
    }

    fileprivate func requireIdlePointer() throws {
        guard !windowDragging else { throw InputError.pointerBusy }
    }

    fileprivate func requireCoordinateMapping() throws {
        guard coordinateMappingAvailable else {
            clearPointerEstimate()
            throw InputError.calibrationMismatch
        }
    }

    fileprivate func pause(_ seconds: TimeInterval) {
        sleep(seconds)
    }

    fileprivate func send(_ id: ReportID, _ bytes: [UInt8]) {
        reportSender(id, bytes)
    }

}

extension DeviceInput {
    enum InputError: Error, CustomStringConvertible {
        case untypeable(Character)
        case unknownKey(String)
        case pointerBusy
        case calibrationMismatch
        case invalidSwipe(String)

        var description: String {
            switch self {
            case .untypeable(let c): "cannot type \(String(reflecting: c)) with a US keyboard"
            case .unknownKey(let k): "unknown key \(k)"
            case .pointerBusy: "mouse drag in progress: release the window mouse before a coordinate gesture"
            case .calibrationMismatch:
                "pointer calibration is missing, invalid, or does not match the current screen; recalibrate before coordinate control"
            case .invalidSwipe(let reason): "invalid swipe: \(reason)"
            }
        }
    }
}

/// Supersedes stale window hover/drag targets without touching queue-owned
/// gesture state. Wrapping arithmetic preserves behavior across sequence rollover.
private final class PointerMotionSequence {
    private let lock = NSLock()
    private var value: UInt64 = 0

    @discardableResult
    func advance() -> UInt64 {
        lock.withLock {
            value &+= 1
            return value
        }
    }

    func isCurrent(_ sequence: UInt64) -> Bool {
        lock.withLock { value == sequence }
    }
}
