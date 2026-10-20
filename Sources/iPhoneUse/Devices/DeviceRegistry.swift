import Foundation

/// A phone: its USB screen, and the Bluetooth host that drives it once matched and connected.
struct Device {
    let screen: ScreenCaptureSession
    let host: UUID?

    var id: String { screen.id }

    var json: [String: Any] {
        var info: [String: Any] = ["id": id, "name": screen.name, "bluetooth": host != nil]
        if let size = screen.size {
            info["width"] = Int(size.width)
            info["height"] = Int(size.height)
        }
        return info
    }
}

struct DeviceError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Matches each phone's Bluetooth connection to its USB screen. Bluetooth does not say which
/// phone is which, so matching moves the pointer through one connection and looks for the
/// screen where it moved. Matches are saved, so a phone is matched once.
final class DeviceRegistry {
    static let shared = DeviceRegistry()

    private let lock = NSLock()
    // DeviceInput creation may wait for the Bluetooth queue. Keep it separate from
    // matching state, which Bluetooth callbacks access on that queue.
    private let inputLock = NSLock()
    private var pairings: [String: UUID] = [:]
    /// Cache identity includes both the BLE session and USB device. Keeping the
    /// entry together prevents an DeviceInput from being reused for another screen.
    private struct CachedInput {
        let input: DeviceInput
        let screenID: String?
    }
    private enum ReplacementRecovery {
        case notApplicable
        case blocked
        case recovered([String: UUID])
    }
    private var inputs: [UUID: CachedInput] = [:]
    private var matchPending = false
    private let matchQueue = DispatchQueue(label: "iphone-use.match")

    private let pairingStore = DevicePairingStore()

    func start() {
        load()
        ScreenCaptureManager.shared.onScreensChanged = { [weak self] in self?.scheduleMatch() }
        HIDPeripheral.shared.onHostsChanged = { [weak self] in self?.scheduleMatch() }
    }

    func all() -> [Device] {
        let hosts = Set(HIDPeripheral.shared.connectedHosts)
        let pairings = lock.withLock { self.pairings }
        return ScreenCaptureManager.shared.all.map { screen in
            Device(screen: screen, host: pairings[screen.id].flatMap { hosts.contains($0) ? $0 : nil })
        }
    }

    /// Device details plus the active pointer mode. Keeping this in the status
    /// endpoint makes it possible to verify which input path the running process
    /// actually loaded, instead of inferring it from a calibration file on disk.
    func status() -> [[String: Any]] {
        all().map { device in
            var info = device.json
            if let host = device.host {
                var pointer =
                    (try? input(for: device))?.pointerStatus
                    ?? ["state": "unavailable"]
                pointer["host"] = host.uuidString
                info["pointer"] = pointer
            } else {
                info["pointer"] = ["state": "unpaired"]
            }
            return info
        }
    }

    /// Connected Bluetooth hosts that no present screen is matched to.
    func unmatchedHosts() -> [UUID] {
        let matched = Set(all().compactMap(\.host))
        return HIDPeripheral.shared.connectedHosts.filter { !matched.contains($0) }
    }

    /// A phone by id, name or id prefix. Without a query there must be exactly one phone.
    func find(_ query: String?) throws -> Device {
        let devices = all()
        if let query, !query.isEmpty {
            let q = query.lowercased()
            let hit =
                devices.first { $0.id.lowercased() == q } ?? devices.first { $0.screen.name.lowercased() == q }
                ?? devices.first { $0.id.lowercased().hasPrefix(q) }
            guard let hit else { throw DeviceError("no phone matches \"\(query)\". \(Self.describe(devices))") }
            return hit
        }
        guard !devices.isEmpty else {
            throw DeviceError("no iPhone screen: plug the iPhone in over USB and unlock it")
        }
        guard devices.count == 1 else {
            throw DeviceError("\(devices.count) phones are connected, pass device. \(Self.describe(devices))")
        }
        return devices[0]
    }

    /// The phone's input, matching its Bluetooth connection first when needed.
    func input(for device: Device) throws -> DeviceInput {
        if let host = device.host { return input(for: host, screen: device.screen) }
        match()
        let matched = try find(device.id)
        if let host = matched.host { return input(for: host, screen: matched.screen) }
        if unmatchedHosts().isEmpty {
            throw DeviceError(
                "\(device.screen.name) has no Bluetooth connection: enable AssistiveTouch, then pair \"\(HIDPeripheral.shared.localName)\" in Settings > Accessibility > Touch > AssistiveTouch > Devices > Bluetooth Devices"
            )
        }
        throw DeviceError(
            "could not tell which Bluetooth connection is \(device.screen.name): unlock it, check AssistiveTouch is on, then POST /match"
        )
    }

    func input(for host: UUID, screen: ScreenCaptureSession? = nil) -> DeviceInput {
        return inputLock.withLock {
            // Serialize the session snapshot with cache access so a delayed old
            // session cannot replace a newer DeviceInput and split the input queues.
            let session = HIDPeripheral.shared.connectionSession(for: host)
            let screenID = screen?.id
            if let cached = inputs[host], cached.input.session == session, cached.screenID == screenID {
                return cached.input
            }
            let input = makeInput(host: host, session: session, screen: screen)
            inputs[host] = CachedInput(input: input, screenID: screenID)
            return input
        }
    }

    /// Returns a cached input for a still-current Bluetooth session without
    /// changing the screen identity associated with the normal input cache.
    /// Recovery uses this only for its isolated probe: an absent USB screen
    /// must not cause an old input queue to be rebound to the newly discovered
    /// screen before the probe proves the replacement.
    private func cachedInput(for host: UUID, session: UUID) -> DeviceInput? {
        inputLock.withLock {
            guard let cached = inputs[host], cached.input.session == session else { return nil }
            return cached.input
        }
    }

    /// Called while inputLock is held. Resolve calibration and the live screen
    /// provider once for each cached session/screen pair.
    private func makeInput(host: UUID, session: UUID?, screen: ScreenCaptureSession?) -> DeviceInput {
        let screenID = screen?.id
        let calibration =
            RelativePointerCalibration.load(
                host: host, screenSize: screen?.size, screenID: screenID)
            ?? RelativePointerCalibration.loadMatchingScreen(
                host: host, screenSize: screen?.size, screenID: screenID)
        let input = DeviceInput(
            host: host, session: session, calibration: calibration,
            calibrationRequired: RelativePointerCalibration.requiresCalibration(
                host: host, screenID: screenID),
            calibrationFilePresent: FileManager.default.fileExists(
                atPath: RelativePointerCalibration.fileURL(host: host).path),
            screenSize: screenID.map { id in
                // USB reconnect creates a new ScreenCaptureSession while the
                // Bluetooth session may remain unchanged.
                { ScreenCaptureManager.shared.all.first { $0.id == id }?.size }
            })
        return input
    }

    func pair(_ device: Device, host: UUID) {
        store([device.id: host])
    }

    /// Matches unmatched hosts to unmatched screens and waits for the result.
    /// `force` rematches every screen present; a screen nothing is found for keeps its match.
    /// `probe` checks the pointer even with one phone, where the match is otherwise assumed.
    @discardableResult
    func match(force: Bool = false, probe: Bool = false) -> [String: UUID] {
        matchQueue.sync { runMatch(force: force, alwaysProbe: probe) }
    }

    // MARK: Matching

    private func scheduleMatch() {
        let alreadyPending = lock.withLock {
            defer { matchPending = true }
            return matchPending
        }
        guard !alreadyPending else { return }
        matchQueue.asyncAfter(deadline: .now() + 1.5) {
            self.lock.withLock { self.matchPending = false }
            self.runMatch(force: false, alwaysProbe: false)
        }
    }

    @discardableResult
    private func runMatch(force: Bool, alwaysProbe: Bool) -> [String: UUID] {
        let screens = ScreenCaptureManager.shared.all
        let hosts = HIDPeripheral.shared.connectedHosts
        let savedPairings = lock.withLock { self.pairings }
        var pairings = savedPairings
        if force { for screen in screens { pairings[screen.id] = nil } }

        if !force {
            switch recoverReplacedUSBDevice(screens: screens, hosts: hosts, pairings: pairings) {
            case .recovered(let recovered):
                guard
                    store(
                        recovered, migrateCalibrationProfiles: false, expectingPairings: pairings
                    )
                else { return [:] }
                for (id, host) in recovered {
                    log(
                        "recovered USB replacement \(screens.first { $0.id == id }?.name ?? id) with bluetooth host \(host)"
                    )
                }
                return recovered
            case .blocked:
                // Do not let generic matching bypass recovery's evidence checks.
                return [:]
            case .notApplicable:
                break
            }
        }

        let matchedHosts = Set(screens.compactMap { pairings[$0.id] }.filter(hosts.contains))
        var freeScreens = screens.filter { pairings[$0.id].map { !hosts.contains($0) } ?? true }
        let freeHosts = hosts.filter { !matchedHosts.contains($0) }
        guard !freeScreens.isEmpty, !freeHosts.isEmpty else { return [:] }

        var found: [String: UUID] = [:]
        let hasConflictingIdentity = hosts.contains { host in
            RelativePointerCalibration.isBoundToDifferentScreen(host: host, screenID: screens.first?.id ?? "")
                || savedPairings.contains { $0.value == host && $0.key != screens.first?.id }
        }
        if screens.count == 1, hosts.count == 1, !alwaysProbe, !hasConflictingIdentity {
            found[screens[0].id] = hosts[0]
        } else {
            for host in freeHosts where !freeScreens.isEmpty {
                guard let screen = probe(host, among: freeScreens) else { continue }
                found[screen.id] = host
                freeScreens.removeAll { $0.id == screen.id }
            }
        }
        store(found)
        for (id, host) in found {
            log("matched \(screens.first { $0.id == id }?.name ?? id) to bluetooth host \(host)")
        }
        return found
    }

    /// USB reconnects can expose a new capture identity while CoreBluetooth
    /// keeps the old host online. A verified calibration profile is the only
    /// persisted evidence we use to identify that stale pairing. Probe both
    /// hosts before replacing it; uncertain or failed probes leave the saved
    /// pairing untouched for an explicit `/match` retry.
    private func recoverReplacedUSBDevice(
        screens: [ScreenCaptureSession], hosts: [UUID], pairings: [String: UUID]
    ) -> ReplacementRecovery {
        // Keep recovery intentionally narrow until multi-screen evidence can be
        // scored as a complete one-to-one matrix.
        guard screens.count == 1, let screen = screens.first else { return .notApplicable }
        let screenIDs = Set(screens.map(\.id))
        let matchedHosts = Set(screens.compactMap { pairings[$0.id] }.filter(hosts.contains))
        let freeHosts = hosts.filter { !matchedHosts.contains($0) }
        let mismatchedIDs = Set(
            screens.compactMap { screen -> String? in
                guard let host = pairings[screen.id], hosts.contains(host),
                    RelativePointerCalibration.isBoundToDifferentScreen(host: host, screenID: screen.id)
                else { return nil }
                return screen.id
            })
        let verifiedAbsentIDs = Set(
            pairings.compactMap { id, host -> String? in
                guard !screenIDs.contains(id), hosts.contains(host),
                    RelativePointerCalibration.isBoundToScreen(host: host, screenID: id)
                else { return nil }
                return id
            })

        // Older versions could save a replacement USB identity against the
        // still-connected old host before it had any calibration identity.
        // In that case, first test only truly unmapped hosts. Probe the current
        // mapping only after exactly one candidate clearly affects this screen.
        if mismatchedIDs.isEmpty,
            let mappedHost = pairings[screen.id], hosts.contains(mappedHost),
            RelativePointerCalibration.boundScreenID(host: mappedHost) == nil,
            let candidate = DevicePairingRecovery.currentMappingCandidate(
                screenIDs: screens.map(\.id), pairings: pairings,
                connectedHosts: hosts, unmatchedHosts: freeHosts)
        {
            return verifyUnidentifiedCurrentMapping(
                candidate, screen: screen, screens: screens, hosts: hosts, pairings: pairings)
        }

        guard
            DevicePairingRecovery.shouldAttemptRecovery(
                screenID: screen.id, pairings: pairings,
                mismatchedCalibrationScreenIDs: mismatchedIDs,
                verifiedAbsentScreenPairingIDs: verifiedAbsentIDs)
        else { return .notApplicable }
        guard
            let candidate = DevicePairingRecovery.candidate(
                screenIDs: screens.map(\.id), pairings: pairings, connectedHosts: hosts,
                unmatchedHosts: freeHosts, mismatchedCalibrationScreenIDs: mismatchedIDs,
                verifiedAbsentScreenPairingIDs: verifiedAbsentIDs),
            candidate.screenID == screen.id
        else { return .blocked }

        guard
            let mappedCalibration = RelativePointerCalibration.load(
                host: candidate.mappedHost, screenSize: nil),
            let mappedProfileScreenID = RelativePointerCalibration.boundScreenID(host: candidate.mappedHost),
            candidate.mappedScreenID == screen.id
                ? mappedProfileScreenID != screen.id
                : mappedProfileScreenID == candidate.mappedScreenID
        else { return .blocked }

        let sessions = Dictionary(
            uniqueKeysWithValues: ([candidate.mappedHost] + candidate.unmatchedHosts).compactMap { host in
                HIDPeripheral.shared.connectionSession(for: host).map { (host, $0) }
            })
        guard sessions.count == candidate.unmatchedHosts.count + 1 else { return .blocked }
        guard recoverySnapshotIsCurrent(screens: screens, hosts: hosts, pairings: pairings, sessions: sessions)
        else { return .blocked }

        var probeResults: [UUID: DevicePairingRecovery.ProbeResult] = [:]
        for host in [candidate.mappedHost] + candidate.unmatchedHosts {
            guard recoverySnapshotIsCurrent(screens: screens, hosts: hosts, pairings: pairings, sessions: sessions)
            else { return .blocked }
            guard let expectedSession = sessions[host] else { return .blocked }

            if host == candidate.mappedHost {
                // Reuse an existing queue when available. If there is no
                // cached queue, probeOutcome creates an isolated input with
                // the expected session token instead of fetching a newer one.
                let sharedInput = cachedInput(for: host, session: expectedSession)
                probeResults[host] = probeOutcome(
                    host, on: screen, calibration: .calibrated(mappedCalibration), expectedSession: expectedSession,
                    input: sharedInput)
            } else {
                let calibration = RelativePointerCalibration.pairingProbeCalibration(host: host, screenID: screen.id)
                probeResults[host] = probeOutcome(
                    host, on: screen, calibration: calibration,
                    expectedSession: expectedSession,
                    input: cachedInput(for: host, session: expectedSession))
            }
        }
        guard recoverySnapshotIsCurrent(screens: screens, hosts: hosts, pairings: pairings, sessions: sessions)
        else { return .blocked }
        guard let replacement = DevicePairingRecovery.replacement(for: candidate, probeResults: probeResults) else {
            return .blocked
        }
        return .recovered(replacement)
    }

    /// Verifies an unidentified saved mapping with a candidate-first probe.
    /// This avoids moving the mapped phone's pointer when an unrelated BLE host
    /// appears, while still repairing stale USB-to-host pairs created by older
    /// releases once the current screen has a unique replacement candidate.
    private func verifyUnidentifiedCurrentMapping(
        _ candidate: DevicePairingRecovery.Candidate, screen: ScreenCaptureSession,
        screens: [ScreenCaptureSession], hosts: [UUID], pairings: [String: UUID]
    ) -> ReplacementRecovery {
        let probeHosts = [candidate.mappedHost] + candidate.unmatchedHosts
        let sessions = Dictionary(
            uniqueKeysWithValues: probeHosts.compactMap { host in
                HIDPeripheral.shared.connectionSession(for: host).map { (host, $0) }
            })
        guard sessions.count == probeHosts.count,
            recoverySnapshotIsCurrent(screens: screens, hosts: hosts, pairings: pairings, sessions: sessions)
        else { return .blocked }

        var probeResults: [UUID: DevicePairingRecovery.ProbeResult] = [:]
        for host in candidate.unmatchedHosts {
            guard recoverySnapshotIsCurrent(screens: screens, hosts: hosts, pairings: pairings, sessions: sessions),
                let expectedSession = sessions[host]
            else { return .blocked }

            let calibration = RelativePointerCalibration.pairingProbeCalibration(host: host, screenID: screen.id)
            let result = probeOutcome(
                host, on: screen, calibration: calibration, expectedSession: expectedSession,
                input: cachedInput(for: host, session: expectedSession))
            guard result != .unavailable else { return .blocked }
            probeResults[host] = result

            // A second hit already makes the candidate set ambiguous. Stop
            // here instead of moving more unrelated phones' pointers.
            if probeResults.values.filter({ $0 == .hit }).count > 1 { return .blocked }
        }
        guard DevicePairingRecovery.uniqueCandidateHit(for: candidate, probeResults: probeResults) != nil,
            recoverySnapshotIsCurrent(screens: screens, hosts: hosts, pairings: pairings, sessions: sessions),
            let mappedSession = sessions[candidate.mappedHost]
        else { return .blocked }

        let mappedCalibration: PairingProbeCalibration
        if let calibration = RelativePointerCalibration.load(host: candidate.mappedHost, screenSize: nil) {
            mappedCalibration = .calibrated(calibration)
        } else if RelativePointerCalibration.requiresCalibration(host: candidate.mappedHost, screenID: nil) {
            // A malformed calibration opts this host into calibrated reports;
            // an absolute probe could falsely classify it as a miss.
            mappedCalibration = .unavailable
        } else {
            mappedCalibration = .absolute
        }
        let mappedResult = probeOutcome(
            candidate.mappedHost, on: screen, calibration: mappedCalibration, expectedSession: mappedSession,
            input: cachedInput(for: candidate.mappedHost, session: mappedSession))
        probeResults[candidate.mappedHost] = mappedResult

        guard recoverySnapshotIsCurrent(screens: screens, hosts: hosts, pairings: pairings, sessions: sessions) else {
            return .blocked
        }
        guard let replacement = DevicePairingRecovery.replacement(for: candidate, probeResults: probeResults) else {
            return .blocked
        }
        return .recovered(replacement)
    }

    private func recoverySnapshotIsCurrent(
        screens: [ScreenCaptureSession], hosts: [UUID], pairings: [String: UUID], sessions: [UUID: UUID]
    ) -> Bool {
        let current = ScreenCaptureManager.shared.all
        return current.count == screens.count && zip(current, screens).allSatisfy { $0 === $1 }
            && Set(HIDPeripheral.shared.connectedHosts) == Set(hosts)
            && lock.withLock({ self.pairings == pairings })
            && sessions.allSatisfy({ HIDPeripheral.shared.connectionSession(for: $0.key) == $0.value })
    }

    private func probeOutcome(
        _ host: UUID, on screen: ScreenCaptureSession,
        calibration: PairingProbeCalibration, expectedSession: UUID,
        input sharedInput: DeviceInput? = nil
    ) -> DevicePairingRecovery.ProbeResult {
        let selectedCalibration: RelativePointerCalibration?
        switch calibration {
        case .calibrated(let profile):
            selectedCalibration = profile
        case .absolute:
            selectedCalibration = nil
        case .unavailable:
            return .unavailable
        }
        let input =
            sharedInput
            ?? DeviceInput(
                host: host, session: expectedSession,
                calibration: selectedCalibration, calibrationRequired: selectedCalibration != nil)
        // The session snapshot is part of the recovery proof. Do not create or
        // probe an input against a newly fetched session after that proof; a
        // reconnect during probing must make the recovery attempt unavailable.
        guard input.host == host, input.session == expectedSession, input.isCurrentSession else {
            return .unavailable
        }
        let requiredReports: [ReportID] = selectedCalibration == nil ? [.absolutePointer] : [.relativeMouse]
        do {
            let captures = try input.pairingProbe(
                calibration: selectedCalibration,
                firstPoint: CGPoint(x: PointerScreenMatcher.firstPoint.x, y: PointerScreenMatcher.firstPoint.y),
                secondPoint: CGPoint(x: PointerScreenMatcher.secondPoint.x, y: PointerScreenMatcher.secondPoint.y),
                isReady: {
                    requiredReports.allSatisfy {
                        HIDPeripheral.shared.isReady(report: $0, host: host, session: expectedSession)
                    }
                },
                capture: { screen.thumbnail(width: PointerScreenMatcher.width, height: PointerScreenMatcher.height) })
            let metrics = PointerScreenMatcher.changeMetrics(before: captures.before, after: captures.after)
            return DevicePairingRecovery.probeResult(for: metrics)
        } catch {
            log("probe \(host) unavailable: \(error)")
            return .unavailable
        }
    }

    /// Moves the host's pointer between two spots and returns the one screen where both
    /// spots changed and the rest of the screen did not.
    private func probe(_ host: UUID, among screens: [ScreenCaptureSession]) -> ScreenCaptureSession? {
        let knownID = lock.withLock { pairings.first { $0.value == host }?.key }
        let input: DeviceInput
        if let screen = ScreenCaptureManager.shared.all.first(where: { $0.id == knownID }) {
            input = self.input(for: host, screen: screen)
        } else {
            // Candidates are not confirmed pairings. Never bind a legacy
            // calibration to screens.first or cache that speculative identity.
            // Matching is serialized and these synchronous moves finish before
            // store publishes the confirmed pairing to API/window consumers.
            input = DeviceInput(
                host: host, session: HIDPeripheral.shared.connectionSession(for: host),
                calibration: RelativePointerCalibration.load(host: host, screenSize: nil),
                calibrationRequired: RelativePointerCalibration.requiresCalibration(host: host, screenID: nil))
        }
        let a = PointerScreenMatcher.firstPoint
        let b = PointerScreenMatcher.secondPoint
        try? input.move(x: a.x, y: a.y)
        Thread.sleep(forTimeInterval: 0.6)
        let before = screens.map {
            $0.thumbnail(width: PointerScreenMatcher.width, height: PointerScreenMatcher.height)
        }
        try? input.move(x: b.x, y: b.y)
        Thread.sleep(forTimeInterval: 0.6)
        let after = screens.map { $0.thumbnail(width: PointerScreenMatcher.width, height: PointerScreenMatcher.height) }

        var scores: [(screen: ScreenCaptureSession, score: Int)] = []
        for (i, screen) in screens.enumerated() {
            guard let p = before[i], let q = after[i] else { continue }
            scores.append((screen, PointerScreenMatcher.score(before: p, after: q)))
        }
        log("probe \(host): " + scores.map { "\($0.screen.name)=\($0.score)" }.joined(separator: " "))

        let ranked = scores.sorted { $0.score > $1.score }
        guard let best = ranked.first, best.score >= 3 else { return nil }
        if ranked.count > 1, ranked[1].score * 2 >= best.score { return nil }
        return best.screen
    }

    // MARK: Saved matches

    /// One host drives one screen, so a new match replaces the host's old one.
    @discardableResult
    private func store(
        _ found: [String: UUID], migrateCalibrationProfiles: Bool = true,
        expectingPairings expectedPairings: [String: UUID]? = nil
    ) -> Bool {
        guard !found.isEmpty else { return true }
        return lock.withLock {
            // Recovery is based on a snapshot taken before probing. Check it
            // again while holding the same lock used to publish pairings so a
            // concurrent explicit /pair cannot be overwritten by stale data.
            guard expectedPairings == nil || pairings == expectedPairings else { return false }
            for (id, host) in found {
                // CoreBluetooth may assign a new central UUID after the phone
                // is forgotten and paired again. Keep the measured curve with
                // the USB screen instead of silently falling back to the
                // unsupported absolute report on iOS 15.4.
                if migrateCalibrationProfiles, let oldHost = pairings[id], oldHost != host {
                    migrateCalibration(from: oldHost, to: host, screenID: id)
                }
                for (other, existing) in pairings where existing == host { pairings[other] = nil }
                pairings[id] = host
            }
            pairingStore.save(pairings)
            return true
        }
    }

    private func migrateCalibration(from oldHost: UUID, to newHost: UUID, screenID: String) {
        let destination = RelativePointerCalibration.fileURL(host: newHost)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        do {
            if try RelativePointerCalibration.rebind(from: oldHost, to: newHost, screenID: screenID) != nil {
                log("migrated pointer calibration from \(oldHost) to \(newHost)")
            }
        } catch {
            log("could not migrate pointer calibration to \(newHost): \(error)")
        }
    }

    private func load() {
        guard let saved = pairingStore.load() else { return }
        lock.withLock { pairings = saved }
    }

    private static func describe(_ devices: [Device]) -> String {
        guard !devices.isEmpty else { return "No phones are plugged in." }
        return "Phones: " + devices.map { "\($0.screen.name) (\($0.id))" }.joined(separator: ", ")
    }
}
