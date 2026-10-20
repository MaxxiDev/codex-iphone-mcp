import XCTest

@testable import iPhoneUse

final class DeviceInputPointerTests: XCTestCase {
    private enum GestureEvent: Equatable {
        case report(ReportID, [UInt8])
        case pause(TimeInterval)
    }

    func testTwoPointSwipeDragsOnTheRelativeCollectionWithEstimatedCounts() throws {
        var reports: [(ReportID, [UInt8])] = []
        var pauses: [TimeInterval] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), screenSize: { CGSize(width: 100, height: 100) },
            sleep: { pauses.append($0) }, reportSender: { reports.append(($0, $1)) })
        input.step = 0.125

        try input.swipe(points: [(0, 0), (1, 1)], duration: 0.5)

        // One absolute hover positions the pointer; the press, movement and
        // release all carry the touch on the relative collection.
        XCTAssertEqual(reports.filter { $0.0 == .absolutePointer }.map { $0.1 }, [[0, 0, 0, 0, 0]])
        XCTAssertEqual(reports.first { $0.0 == .relativeMouse }?.1, [1, 0, 0, 0])
        XCTAssertEqual(reports.last?.0, .relativeMouse)
        XCTAssertEqual(reports.last?.1, [0, 0, 0, 0])
        let movement = reports.filter { $0.0 == .relativeMouse }.dropFirst().dropLast()
        XCTAssertTrue(movement.allSatisfy { $0.1[0] == 1 })
        // Replaying the reports through the estimated gain reaches the target.
        var position = CGPoint(x: 0, y: 0)
        for (_, bytes) in movement {
            position.x += Double(Int8(bitPattern: bytes[1])) * 2
            position.y += Double(Int8(bitPattern: bytes[2])) * 2
        }
        XCTAssertEqual(position.x, 99, accuracy: 1)
        XCTAssertEqual(position.y, 99, accuracy: 1)
        // Positioning and release retain their original pacing.
        XCTAssertEqual(pauses.first, 0.25)
        XCTAssertEqual(pauses.last, 0.125)
        XCTAssertTrue(pauses.allSatisfy { $0.isFinite && $0 >= 0 })
    }

    func testPairingProbeMovesAndCapturesOnTheInputQueue() throws {
        var reports: [(ReportID, [UInt8])] = []
        var captureCount = 0
        let input = DeviceInput(
            host: UUID(), session: UUID(), sleep: { _ in },
            reportSender: { reports.append(($0, $1)) })

        let captures = try input.pairingProbe(
            calibration: nil, firstPoint: CGPoint(x: 0.3, y: 0.35), secondPoint: CGPoint(x: 0.7, y: 0.65),
            wait: 0, isReady: { true },
            capture: {
                captureCount += 1
                return [UInt8(captureCount)]
            })

        XCTAssertEqual(captures.before, [1])
        XCTAssertEqual(captures.after, [2])
        XCTAssertEqual(captureCount, 2)
        XCTAssertEqual(reports.map(\.0), [.absolutePointer, .absolutePointer])
    }

    func testPairingProbeStopsBeforeSendingWhenBluetoothIsNotReady() {
        var reports: [(ReportID, [UInt8])] = []
        var captureCount = 0
        let input = DeviceInput(
            host: UUID(), session: UUID(), sleep: { _ in },
            reportSender: { reports.append(($0, $1)) })

        XCTAssertThrowsError(
            try input.pairingProbe(
                calibration: nil, firstPoint: CGPoint(x: 0.3, y: 0.35), secondPoint: CGPoint(x: 0.7, y: 0.65),
                wait: 0, isReady: { false },
                capture: {
                    captureCount += 1
                    return [UInt8(captureCount)]
                }))

        XCTAssertTrue(reports.isEmpty)
        XCTAssertEqual(captureCount, 0)
    }

    func testAbsolutePointerReadinessRequiresMovementAndClickSubscriptions() {
        let input = DeviceInput(
            host: UUID(), session: UUID(),
            reportReadiness: { report, _, _ in
                [.keyboard, .absolutePointer, .consumer].contains(report)
            })

        XCTAssertFalse(input.isPointerReady)
        XCTAssertFalse(input.isBluetoothReady)

        let readyInput = DeviceInput(
            host: UUID(), session: UUID(),
            reportReadiness: { report, _, _ in
                [.keyboard, .absolutePointer, .relativeMouse, .consumer].contains(report)
            })
        XCTAssertTrue(readyInput.isPointerReady)
        XCTAssertTrue(readyInput.isBluetoothReady)
    }

    func testCalibratedPointerReadinessRequiresRelativeSubscription() {
        let calibration = RelativePointerCalibration(
            host: UUID(), screenWidth: 100, screenHeight: 200,
            reportInterval: 0.01, distances: [0, 1, 3, 8, 20])
        let input = DeviceInput(
            host: calibration.host, session: UUID(), calibration: calibration,
            reportReadiness: { report, _, _ in
                [.keyboard, .relativeMouse, .consumer].contains(report)
            })

        XCTAssertTrue(input.isPointerReady)
        XCTAssertTrue(input.isBluetoothReady)
    }

    func testMultiPointSwipePassesCornersWithoutReleasingAndUsesPixelDistances() throws {
        var reports: [(ReportID, [UInt8])] = []
        var pauses: [TimeInterval] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), screenSize: { CGSize(width: 200, height: 400) },
            sleep: { pauses.append($0) }, reportSender: { reports.append(($0, $1)) })
        input.step = 0.125

        try input.swipe(points: [(0, 0), (1, 0), (1, 1)], duration: 0.75)

        // One absolute hover; the whole drag runs on the relative collection.
        XCTAssertEqual(reports.filter { $0.0 == .absolutePointer }.map { $0.1 }, [[0, 0, 0, 0, 0]])
        XCTAssertEqual(reports.first { $0.0 == .relativeMouse }?.1, [1, 0, 0, 0])
        XCTAssertEqual(reports.last?.1, [0, 0, 0, 0])
        let movement = reports.filter { $0.0 == .relativeMouse }.dropFirst().dropLast()
        XCTAssertTrue(movement.allSatisfy { $0.1[0] == 1 })
        // Replaying through the estimate: the horizontal corner arrives before
        // the turn, and the path ends in the opposite corner.
        var position = CGPoint(x: 0, y: 0)
        var reachedHorizontalCorner = false
        for (_, bytes) in movement {
            let dx = Double(Int8(bitPattern: bytes[1]))
            let dy = Double(Int8(bitPattern: bytes[2]))
            if abs(position.y) <= 1, dy == 0 {
                position.x += dx * 2
            } else {
                XCTAssertEqual(dx, 0, "the vertical segment must not move horizontally")
                position.y += dy * 2
            }
            if abs(position.x - 199) <= 1, abs(position.y) <= 1 { reachedHorizontalCorner = true }
        }
        XCTAssertTrue(reachedHorizontalCorner)
        XCTAssertEqual(position.y, 399, accuracy: 1)
        // The vertical segment is twice as long in pixels, so it receives four
        // intervals while the horizontal segment receives two.
        XCTAssertTrue(pauses.dropFirst(2).dropLast().allSatisfy { $0 == 0.125 })
        XCTAssertGreaterThanOrEqual(pauses.dropFirst(2).dropLast().reduce(0, +), 0.75)
    }

    func testRepeatedSwipePointsKeepOnePressAndPreserveMovementDuration() throws {
        let paths: [[(Double, Double)]] = [
            [(0, 0), (0, 0), (1, 1), (1, 1)],
            [(0.5, 0.5), (0.5, 0.5), (0.5, 0.5)],
        ]
        for points in paths {
            var reports: [(ReportID, [UInt8])] = []
            var pauses: [TimeInterval] = []
            let input = DeviceInput(
                host: UUID(), session: UUID(), sleep: { pauses.append($0) },
                reportSender: { reports.append(($0, $1)) })
            input.step = 0.125

            try input.swipe(points: points, duration: 0.5)

            // One absolute hover, one press, one release — repeated or
            // stationary points never add a second button transition.
            XCTAssertEqual(reports.filter { $0.0 == .absolutePointer }.count, 1)
            XCTAssertEqual(reports.first?.1[0], 0)
            XCTAssertEqual(reports.last?.1[0], 0)
            XCTAssertTrue(reports.dropFirst().dropLast().allSatisfy { $0.1[0] == 1 })
            XCTAssertTrue(pauses.allSatisfy { $0.isFinite && $0 >= 0 })
            XCTAssertEqual(pauses.dropFirst(2).dropLast().reduce(0, +), 0.5, accuracy: 1e-12)
        }
    }

    func testCalibratedMultiPointSwipeVisitsCornersAndUsesCalibrationDimensions() throws {
        let calibration = RelativePointerCalibration(
            host: UUID(), screenWidth: 100, screenHeight: 200,
            reportInterval: 0.01, distances: [0, 1, 3, 8, 20])
        var position = CGPoint(x: 90, y: 190)
        var reports: [(buttons: UInt8, position: CGPoint)] = []
        var pauses: [TimeInterval] = []
        let input = DeviceInput(
            host: calibration.host, session: UUID(), calibration: calibration,
            sleep: { pauses.append($0) },
            reportSender: { id, bytes in
                XCTAssertEqual(id, .relativeMouse)
                let dx = Int(Int8(bitPattern: bytes[1]))
                let dy = Int(Int8(bitPattern: bytes[2]))
                position.x = max(0, min(99, position.x + (dx < 0 ? -1 : 1) * calibration.distances[abs(dx)]))
                position.y = max(0, min(199, position.y + (dy < 0 ? -1 : 1) * calibration.distances[abs(dy)]))
                reports.append((bytes[0], position))
            })
        input.step = 0.125

        try input.swipe(points: [(0.2, 0.2), (0.8, 0.2), (0.8, 0.8)], duration: 0.75)

        let firstPress = try XCTUnwrap(reports.firstIndex { $0.buttons == 1 })
        let heldReports = reports[firstPress..<reports.count - 1]
        XCTAssertEqual(heldReports.first?.position, CGPoint(x: 20, y: 40))
        XCTAssertTrue(heldReports.contains { $0.position == CGPoint(x: 80, y: 40) })
        XCTAssertTrue(heldReports.allSatisfy { $0.buttons == 1 })
        XCTAssertEqual(reports.last?.buttons, 0)
        XCTAssertEqual(position, CGPoint(x: 80, y: 160))
        // Without a capture size, the 100x200 calibration supplies the same 1:2
        // segment ratio. Remove the calibrated report intervals to inspect the
        // six movement waits plus the existing press/release preparation.
        XCTAssertEqual(pauses.filter { $0 != calibration.reportInterval }, [0.25] + Array(repeating: 0.125, count: 8))
    }

    func testVeryShortSwipeSegmentsStillReachEveryCorner() throws {
        var reports: [(ReportID, [UInt8])] = []
        var pauses: [TimeInterval] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), screenSize: { CGSize(width: 200, height: 400) },
            sleep: { pauses.append($0) }, reportSender: { reports.append(($0, $1)) })
        input.step = 0.03

        try input.swipe(points: [(0, 0), (1, 0), (1, 1)], duration: .leastNonzeroMagnitude)

        // The estimated drag converges on every interpolated target, so even
        // a near-zero duration still reaches both corners before releasing.
        let movement = reports.filter { $0.0 == .relativeMouse }.dropFirst().dropLast()
        XCTAssertTrue(movement.allSatisfy { $0.1[0] == 1 })
        var position = CGPoint(x: 0, y: 0)
        var reachedHorizontalCorner = false
        for (_, bytes) in movement {
            let dx = Double(Int8(bitPattern: bytes[1]))
            let dy = Double(Int8(bitPattern: bytes[2]))
            if abs(position.y) <= 1, dy == 0 {
                position.x += dx * 2
            } else {
                XCTAssertEqual(dx, 0)
                position.y += dy * 2
            }
            if abs(position.x - 199) <= 1, abs(position.y) <= 1 { reachedHorizontalCorner = true }
        }
        XCTAssertTrue(reachedHorizontalCorner)
        XCTAssertEqual(position.x, 199, accuracy: 1)
        XCTAssertEqual(position.y, 399, accuracy: 1)
        XCTAssertTrue(pauses.allSatisfy { $0.isFinite && $0 >= 0 })
    }

    func testInvalidSwipeInputsSendNoReportsOrPauses() {
        var reports: [[UInt8]] = []
        var pauses: [TimeInterval] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), sleep: { pauses.append($0) },
            reportSender: { _, bytes in reports.append(bytes) })
        let invalidPoints: [[(Double, Double)]] = [
            [], [(0, 0)], [(0, 0), (.nan, 1)], [(0, 0), (1, .infinity)],
            [(-0.01, 0), (1, 1)], [(0, 0), (1, 1.01)],
        ]
        for points in invalidPoints {
            XCTAssertThrowsError(try input.swipe(points: points, duration: 0.3))
        }
        for duration in [TimeInterval(0), -1, .nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            XCTAssertThrowsError(try input.swipe(points: [(0, 0), (1, 1)], duration: duration))
        }
        for interval in [TimeInterval(0), -1, .nan, .infinity, .leastNonzeroMagnitude, .greatestFiniteMagnitude] {
            input.step = interval
            XCTAssertThrowsError(try input.swipe(points: [(0, 0), (1, 1)], duration: 0.3))
        }
        XCTAssertTrue(reports.isEmpty)
        XCTAssertTrue(pauses.isEmpty)
    }

    func testSwipeRequiresMatchingCalibrationBeforeSendingReports() {
        var reports: [[UInt8]] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), calibrationRequired: true,
            sleep: { _ in }, reportSender: { _, bytes in reports.append(bytes) })

        XCTAssertThrowsError(try input.swipe(points: [(0, 0), (1, 0), (1, 1)], duration: 0.3)) { error in
            guard case DeviceInput.InputError.calibrationMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertTrue(reports.isEmpty)
    }

    func testCoordinateTapAfterWindowMovementUsesRequestedPixels() throws {
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(host: UUID(), session: UUID(), reportSender: { reports.append(($0, $1)) })

        input.positionPointer(x: 1, y: 1)
        try input.tap(x: 500.0 / 750, y: 500.0 / 1334)
        input.positionPointer(x: 0, y: 0)
        try input.tap(x: 0.5, y: 0.5)

        XCTAssertEqual(
            reports.map { $0.0 },
            [
                .absolutePointer, .absolutePointer, .relativeMouse, .relativeMouse,
                .absolutePointer, .absolutePointer, .relativeMouse, .relativeMouse,
            ])
        XCTAssertEqual(
            reports.map { $0.1 },
            [
                [0, 255, 127, 255, 127], [0, 85, 85, 249, 47], [1, 0, 0, 0], [0, 0, 0, 0],
                [0, 0, 0, 0, 0], [0, 0, 64, 0, 64], [1, 0, 0, 0], [0, 0, 0, 0],
            ])
    }

    func testWindowClickPositionsAtMouseDownEvenWithoutHover() throws {
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(host: UUID(), session: UUID(), reportSender: { reports.append(($0, $1)) })

        try input.tap(x: 1, y: 0)
        input.press(x: 0, y: 1)
        input.release(x: 0, y: 1)
        // Wait for all asynchronous window reports without adding a movement.
        try input.nudge(dx: 0, dy: 0, click: false)

        XCTAssertEqual(
            reports.dropFirst(3).map { $0.0 },
            [
                .absolutePointer, .relativeMouse, .relativeMouse,
            ])
        XCTAssertEqual(
            reports.dropFirst(3).map { $0.1 },
            [
                [0, 0, 0, 255, 127], [1, 0, 0, 0], [0, 0, 0, 0],
            ])
    }

    func testWindowDragMovesRelativelyAndRetainsFinalLocation() throws {
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), screenSize: { CGSize(width: 100, height: 100) },
            reportSender: { reports.append(($0, $1)) })

        input.press(x: 0, y: 0)
        input.drag(x: 0.5, y: 0.5)
        input.drag(x: 1, y: 1)
        input.release(x: 1, y: 1)
        try input.nudge(dx: 0, dy: 0, click: false)

        // The queued drags are superseded; the release positions the pointer.
        // One absolute hover, then a wholly relative drag to the release point.
        XCTAssertEqual(reports.first?.1, [0, 0, 0, 0, 0])
        XCTAssertEqual(reports.filter { $0.0 == .absolutePointer }.count, 1)
        XCTAssertEqual(reports.first { $0.0 == .relativeMouse }?.1, [1, 0, 0, 0])
        XCTAssertEqual(reports.last?.1, [0, 0, 0, 0])
        let movement = reports.filter { $0.0 == .relativeMouse }.dropFirst().dropLast()
        XCTAssertTrue(movement.allSatisfy { $0.1[0] == 1 })
        var position = CGPoint(x: 0, y: 0)
        for (_, bytes) in movement {
            position.x += Double(Int8(bitPattern: bytes[1])) * 2
            position.y += Double(Int8(bitPattern: bytes[2])) * 2
        }
        XCTAssertEqual(position.x, 99, accuracy: 1)
        XCTAssertEqual(position.y, 99, accuracy: 1)
    }

    func testWindowDragReleasesButtonStateForEveryPointerReport() throws {
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), sleep: { _ in }, reportSender: { reports.append(($0, $1)) })

        input.press(x: 0.2, y: 0.4)
        input.drag(x: 0.6, y: 0.4)
        // Finish the held movement before the release supersedes pending targets.
        try input.type("")
        input.release(x: 0.8, y: 0.4)
        try input.nudge(dx: 0, dy: 0, click: false)

        // The report map has two independent mouse collections. Releasing one
        // must not be treated as a release of the other's stored button state.
        var buttonStateByReport: [ReportID: UInt8] = [
            .absolutePointer: 0,
            .relativeMouse: 0,
        ]
        for (reportID, payload) in reports {
            guard let buttons = payload.first else { continue }
            buttonStateByReport[reportID] = buttons & 1
        }

        XCTAssertTrue(reports.contains { $0.0 == .relativeMouse && $0.1[0] & 1 == 1 })
        XCTAssertEqual(buttonStateByReport[.absolutePointer], 0, "absolute pointer must not retain a pressed button")
        XCTAssertEqual(buttonStateByReport[.relativeMouse], 0, "relative mouse must not retain a pressed button")
    }

    func testCoordinateGestureCannotInterruptHeldWindowButton() throws {
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(host: UUID(), session: UUID(), reportSender: { reports.append(($0, $1)) })

        input.press(x: 0.5, y: 0.5)
        for gesture in [
            { try input.tap(x: 1, y: 1) },
            { try input.swipe(points: [(0, 0), (1, 0), (1, 1)], duration: 0.06) },
            { try input.move(x: 1, y: 1) },
            { try input.nudge(dx: 1, dy: 1, click: true) },
        ] {
            XCTAssertThrowsError(try gesture()) { error in
                guard case DeviceInput.InputError.pointerBusy = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }
        XCTAssertEqual(reports.count, 2)
        input.release(x: 0.5, y: 0.5)
        try input.tap(x: 1, y: 1)
        XCTAssertEqual(
            reports.suffix(3).map { $0.1 },
            [
                [0, 255, 127, 255, 127], [1, 0, 0, 0], [0, 0, 0, 0],
            ])
    }

    func testFocusCancellationReleasesWindowButtonAndAllowsAPITap() throws {
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(host: UUID(), session: UUID(), reportSender: { reports.append(($0, $1)) })
        input.press(x: 0, y: 0)
        input.cancelPointer()
        // A stale AppKit mouse-up after cancellation must not reposition the phone.
        input.release(x: 1, y: 1)
        try input.tap(x: 0.5, y: 0.5)

        XCTAssertEqual(
            reports.map { $0.0 },
            [
                .absolutePointer, .relativeMouse, .relativeMouse, .absolutePointer,
                .absolutePointer, .relativeMouse, .relativeMouse,
            ])
        XCTAssertEqual(
            reports.map { $0.1 },
            [
                [0, 0, 0, 0, 0], [1, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0, 0],
                [0, 0, 64, 0, 64], [1, 0, 0, 0], [0, 0, 0, 0],
            ])
    }

    func testRapidMovementDeliversFinalPosition() throws {
        var positions: [[UInt8]] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(),
            reportSender: { id, bytes in
                XCTAssertEqual(id, .absolutePointer)
                positions.append(bytes)
            })
        input.positionPointer(x: 0, y: 0)
        input.positionPointer(x: 0.5, y: 0.5)
        input.positionPointer(x: 1, y: 1)
        try input.nudge(dx: 0, dy: 0, click: false)

        XCTAssertEqual(positions.last, [0, 255, 127, 255, 127])
        XCTAssertLessThanOrEqual(positions.count, 3)
    }

    func testInvalidatedCalibratedEstimateHomesBeforeNextWindowMove() throws {
        let calibration = RelativePointerCalibration(
            host: UUID(), screenWidth: 100, screenHeight: 200,
            reportInterval: 0.01, distances: [0, 1, 3, 8, 20])
        var reports: [[UInt8]] = []
        let input = DeviceInput(
            host: calibration.host, session: UUID(), calibration: calibration,
            reportSender: { _, bytes in reports.append(bytes) })

        input.positionPointer(x: 0.5, y: 0.5)
        try input.nudge(dx: 0, dy: 0, click: false)
        reports.removeAll()
        input.invalidatePointerEstimate()
        input.positionPointer(x: 0.5, y: 0.5)
        try input.nudge(dx: 0, dy: 0, click: false)

        // The host may have moved anywhere during the interruption. Replaying
        // the emitted reports must recover the requested position from there.
        var position = CGPoint(x: 90, y: 190)
        for bytes in reports {
            let dx = Int(Int8(bitPattern: bytes[1]))
            let dy = Int(Int8(bitPattern: bytes[2]))
            position.x = max(0, min(99, position.x + (dx < 0 ? -1 : 1) * calibration.distances[abs(dx)]))
            position.y = max(0, min(199, position.y + (dy < 0 ? -1 : 1) * calibration.distances[abs(dy)]))
        }
        XCTAssertEqual(position, CGPoint(x: 50, y: 100))
    }
}
