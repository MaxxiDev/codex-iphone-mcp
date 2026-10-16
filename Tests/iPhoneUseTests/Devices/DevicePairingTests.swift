import XCTest

@testable import iPhoneUse

final class DevicePairingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testPairingFileRemainsAnUnwrappedDeviceToUUIDDictionary() throws {
        let store = DevicePairingStore(file: directory.appendingPathComponent("pairings.json"))
        let host = UUID()
        store.save(["usb-phone": host])
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.file)) as? [String: String]
        XCTAssertEqual(json, ["usb-phone": host.uuidString])
        XCTAssertEqual(store.load(), ["usb-phone": host])
    }

    func testPairingLoadDropsOnlyMalformedUUIDs() throws {
        let store = DevicePairingStore(file: directory.appendingPathComponent("pairings.json"))
        let host = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "valid": host.uuidString.lowercased(), "invalid": "bad-uuid",
        ])
        try data.write(to: store.file)
        XCTAssertEqual(store.load(), ["valid": host])
    }

    func testMissingOrInvalidFileDoesNotReplaceCurrentPairings() throws {
        let store = DevicePairingStore(file: directory.appendingPathComponent("pairings.json"))
        XCTAssertNil(store.load())
        try Data("not json".utf8).write(to: store.file)
        XCTAssertNil(store.load())
        try Data("{\"phone\":123}".utf8).write(to: store.file)
        XCTAssertNil(store.load())
    }

    func testProbeRequiresChangesAtBothPointerPositions() {
        let before = blankThumbnail()
        var after = before
        mark(&after, x: 27, y: 68, value: 13)
        XCTAssertEqual(PointerScreenMatcher.score(before: before, after: after), 0)
        mark(&after, x: 62, y: 126, value: 13)
        XCTAssertEqual(PointerScreenMatcher.score(before: before, after: after), 1)
    }

    func testProbeSubtractsBackgroundChangesAndIgnoresSmallDifferences() {
        let before = blankThumbnail()
        var after = before
        mark(&after, x: 27, y: 68, value: 12)
        mark(&after, x: 62, y: 126, value: 12)
        XCTAssertEqual(PointerScreenMatcher.score(before: before, after: after), 0)
        mark(&after, x: 27, y: 68, value: 40)
        mark(&after, x: 62, y: 126, value: 40)
        mark(&after, x: 27, y: 126, value: 40)
        XCTAssertEqual(PointerScreenMatcher.score(before: before, after: after), 0)
    }

    func testUniformScreenChangeCannotBeMistakenForPointerMovement() {
        let before = blankThumbnail()
        let after = [UInt8](repeating: 255, count: before.count)
        XCTAssertEqual(PointerScreenMatcher.score(before: before, after: after), 0)
    }

    private func blankThumbnail() -> [UInt8] {
        [UInt8](repeating: 0, count: PointerScreenMatcher.width * PointerScreenMatcher.height)
    }

    private func mark(_ pixels: inout [UInt8], x: Int, y: Int, value: UInt8) {
        pixels[y * PointerScreenMatcher.width + x] = value
    }
}
