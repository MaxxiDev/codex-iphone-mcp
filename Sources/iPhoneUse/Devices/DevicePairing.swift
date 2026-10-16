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

    /// Buffers come from ScreenCaptureSession.thumbnail and contain width * height gray pixels.
    static func score(before: [UInt8], after: [UInt8]) -> Int {
        let a = firstPoint
        let b = secondPoint
        let signal = min(changed(before, after, around: a), changed(before, after, around: b))
        let noise = max(changed(before, after, around: (a.x, b.y)), changed(before, after, around: (b.x, a.y)))
        return signal - noise
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
