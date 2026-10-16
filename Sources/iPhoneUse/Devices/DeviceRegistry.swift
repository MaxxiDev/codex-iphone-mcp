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
                "\(device.screen.name) has no Bluetooth connection: pair \"\(HIDPeripheral.shared.localName)\" in its Bluetooth settings"
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
        var pairings = lock.withLock { self.pairings }
        if force { for screen in screens { pairings[screen.id] = nil } }

        let matchedHosts = Set(screens.compactMap { pairings[$0.id] }.filter(hosts.contains))
        var freeScreens = screens.filter { pairings[$0.id].map { !hosts.contains($0) } ?? true }
        let freeHosts = hosts.filter { !matchedHosts.contains($0) }
        guard !freeScreens.isEmpty, !freeHosts.isEmpty else { return [:] }

        var found: [String: UUID] = [:]
        if screens.count == 1, hosts.count == 1, !alwaysProbe {
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
    private func store(_ found: [String: UUID]) {
        guard !found.isEmpty else { return }
        lock.withLock {
            for (id, host) in found {
                // CoreBluetooth may assign a new central UUID after the phone
                // is forgotten and paired again. Keep the measured curve with
                // the USB screen instead of silently falling back to the
                // unsupported absolute report on iOS 15.4.
                if let oldHost = pairings[id], oldHost != host {
                    migrateCalibration(from: oldHost, to: host, screenID: id)
                }
                for (other, existing) in pairings where existing == host { pairings[other] = nil }
                pairings[id] = host
            }
            pairingStore.save(pairings)
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
