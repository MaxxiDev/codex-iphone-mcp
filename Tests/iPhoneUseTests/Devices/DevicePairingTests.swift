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

    func testRecoveryTreatsOnlyAnUnchangedCaptureAsAConfirmedMiss() {
        XCTAssertEqual(
            DevicePairingRecovery.probeResult(
                for: PointerScreenMatcher.ChangeMetrics(signal: 0, noise: 0)),
            .miss)
        XCTAssertEqual(
            DevicePairingRecovery.probeResult(
                for: PointerScreenMatcher.ChangeMetrics(signal: 4, noise: 4)),
            .unavailable)
        XCTAssertEqual(
            DevicePairingRecovery.probeResult(
                for: PointerScreenMatcher.ChangeMetrics(signal: 0, noise: 2)),
            .unavailable)
        XCTAssertEqual(
            DevicePairingRecovery.probeResult(
                for: PointerScreenMatcher.ChangeMetrics(signal: 4, noise: 0)),
            .hit)
    }

    func testRecoveryCandidateRequiresVerifiedScreenMismatch() {
        let oldHost = UUID()
        let newHost = UUID()
        let pairings = ["new-usb-id": oldHost]
        let common: (Set<String>) -> DevicePairingRecovery.Candidate? = { mismatches in
            DevicePairingRecovery.candidate(
                screenIDs: ["new-usb-id"], pairings: pairings,
                connectedHosts: [oldHost, newHost], unmatchedHosts: [newHost],
                mismatchedCalibrationScreenIDs: mismatches)
        }

        XCTAssertNil(common([]), "a new host alone must not trigger a rematch")
        XCTAssertNotNil(common(["new-usb-id"]))
    }

    func testRecoveryRejectsAHostSavedForMoreThanOneScreen() {
        let oldHost = UUID()
        let newHost = UUID()
        XCTAssertNil(
            DevicePairingRecovery.candidate(
                screenIDs: ["new-usb-id"],
                pairings: ["new-usb-id": oldHost, "other-usb-id": oldHost],
                connectedHosts: [oldHost, newHost], unmatchedHosts: [newHost],
                mismatchedCalibrationScreenIDs: ["new-usb-id"]))
    }

    func testRecoveryKeepsPairingWhenProbeIsAmbiguousOrOldHostHits() throws {
        let oldHost = UUID()
        let newHost = UUID()
        let candidate = try XCTUnwrap(
            DevicePairingRecovery.candidate(
                screenIDs: ["new-usb-id"], pairings: ["new-usb-id": oldHost],
                connectedHosts: [oldHost, newHost], unmatchedHosts: [newHost],
                mismatchedCalibrationScreenIDs: ["new-usb-id"]))

        XCTAssertNil(
            DevicePairingRecovery.replacement(
                for: candidate, probeResults: [oldHost: .hit, newHost: .hit]))
        XCTAssertNil(
            DevicePairingRecovery.replacement(
                for: candidate, probeResults: [oldHost: .miss, newHost: .unavailable]))
    }

    func testRecoveryReplacesOnlyWhenOldMissesAndOneNewHostHits() throws {
        let oldHost = UUID()
        let newHost = UUID()
        let candidate = try XCTUnwrap(
            DevicePairingRecovery.candidate(
                screenIDs: ["new-usb-id"], pairings: ["new-usb-id": oldHost],
                connectedHosts: [oldHost, newHost], unmatchedHosts: [newHost],
                mismatchedCalibrationScreenIDs: ["new-usb-id"]))

        XCTAssertEqual(
            DevicePairingRecovery.replacement(
                for: candidate, probeResults: [oldHost: .miss, newHost: .hit]),
            ["new-usb-id": newHost])
    }

    func testRecoveryFindsNewUSBIdentityFromVerifiedAbsentScreenMapping() throws {
        let oldHost = UUID()
        let newHost = UUID()
        let candidate = try XCTUnwrap(
            DevicePairingRecovery.candidate(
                screenIDs: ["new-usb-id"], pairings: ["old-usb-id": oldHost],
                connectedHosts: [oldHost, newHost], unmatchedHosts: [newHost],
                mismatchedCalibrationScreenIDs: [], verifiedAbsentScreenPairingIDs: ["old-usb-id"]))

        XCTAssertEqual(candidate.screenID, "new-usb-id")
        XCTAssertEqual(candidate.mappedScreenID, "old-usb-id")
        XCTAssertEqual(candidate.mappedHost, oldHost)
        XCTAssertEqual(
            DevicePairingRecovery.replacement(
                for: candidate, probeResults: [oldHost: .miss, newHost: .hit]),
            ["new-usb-id": newHost])
        // A noisy miss from the old host must not strand the screen: the
        // candidate's direct hit is the stronger piece of evidence.
        XCTAssertEqual(
            DevicePairingRecovery.replacement(
                for: candidate, probeResults: [oldHost: .unavailable, newHost: .hit]),
            ["new-usb-id": newHost])
        XCTAssertNil(
            DevicePairingRecovery.replacement(
                for: candidate, probeResults: [oldHost: .miss, newHost: .unavailable]))
    }

    func testRecoveryRejectsAmbiguousAbsentScreenMappings() {
        let firstOldHost = UUID()
        let secondOldHost = UUID()
        let newHost = UUID()
        XCTAssertNil(
            DevicePairingRecovery.candidate(
                screenIDs: ["new-usb-id"],
                pairings: ["old-usb-a": firstOldHost, "old-usb-b": secondOldHost],
                connectedHosts: [firstOldHost, secondOldHost, newHost], unmatchedHosts: [newHost],
                mismatchedCalibrationScreenIDs: [],
                verifiedAbsentScreenPairingIDs: ["old-usb-a", "old-usb-b"]))
    }

    func testRecoveryDoesNotBlockAValidCurrentMappingBecauseOfHistoricalPairings() {
        let currentHost = UUID()
        let oldHost = UUID()
        let pairings = ["new-usb-id": currentHost, "old-usb-id": oldHost]

        XCTAssertFalse(
            DevicePairingRecovery.shouldAttemptRecovery(
                screenID: "new-usb-id", pairings: pairings,
                mismatchedCalibrationScreenIDs: [], verifiedAbsentScreenPairingIDs: ["old-usb-id"]))
        XCTAssertTrue(
            DevicePairingRecovery.shouldAttemptRecovery(
                screenID: "new-usb-id", pairings: pairings,
                mismatchedCalibrationScreenIDs: ["new-usb-id"], verifiedAbsentScreenPairingIDs: []))
        XCTAssertTrue(
            DevicePairingRecovery.shouldAttemptRecovery(
                screenID: "new-usb-id", pairings: [:],
                mismatchedCalibrationScreenIDs: [], verifiedAbsentScreenPairingIDs: ["old-usb-id"]))
    }

    func testRecoveryCanValidateACurrentMappingWithoutAStoredScreenIdentity() throws {
        let oldHost = UUID()
        let newHost = UUID()
        let candidate = try XCTUnwrap(
            DevicePairingRecovery.currentMappingCandidate(
                screenIDs: ["new-usb-id"], pairings: ["new-usb-id": oldHost],
                connectedHosts: [oldHost, newHost], unmatchedHosts: [newHost]))

        XCTAssertEqual(candidate.mappedHost, oldHost)
        XCTAssertEqual(candidate.unmatchedHosts, [newHost])
        XCTAssertEqual(
            DevicePairingRecovery.uniqueCandidateHit(
                for: candidate, probeResults: [newHost: .hit]),
            newHost)
        XCTAssertNil(
            DevicePairingRecovery.uniqueCandidateHit(
                for: candidate, probeResults: [newHost: .unavailable]))
        XCTAssertEqual(
            DevicePairingRecovery.replacement(
                for: candidate, probeResults: [newHost: .hit, oldHost: .miss]),
            ["new-usb-id": newHost])
    }

    func testRecoveryDoesNotUseAHostWithAnotherSavedMappingAsCandidate() {
        let currentHost = UUID()
        let savedHost = UUID()
        XCTAssertNil(
            DevicePairingRecovery.currentMappingCandidate(
                screenIDs: ["new-usb-id"],
                pairings: ["new-usb-id": currentHost, "other-usb-id": savedHost],
                connectedHosts: [currentHost, savedHost], unmatchedHosts: [savedHost]))
    }

    func testSingleHostShortcutKeepsAScreenSavedToADisconnectedHost() {
        let owner = UUID()
        let otherHost = UUID()
        // A brand-new screen, or a reconfirmation of the same host, may skip probing.
        XCTAssertTrue(
            DevicePairingRecovery.singleHostShortcutAllowed(
                screenID: "usb-a", pairings: [:], host: otherHost))
        XCTAssertTrue(
            DevicePairingRecovery.singleHostShortcutAllowed(
                screenID: "usb-a", pairings: ["usb-a": otherHost], host: otherHost))
        // The screen belongs to a (currently disconnected) owner: a device swap
        // that leaves only one other host connected must not steal it blindly.
        XCTAssertFalse(
            DevicePairingRecovery.singleHostShortcutAllowed(
                screenID: "usb-a", pairings: ["usb-a": owner], host: otherHost))
    }

    func testVerifiedOwnerClaimRepairsACrossedPairing() {
        let screen = "usb-a"
        let trueOwner = UUID()
        let wrongHost = UUID()
        let unverified = UUID()
        let isVerifiedOwner: (UUID, String) -> Bool = { host, id in host == trueOwner && id == screen }

        // The crossed state: the screen is paired to the wrong connected host
        // while its verified owner is connected but unmatched.
        let candidate = DevicePairingRecovery.verifiedOwnerClaim(
            screenIDs: [screen], pairings: [screen: wrongHost],
            connectedHosts: [wrongHost, trueOwner], isVerifiedOwner: isVerifiedOwner)
        XCTAssertEqual(candidate?.mappedHost, wrongHost)
        XCTAssertEqual(candidate?.unmatchedHosts, [trueOwner])
        XCTAssertEqual(
            DevicePairingRecovery.replacement(
                for: candidate!, probeResults: [trueOwner: .hit, wrongHost: .miss]),
            [screen: trueOwner])

        // No claim without verified ownership, with a disconnected owner, or
        // while the claimant is already paired to another screen.
        XCTAssertNil(
            DevicePairingRecovery.verifiedOwnerClaim(
                screenIDs: [screen], pairings: [screen: wrongHost],
                connectedHosts: [wrongHost, unverified], isVerifiedOwner: isVerifiedOwner))
        XCTAssertNil(
            DevicePairingRecovery.verifiedOwnerClaim(
                screenIDs: [screen], pairings: [screen: wrongHost],
                connectedHosts: [wrongHost], isVerifiedOwner: isVerifiedOwner))
        XCTAssertNil(
            DevicePairingRecovery.verifiedOwnerClaim(
                screenIDs: [screen], pairings: [screen: wrongHost, "usb-b": trueOwner],
                connectedHosts: [wrongHost, trueOwner], isVerifiedOwner: isVerifiedOwner))
        // Two simultaneous claims stay ambiguous and are left to explicit repair.
        XCTAssertNil(
            DevicePairingRecovery.verifiedOwnerClaim(
                screenIDs: [screen, "usb-b"], pairings: [screen: wrongHost],
                connectedHosts: [wrongHost, trueOwner], isVerifiedOwner: isVerifiedOwner))
    }

    private func blankThumbnail() -> [UInt8] {
        [UInt8](repeating: 0, count: PointerScreenMatcher.width * PointerScreenMatcher.height)
    }

    private func mark(_ pixels: inout [UInt8], x: Int, y: Int, value: UInt8) {
        pixels[y * PointerScreenMatcher.width + x] = value
    }
}
