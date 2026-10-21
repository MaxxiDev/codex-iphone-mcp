import Darwin
import Foundation

/// Coordinates independent stdio processes, including short-lived recovery clients.
/// Lock files stay in place: unlinking a live file would split its lock domain.
enum MCPAccess {
    static func withService<T>(
        port: Int, language: AppLanguage = .en, _ body: () throws -> T
    ) throws -> T {
        try withLock("service-\(port).lock", shared: true, language: language, body)
    }

    static func withDevice<T>(port: Int, id: String, language: AppLanguage = .en, _ body: () throws -> T) throws -> T {
        let key = id.lowercased().utf8.map { String(format: "%02x", $0) }.joined()
        return try withLock("device-\(port)-\(key).lock", shared: false, language: language, body)
    }

    private static func withLock<T>(
        _ name: String, shared: Bool, language: AppLanguage, _ body: () throws -> T
    ) throws -> T {
        let table = StringsMCP(language: language)
        if let path = ProcessInfo.processInfo.environment["IPHONE_USE_STATE_DIR"], !path.hasPrefix("/") {
            throw MCPServer.MCPError(table.lockStateDirAbsolute)
        }
        let directory =
            ProcessInfo.processInfo.environment["IPHONE_USE_STATE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/iPhoneUse")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent(name).path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MCPServer.MCPError(table.lockOpenFailed(Int32(errno))) }
        defer { close(fd) }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while flock(fd, (shared ? LOCK_SH : LOCK_EX) | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else {
                throw MCPServer.MCPError(table.lockAcquireFailed(Int32(errno)))
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw MCPServer.MCPError(
                    shared ? table.lockServiceBusy : table.lockDeviceBusy)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
