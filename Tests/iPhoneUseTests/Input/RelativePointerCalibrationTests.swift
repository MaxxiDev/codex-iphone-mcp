import XCTest

@testable import iPhoneUse

final class RelativePointerCalibrationTests: XCTestCase {
    private func profile(_ distances: [Double] = [0, 1, 3, 8, 20]) -> RelativePointerCalibration {
        RelativePointerCalibration(
            host: UUID(), screenWidth: 100, screenHeight: 200,
            reportInterval: 0.01, distances: distances)
    }

    func testPlansBothAxesAndPreservesPredictedLandingAcrossMoves() throws {
        let calibration = profile()
        try calibration.validate()
        let first = calibration.plan(from: .zero, to: CGPoint(x: 42.4, y: 69.7))
        XCTAssertEqual(first.position, CGPoint(x: 42, y: 70))
        XCTAssertTrue(first.reports.allSatisfy { ($0.dx == 0) != ($0.dy == 0) })
        let repeated = calibration.plan(from: first.position, to: CGPoint(x: 42.4, y: 69.7))
        XCTAssertTrue(repeated.reports.isEmpty)
        XCTAssertEqual(repeated.position, first.position)
        let back = calibration.plan(from: first.position, to: .zero)
        XCTAssertEqual(back.position, .zero)
        XCTAssertTrue(back.reports.allSatisfy { $0.dx <= 0 && $0.dy <= 0 })
    }

    func testClampsTargetsToPhysicalScreenAndHomesPastBothEdges() {
        let calibration = profile()
        let result = calibration.plan(from: .zero, to: CGPoint(x: 1000, y: -100))
        XCTAssertEqual(result.position, CGPoint(x: 99, y: 0))
        XCTAssertEqual(calibration.homingReports.filter { $0.dx < 0 }.count, 7)
        XCTAssertEqual(calibration.homingReports.filter { $0.dy < 0 }.count, 12)
        XCTAssertFalse(calibration.matches(CGSize(width: 200, height: 100)))
    }

    func testTrackingConvergesWithoutReversingAndInterleavesAxes() {
        let calibration = profile()
        for target in [
            CGPoint(x: 91.7, y: 180.2), CGPoint(x: 1.2, y: 2.6),
            CGPoint(x: 91.7, y: 2.6), CGPoint(x: 1.2, y: 180.2),
        ] {
            let start = CGPoint(x: 50, y: 100)
            var position = start
            var previous: RelativePointerCalibration.Movement?
            var reports: [RelativePointerCalibration.Movement] = []
            for _ in 0..<1000 {
                guard let step = calibration.trackingStep(from: position, to: target, after: previous) else { break }
                XCTAssertGreaterThanOrEqual(Double(step.report.dx) * (target.x - start.x), 0)
                XCTAssertGreaterThanOrEqual(Double(step.report.dy) * (target.y - start.y), 0)
                XCTAssertTrue((step.report.dx == 0) != (step.report.dy == 0))
                position = step.position
                previous = step.report
                reports.append(step.report)
            }
            XCTAssertLessThan(reports.count, 1000, "tracking did not converge")
            XCTAssertEqual(position.x, target.x, accuracy: calibration.distances[1] / 2)
            XCTAssertEqual(position.y, target.y, accuracy: calibration.distances[1] / 2)
            XCTAssertTrue(reports.prefix(2).contains { $0.dx != 0 })
            XCTAssertTrue(reports.prefix(2).contains { $0.dy != 0 })
            XCTAssertNil(calibration.trackingStep(from: position, to: target, after: previous))
        }
    }

    func testTrackingFinishesFineAxisAndClampsScreenEdges() {
        let calibration = profile()
        for target in [CGPoint(x: 0.7, y: 190), CGPoint(x: 1000, y: -100)] {
            var position = CGPoint.zero
            var previous: RelativePointerCalibration.Movement?
            for _ in 0..<1000 {
                guard let step = calibration.trackingStep(from: position, to: target, after: previous) else { break }
                position = step.position
                previous = step.report
                XCTAssertTrue((0...99).contains(position.x))
                XCTAssertTrue((0...199).contains(position.y))
            }
            XCTAssertEqual(position.x, max(0, min(99, target.x)), accuracy: 0.5)
            XCTAssertEqual(position.y, max(0, min(199, target.y)), accuracy: 0.5)
            XCTAssertNil(calibration.trackingStep(from: position, to: target, after: previous))
        }
    }

    func testRejectsUnusableOrUnboundedCalibration() throws {
        for values in [[Double](), [0], [0, 0], [0, 2, 1], [0, .infinity], [0, 0.000001]] {
            XCTAssertThrowsError(try profile(values).validate())
        }
        let valid = profile()
        let decoded = try JSONDecoder().decode(RelativePointerCalibration.self, from: JSONEncoder().encode(valid))
        try decoded.validate()
        XCTAssertEqual(decoded.distances, valid.distances)
    }

    func testAPITapAfterWindowMoveUsesSharedPositionAndOnlyRelativeChannel() throws {
        let calibration = profile()
        var reports: [[UInt8]] = []
        let input = DeviceInput(
            host: calibration.host, session: UUID(), calibration: calibration,
            reportSender: { id, bytes in
                XCTAssertEqual(id, .relativeMouse)
                reports.append(bytes)
            })
        input.positionPointer(x: 0.8, y: 0.8)
        try input.tap(x: 0.5, y: 0.5, hold: 0)
        // Simulate a screen with the exact calibration curve, including clipping.
        var position = CGPoint(x: 80, y: 70)
        var click: CGPoint?
        for bytes in reports {
            let dx = Int(Int8(bitPattern: bytes[1]))
            let dy = Int(Int8(bitPattern: bytes[2]))
            position.x = max(0, min(99, position.x + (dx < 0 ? -1 : 1) * calibration.distances[abs(dx)]))
            position.y = max(0, min(199, position.y + (dy < 0 ? -1 : 1) * calibration.distances[abs(dy)]))
            if bytes[0] == 1 { click = position }
        }
        XCTAssertEqual(click, CGPoint(x: 50, y: 100))
        XCTAssertEqual(reports.last, [0, 0, 0, 0])
    }

    func testMismatchedCalibrationDoesNotClickButAllowsRawCalibrationMovement() throws {
        var reports = 0
        let input = DeviceInput(
            host: UUID(), session: UUID(), calibrationRequired: true,
            reportSender: { _, _ in reports += 1 })
        XCTAssertThrowsError(try input.tap(x: 0.5, y: 0.5))
        XCTAssertEqual(reports, 0)
        try input.nudge(dx: 1, dy: 0, click: false)
        XCTAssertEqual(reports, 1)
    }

    func testCaptureFirstFrameEnablesCalibrationAndRotationDisablesIt() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = profile()
        try save(saved, in: directory)
        let calibration = try XCTUnwrap(
            RelativePointerCalibration.load(
                host: saved.host, screenSize: nil, directory: directory))
        var size: CGSize?
        var reports = 0
        let input = DeviceInput(
            host: calibration.host, session: UUID(), calibration: calibration,
            calibrationRequired: true, screenSize: { size },
            reportSender: { id, _ in
                XCTAssertEqual(id, .relativeMouse)
                reports += 1
            })
        XCTAssertThrowsError(try input.move(x: 0.5, y: 0.5))
        XCTAssertThrowsError(try input.tap(x: 0.5, y: 0.5))
        XCTAssertEqual(reports, 0)
        size = CGSize(width: 100, height: 200)
        try input.move(x: 0.5, y: 0.5)
        let sent = reports
        XCTAssertGreaterThan(sent, 0)
        size = CGSize(width: 200, height: 100)
        XCTAssertThrowsError(try input.tap(x: 0.5, y: 0.5))
        XCTAssertEqual(reports, sent)
        size = CGSize(width: 100, height: 200)
        try input.move(x: 0.5, y: 0.5)
        XCTAssertGreaterThan(reports, sent)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func save(_ calibration: RelativePointerCalibration, in directory: URL, named host: UUID? = nil) throws {
        try JSONEncoder().encode(calibration).write(
            to: directory.appendingPathComponent((host ?? calibration.host).uuidString + ".json"))
    }

    func testLegacyProfileBindsOnlyItsConfirmedHostAndPersistsScreenIdentity() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calibration = profile()
        try save(calibration, in: directory)
        let size = CGSize(width: 100, height: 200)
        let original = try XCTUnwrap(
            RelativePointerCalibration.load(
                host: calibration.host, screenSize: size, directory: directory))
        XCTAssertNil(original.screenID)
        XCTAssertNil(
            RelativePointerCalibration.loadMatchingScreen(
                host: UUID(), screenSize: size, screenID: "phone-a", directory: directory))

        let bound = try XCTUnwrap(
            RelativePointerCalibration.load(
                host: calibration.host, screenSize: size, screenID: "phone-a", directory: directory))
        XCTAssertEqual(bound.screenID, "phone-a")
        let persisted = try XCTUnwrap(
            RelativePointerCalibration.load(
                host: calibration.host, screenSize: size, directory: directory))
        XCTAssertEqual(persisted.screenID, "phone-a")
        XCTAssertNil(
            RelativePointerCalibration.load(
                host: calibration.host, screenSize: size, screenID: "phone-b", directory: directory))
        let unknownHost = UUID()
        try save(calibration, in: directory, named: unknownHost)
        XCTAssertNil(
            RelativePointerCalibration.load(
                host: unknownHost, screenSize: size, screenID: "phone-a", directory: directory))
    }

    func testRepairedHostRequiresExactScreenIdentityInsteadOfResolution() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let newHost = UUID()
        let legacy = profile()
        try save(legacy, in: directory)
        let otherPhone = RelativePointerCalibration(
            host: UUID(), screenWidth: 100, screenHeight: 200,
            reportInterval: 0.01, distances: [0, 1, 4, 9, 22], screenID: "phone-b")
        try save(otherPhone, in: directory)
        XCTAssertNil(
            RelativePointerCalibration.loadMatchingScreen(
                host: newHost, screenSize: CGSize(width: 100, height: 200), screenID: "phone-a", directory: directory))
        let calibration = RelativePointerCalibration(
            host: UUID(), screenWidth: 100, screenHeight: 200,
            reportInterval: 0.01, distances: [0, 1, 3, 8, 20], screenID: "phone-a")
        try save(calibration, in: directory)
        let rebound = try XCTUnwrap(
            RelativePointerCalibration.loadMatchingScreen(
                host: newHost, screenSize: CGSize(width: 100, height: 200), screenID: "phone-a", directory: directory))
        try rebound.validate()
        XCTAssertEqual(rebound.host, newHost)
        XCTAssertEqual(rebound.screenID, "phone-a")
        XCTAssertEqual(rebound.distances, calibration.distances)
        let reboundWithoutFrame = try XCTUnwrap(
            RelativePointerCalibration.loadMatchingScreen(
                host: newHost, screenSize: nil, screenID: "phone-a", directory: directory))
        XCTAssertEqual(reboundWithoutFrame.host, newHost)
        XCTAssertEqual(reboundWithoutFrame.screenID, "phone-a")
        let reboundAfterRotation = try XCTUnwrap(
            RelativePointerCalibration.loadMatchingScreen(
                host: newHost, screenSize: CGSize(width: 200, height: 100), screenID: "phone-a", directory: directory))
        XCTAssertEqual(reboundAfterRotation.host, newHost)
        XCTAssertEqual(reboundAfterRotation.screenID, "phone-a")
        XCTAssertEqual(reboundAfterRotation.distances, calibration.distances)
        XCTAssertNil(
            RelativePointerCalibration.loadMatchingScreen(
                host: newHost, screenSize: CGSize(width: 100, height: 200), directory: directory))

        var size: CGSize? = CGSize(width: 200, height: 100)
        var reports = 0
        let input = DeviceInput(
            host: newHost, session: UUID(), calibration: reboundAfterRotation,
            calibrationRequired: true, screenSize: { size },
            reportSender: { id, _ in
                XCTAssertEqual(id, .relativeMouse)
                reports += 1
            })
        XCTAssertThrowsError(try input.move(x: 0.5, y: 0.5))
        XCTAssertThrowsError(try input.tap(x: 0.5, y: 0.5))
        XCTAssertEqual(reports, 0)
        size = CGSize(width: 100, height: 200)
        XCTAssertNoThrow(try input.move(x: 0.5, y: 0.5))
        let sent = reports
        size = CGSize(width: 200, height: 100)
        XCTAssertThrowsError(try input.tap(x: 0.5, y: 0.5))
        XCTAssertEqual(reports, sent)
        size = CGSize(width: 100, height: 200)
        XCTAssertNoThrow(try input.move(x: 0.5, y: 0.5))
        XCTAssertGreaterThan(reports, sent)
    }

    func testMigrationUpdatesHostAndScreenIdentityOnDisk() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calibration = profile()
        try save(calibration, in: directory)
        let newHost = UUID()
        let migrated = try XCTUnwrap(
            RelativePointerCalibration.rebind(
                from: calibration.host, to: newHost, screenID: "phone-a", directory: directory))
        XCTAssertEqual(migrated.host, newHost)
        XCTAssertEqual(migrated.screenID, "phone-a")
        let persisted = try XCTUnwrap(
            RelativePointerCalibration.load(
                host: newHost, screenSize: CGSize(width: 100, height: 200), screenID: "phone-a", directory: directory))
        XCTAssertEqual(persisted.host, newHost)
        XCTAssertEqual(persisted.screenID, "phone-a")
        XCTAssertEqual(persisted.distances, calibration.distances)
        XCTAssertThrowsError(
            try RelativePointerCalibration.rebind(
                from: newHost, to: UUID(), screenID: "phone-b", directory: directory))
    }

    func testInvalidOrMisnamedMigrationCannotCreateANewProfile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalid = RelativePointerCalibration(
            host: UUID(), screenWidth: 100, screenHeight: 200,
            reportInterval: 0.01, distances: [0, 0], screenID: "phone-a")
        try save(invalid, in: directory)
        let newHost = UUID()
        XCTAssertThrowsError(
            try RelativePointerCalibration.rebind(
                from: invalid.host, to: newHost, screenID: "phone-a", directory: directory))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(newHost.uuidString + ".json").path))
        let wrongHost = UUID()
        try save(profile(), in: directory, named: wrongHost)
        XCTAssertThrowsError(
            try RelativePointerCalibration.rebind(
                from: wrongHost, to: newHost, screenID: "phone-a", directory: directory))
        XCTAssertNil(
            try RelativePointerCalibration.rebind(
                from: UUID(), to: newHost, screenID: "phone-a", directory: directory))
    }

    func testInvalidBoundProfileStillRequiresCalibration() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID()
        XCTAssertFalse(
            RelativePointerCalibration.requiresCalibration(host: host, screenID: "phone-a", directory: directory))
        let invalid = directory.appendingPathComponent(UUID().uuidString + ".json")
        try Data("{\"screenID\":\"phone-a\",\"distances\":[0,0]}".utf8).write(to: invalid)
        XCTAssertTrue(
            RelativePointerCalibration.requiresCalibration(host: host, screenID: "phone-a", directory: directory))
        XCTAssertFalse(
            RelativePointerCalibration.requiresCalibration(host: host, screenID: "phone-b", directory: directory))
        XCTAssertFalse(RelativePointerCalibration.requiresCalibration(host: host, screenID: nil, directory: directory))
        try Data("broken".utf8).write(to: directory.appendingPathComponent(host.uuidString + ".json"))
        XCTAssertTrue(RelativePointerCalibration.requiresCalibration(host: host, screenID: nil, directory: directory))
    }
}
