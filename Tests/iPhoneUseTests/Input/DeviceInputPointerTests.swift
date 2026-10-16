import XCTest

@testable import iPhoneUse

final class DeviceInputPointerTests: XCTestCase {
    private enum GestureEvent: Equatable {
        case report(ReportID, [UInt8])
        case pause(TimeInterval)
    }

    func testTwoPointSwipeRetainsReportSequenceAndPacing() throws {
        var events: [GestureEvent] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(),
            sleep: { events.append(.pause($0)) },
            reportSender: { events.append(.report($0, $1)) })
        input.step = 0.125

        try input.swipe(points: [(0, 0), (1, 1)], duration: 0.5)

        XCTAssertEqual(
            events,
            [
                .report(.absolutePointer, [0, 0, 0, 0, 0]), .pause(0.25),
                .report(.relativeMouse, [1, 0, 0, 0]), .pause(0.125),
                .report(.absolutePointer, [1, 0, 32, 0, 32]), .pause(0.125),
                .report(.absolutePointer, [1, 0, 64, 0, 64]), .pause(0.125),
                .report(.absolutePointer, [1, 255, 95, 255, 95]), .pause(0.125),
                .report(.absolutePointer, [1, 255, 127, 255, 127]), .pause(0.125),
                .report(.relativeMouse, [0, 0, 0, 0]), .pause(0.125),
            ])
    }

    func testMultiPointSwipePassesCornersWithoutReleasingAndUsesPixelDistances() throws {
        var reports: [(ReportID, [UInt8])] = []
        var pauses: [TimeInterval] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), screenSize: { CGSize(width: 200, height: 400) },
            sleep: { pauses.append($0) }, reportSender: { reports.append(($0, $1)) })
        input.step = 0.125

        try input.swipe(points: [(0, 0), (1, 0), (1, 1)], duration: 0.75)

        XCTAssertEqual(
            reports.filter { $0.0 == .absolutePointer }.map { $0.1 },
            [
                [0, 0, 0, 0, 0],
                [1, 0, 64, 0, 0], [1, 255, 127, 0, 0],
                [1, 255, 127, 0, 32], [1, 255, 127, 0, 64],
                [1, 255, 127, 255, 95], [1, 255, 127, 255, 127],
            ])
        XCTAssertEqual(reports.filter { $0.0 == .relativeMouse }.map { $0.1 }, [[1, 0, 0, 0], [0, 0, 0, 0]])
        XCTAssertTrue(reports.dropFirst().dropLast().allSatisfy { $0.1[0] == 1 })
        // The vertical segment is twice as long in pixels, so it receives four
        // intervals while the horizontal segment receives two.
        XCTAssertEqual(Array(pauses.dropFirst(2).dropLast()), Array(repeating: 0.125, count: 6))
        XCTAssertEqual(pauses.dropFirst(2).dropLast().reduce(0, +), 0.75)
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

            XCTAssertEqual(reports.filter { $0.0 == .relativeMouse }.map { $0.1 }, [[1, 0, 0, 0], [0, 0, 0, 0]])
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
            host: UUID(), session: UUID(), sleep: { pauses.append($0) },
            reportSender: { reports.append(($0, $1)) })
        input.step = 0.03

        try input.swipe(points: [(0, 0), (1, 0), (1, 1)], duration: .leastNonzeroMagnitude)

        let positions = reports.filter { $0.0 == .absolutePointer }.map { $0.1 }
        XCTAssertEqual(positions[2], [1, 255, 127, 0, 0])
        XCTAssertEqual(positions.last, [1, 255, 127, 255, 127])
        XCTAssertEqual(reports.filter { $0.0 == .relativeMouse }.count, 2)
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
                .absolutePointer, .relativeMouse, .absolutePointer, .relativeMouse,
            ])
        XCTAssertEqual(
            reports.dropFirst(3).map { $0.1 },
            [
                [0, 0, 0, 255, 127], [1, 0, 0, 0], [1, 0, 0, 255, 127], [0, 0, 0, 0],
            ])
    }

    func testWindowDragRetainsFinalLocationAndNeverSendsRelativeMovement() throws {
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(host: UUID(), session: UUID(), reportSender: { reports.append(($0, $1)) })

        input.press(x: 0, y: 0)
        input.drag(x: 0.5, y: 0.5)
        input.drag(x: 1, y: 1)
        input.release(x: 1, y: 1)
        try input.nudge(dx: 0, dy: 0, click: false)

        XCTAssertEqual(reports.prefix(2).map { $0.1 }, [[0, 0, 0, 0, 0], [1, 0, 0, 0]])
        XCTAssertEqual(reports.suffix(2).map { $0.1 }, [[1, 255, 127, 255, 127], [0, 0, 0, 0]])
        XCTAssertTrue(reports.dropFirst(2).dropLast().allSatisfy { $0.1[0] == 1 })
        XCTAssertTrue(reports.filter { $0.0 == .relativeMouse }.allSatisfy { $0.1.dropFirst() == [0, 0, 0] })
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
            reports.map { $0.1 },
            [
                [0, 0, 0, 0, 0], [1, 0, 0, 0], [0, 0, 0, 0],
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
