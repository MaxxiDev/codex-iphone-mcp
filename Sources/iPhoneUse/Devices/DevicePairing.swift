import Foundation

/// The existing USB-device-ID to Bluetooth-host JSON format. Synchronization and
/// calibration migration belong to DeviceRegistry; this type only reads/writes the file.
struct DevicePairingStore {
    let file: URL

    init(file: URL? = nil) {
        if let file {
            self.file = file
        } else {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("iPhoneUse", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.file = directory.appendingPathComponent("pairings.json")
        }
    }

    /// Nil leaves the caller's current state intact; invalid UUID entries are
    /// discarded individually, as in the original persisted pairing format.
    func load() -> [String: UUID]? {
        guard let data = try? Data(contentsOf: file),
            let saved = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        return saved.compactMapValues(UUID.init(uuidString:))
    }

    func save(_ pairings: [String: UUID]) {
        let encoded = pairings.mapValues(\.uuidString)
        if let data = try? JSONSerialization.data(withJSONObject: encoded, options: [.prettyPrinted]) {
            try? data.write(to: file)
        }
    }
}

/// Scores the two thumbnails captured during a Bluetooth pairing probe. The
/// pointer should change both visited regions, without changing the control regions.
enum PointerScreenMatcher {
    static let width = 90
    static let height = 195
    static let firstPoint = (x: 0.3, y: 0.35)
    static let secondPoint = (x: 0.7, y: 0.65)

    struct ChangeMetrics: Equatable {
        let signal: Int
        let noise: Int
    }

    /// Buffers come from ScreenCaptureSession.thumbnail and contain width * height gray pixels.
    static func score(before: [UInt8], after: [UInt8]) -> Int {
        let metrics = changeMetrics(before: before, after: after)
        return metrics.signal - metrics.noise
    }

    /// Separates changes around the two pointer targets from changes in the
    /// crossed control regions. A zero score alone is not enough to prove a
    /// miss: background activity can cancel a real signal.
    static func changeMetrics(before: [UInt8], after: [UInt8]) -> ChangeMetrics {
        let a = firstPoint
        let b = secondPoint
        let signal = min(changed(before, after, around: a), changed(before, after, around: b))
        let noise = max(changed(before, after, around: (a.x, b.y)), changed(before, after, around: (b.x, a.y)))
        return ChangeMetrics(signal: signal, noise: noise)
    }

    /// Count pixels above the original noise threshold in a 15-by-15 region.
    private static func changed(_ before: [UInt8], _ after: [UInt8], around point: (Double, Double)) -> Int {
        let radius = 7
        let centerX = Int(point.0 * Double(width))
        let centerY = Int(point.1 * Double(height))
        var count = 0
        for y in max(0, centerY - radius)...min(height - 1, centerY + radius) {
            for x in max(0, centerX - radius)...min(width - 1, centerX + radius) {
                let index = y * width + x
                if abs(Int(before[index]) - Int(after[index])) > 12 { count += 1 }
            }
        }
        return count
    }
}

/// Selects a narrowly-scoped recovery when a still-connected saved host's
/// calibration proves that the current USB screen belongs to another phone.
/// The probe result is deliberately required before replacing any saved match.
enum DevicePairingRecovery {
    enum ProbeResult: Equatable {
        case hit
        case miss
        case unavailable
    }

    static func probeResult(for metrics: PointerScreenMatcher.ChangeMetrics) -> ProbeResult {
        let score = metrics.signal - metrics.noise
        if score >= 3 { return .hit }
        // Only a completely unchanged capture is a reliable miss. A zero score
        // with either signal or noise may be a cancelled or partial observation.
        return metrics.signal == 0 && metrics.noise == 0 ? .miss : .unavailable
    }

    struct Candidate: Equatable {
        let screenID: String
        let mappedScreenID: String
        let mappedHost: UUID
        let unmatchedHosts: [UUID]
    }

    static func shouldAttemptRecovery(
        screenID: String, pairings: [String: UUID], mismatchedCalibrationScreenIDs: Set<String>,
        verifiedAbsentScreenPairingIDs: Set<String>
    ) -> Bool {
        // Keep historical absent-screen records after recovery, but do not let
        // them repeatedly block matching once the current screen has a valid
        // pairing. A mismatched current mapping still needs recovery evidence.
        if pairings[screenID] != nil, !mismatchedCalibrationScreenIDs.contains(screenID) {
            return false
        }
        return !mismatchedCalibrationScreenIDs.isEmpty || !verifiedAbsentScreenPairingIDs.isEmpty
    }

    static func candidate(
        screenIDs: [String], pairings: [String: UUID], connectedHosts: [UUID],
        unmatchedHosts: [UUID], mismatchedCalibrationScreenIDs: Set<String>,
        verifiedAbsentScreenPairingIDs: Set<String> = []
    ) -> Candidate? {
        guard screenIDs.count == 1,
            Set(unmatchedHosts).isSubset(of: Set(connectedHosts))
        else { return nil }

        guard let screenID = screenIDs.first else { return nil }
        if pairings[screenID] != nil, !mismatchedCalibrationScreenIDs.contains(screenID) {
            return nil
        }
        let connected = Set(connectedHosts)
        let suspects = pairings.compactMap { mappedScreenID, host -> (String, UUID)? in
            let isWrongCurrentMapping =
                mappedScreenID == screenID
                && mismatchedCalibrationScreenIDs.contains(mappedScreenID)
            let isVerifiedAbsentScreenMapping =
                !screenIDs.contains(mappedScreenID)
                && verifiedAbsentScreenPairingIDs.contains(mappedScreenID)
            guard isWrongCurrentMapping || isVerifiedAbsentScreenMapping, connected.contains(host)
            else { return nil }
            return (mappedScreenID, host)
        }
        guard suspects.count == 1, let (mappedScreenID, mappedHost) = suspects.first,
            pairings.values.filter({ $0 == mappedHost }).count == 1
        else { return nil }

        let savedHosts = Set(pairings.values)
        let candidates = unmatchedHosts.filter { !savedHosts.contains($0) }
        guard !candidates.isEmpty else { return nil }
        return Candidate(
            screenID: screenID, mappedScreenID: mappedScreenID, mappedHost: mappedHost,
            unmatchedHosts: candidates)
    }

    /// Builds the narrowly-scoped candidate used to validate a currently
    /// mapped screen when its saved host has no calibration identity. The
    /// current host is retained as the mapped host; only hosts that are both
    /// connected and absent from every saved pairing may be candidates.
    static func currentMappingCandidate(
        screenIDs: [String], pairings: [String: UUID], connectedHosts: [UUID], unmatchedHosts: [UUID]
    ) -> Candidate? {
        guard screenIDs.count == 1,
            let screenID = screenIDs.first, let mappedHost = pairings[screenID], connectedHosts.contains(mappedHost),
            Set(unmatchedHosts).isSubset(of: Set(connectedHosts)),
            pairings.values.filter({ $0 == mappedHost }).count == 1
        else { return nil }

        let savedHosts = Set(pairings.values)
        let candidates = unmatchedHosts.filter { !savedHosts.contains($0) }
        guard !candidates.isEmpty else { return nil }
        return Candidate(
            screenID: screenID, mappedScreenID: screenID, mappedHost: mappedHost, unmatchedHosts: candidates)
    }

    /// A replacement is safe only when every probe completed, the old host
    /// clearly missed, and exactly one unmatched host clearly hit the screen.
    static func replacement(for candidate: Candidate, probeResults: [UUID: ProbeResult]) -> [String: UUID]? {
        let expectedHosts = Set(candidate.unmatchedHosts).union([candidate.mappedHost])
        guard Set(probeResults.keys) == expectedHosts,
            probeResults[candidate.mappedHost] == .miss,
            let host = uniqueCandidateHit(for: candidate, probeResults: probeResults)
        else { return nil }
        return [candidate.screenID: host]
    }

    /// Returns a candidate only when every unmatched host was probed, exactly
    /// one clearly hit this screen, and the others clearly missed. Recovery
    /// uses this before probing the already-mapped host to avoid moving the
    /// current phone's pointer unless a replacement is plausible.
    static func uniqueCandidateHit(
        for candidate: Candidate, probeResults: [UUID: ProbeResult]
    ) -> UUID? {
        let expectedHosts = Set(candidate.unmatchedHosts)
        guard !expectedHosts.isEmpty, Set(probeResults.keys).isSuperset(of: expectedHosts) else { return nil }
        let results = candidate.unmatchedHosts.compactMap { probeResults[$0] }
        guard results.count == expectedHosts.count, results.allSatisfy({ $0 != .unavailable }) else { return nil }
        let matches = candidate.unmatchedHosts.filter { probeResults[$0] == .hit }
        guard matches.count == 1 else { return nil }
        return matches.first
    }
}
