import Foundation

/// State owned exclusively by HIDPeripheral's Bluetooth queue. Keeping it separate
/// from CoreBluetooth lets disconnect and backpressure handling run without hardware.
struct HIDConnectionState {
    enum Channel: Hashable {
        case report(ReportID)
        case serviceChanged
        case battery

        var isInput: Bool {
            if case .report = self { return true }
            return false
        }
    }

    struct PendingReport {
        let host: UUID
        let channel: Channel
        let data: Data
    }

    private(set) var subscriptions: [UUID: Set<Channel>] = [:]
    private(set) var sessions: [UUID: UUID] = [:]
    private(set) var pending: [PendingReport] = []

    /// A connected keyboard does not imply that the host has subscribed to its
    /// pointer reports yet. Check the report as well as the current session.
    func isReady(report: ReportID, host: UUID, session: UUID?) -> Bool {
        guard let session, sessions[host] == session else { return false }
        return subscriptions[host]?.contains(.report(report)) == true
    }

    mutating func subscribe(_ channel: Channel, host: UUID) {
        subscriptions[host, default: []].insert(channel)
        if channel.isInput, sessions[host] == nil { sessions[host] = UUID() }
    }

    mutating func unsubscribe(_ channel: Channel, host: UUID) {
        subscriptions[host]?.remove(channel)
        pending.removeAll { $0.host == host && $0.channel == channel }
        if !(subscriptions[host]?.contains(where: \.isInput) ?? false) {
            sessions[host] = nil
            pending.removeAll { $0.host == host && $0.channel.isInput }
        }
        if subscriptions[host]?.isEmpty == true { subscriptions[host] = nil }
    }

    /// An old DeviceInput may still have work queued when the same phone reconnects.
    /// Its token must match the current session, as well as the subscription.
    mutating func enqueue(_ channel: Channel, data: Data, host: UUID, session: UUID? = nil) {
        guard subscriptions[host]?.contains(channel) == true else { return }
        if channel.isInput {
            guard let session, sessions[host] == session else { return }
        }
        let report = PendingReport(host: host, channel: channel, data: data)
        // Under backpressure only replace consecutive absolute positions with the
        // same button state. Never merge a key, click or relative displacement.
        if channel == .report(.absolutePointer), let last = pending.last,
            last.host == host, last.channel == channel, last.data.first == data.first
        {
            pending[pending.count - 1] = report
        } else {
            pending.append(report)
        }
    }

    mutating func removeFirst() { pending.removeFirst() }

    mutating func reset() {
        subscriptions.removeAll()
        sessions.removeAll()
        pending.removeAll()
    }
}
