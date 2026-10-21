import Darwin
import Foundation

/// Coordinates independent stdio processes, including short-lived recovery clients.
/// Lock files stay in place: unlinking a live file would split its lock domain.
enum MCPAccess {
    static func withService<T>(port: Int, _ body: () throws -> T) throws -> T {
        try withLock("service-\(port).lock", shared: true, body)
    }

    static func withDevice<T>(port: Int, id: String, _ body: () throws -> T) throws -> T {
        let key = id.lowercased().utf8.map { String(format: "%02x", $0) }.joined()
        return try withLock("device-\(port)-\(key).lock", shared: false, body)
    }

    private static func withLock<T>(_ name: String, shared: Bool, _ body: () throws -> T) throws -> T {
        if let path = ProcessInfo.processInfo.environment["IPHONE_USE_STATE_DIR"], !path.hasPrefix("/") {
            throw MCPServer.MCPError("IPHONE_USE_STATE_DIR must be an absolute path shared by all clients.")
        }
        let directory =
            ProcessInfo.processInfo.environment["IPHONE_USE_STATE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/iPhoneUse")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent(name).path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MCPServer.MCPError("Cannot open MCP coordination lock: \(errno)") }
        defer { close(fd) }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while flock(fd, (shared ? LOCK_SH : LOCK_EX) | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else {
                throw MCPServer.MCPError("Cannot acquire MCP coordination lock: \(errno)")
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw MCPServer.MCPError(
                    shared
                        ? "Another session is recovering the service; retry after recovery."
                        : "Device busy in another session; take a fresh screenshot before continuing.")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
