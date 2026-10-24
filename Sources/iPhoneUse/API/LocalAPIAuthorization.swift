import Darwin
import Foundation
import Security

/// Authenticates local clients; this does not isolate malicious software running as the same user.
struct LocalAPIAuthorization {
    let port: UInt16
    let token: String

    func rejection(for request: HTTPRequest) -> HTTPResponse? {
        let hosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host = request.headers["host"], hosts.contains(host.lowercased()) else {
            return .error("Invalid local Host", status: 403)
        }
        if let origin = request.headers["origin"], !hosts.map({ "http://" + $0 }).contains(origin.lowercased()) {
            return .error("Cross-origin requests are not allowed", status: 403)
        }
        if request.headers["sec-fetch-site"] == "cross-site" {
            return .error("Cross-site requests are not allowed", status: 403)
        }
        // This shell has no device data. Every subsequent data fetch is authenticated.
        if request.method == "GET", ["/viewer", "/viewer/"].contains(request.path) { return nil }
        let expected = Array("Bearer \(token)".utf8)
        let supplied = Array((request.headers["authorization"] ?? "").utf8)
        guard supplied.count == expected.count else { return .error("API token required", status: 401) }
        let difference = zip(supplied, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
        guard difference == 0 else { return .error("API token required", status: 401) }
        if request.method == "POST", !request.body.isEmpty {
            let contentType = request.headers["content-type"]?.split(separator: ";").first?
                .trimmingCharacters(in: .whitespaces).lowercased()
            guard contentType == "application/json" else { return .error("Use application/json") }
        }
        return nil
    }
}

enum LocalAPIToken {
    struct TokenError: Error, CustomStringConvertible { let description: String }

    static var fileURL: URL {
        get throws {
            if let path = ProcessInfo.processInfo.environment["IPHONE_USE_AUTH_FILE"] {
                guard path.hasPrefix("/") else {
                    throw TokenError(description: "IPHONE_USE_AUTH_FILE must be absolute")
                }
                return URL(fileURLWithPath: path)
            }
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/iPhoneUse/api-token")
        }
    }

    static func read(at url: URL? = nil) throws -> String {
        let url = try url ?? fileURL
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw TokenError(description: "API token unavailable; start the reviewed app first") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
            info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600, info.st_size == 65
        else {
            throw TokenError(description: "API token must be an owner-only (0600) regular file")
        }
        let data = try handle.read(upToCount: 66) ?? Data()
        guard data.count == 65, data.last == 10 else { throw TokenError(description: "Invalid API token file") }
        let token = String(decoding: data.dropLast(), as: UTF8.self)
        guard valid(token) else { throw TokenError(description: "Invalid API token file") }
        return token
    }

    static func createIfNeeded(at url: URL? = nil) throws -> String {
        let url = try url ?? fileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0 {
            guard errno == EEXIST else { throw TokenError(description: "Cannot create private API token") }
            return try read(at: url)
        }
        defer { close(fd) }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            unlink(url.path)
            throw TokenError(description: "Secure random generation failed")
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let data = Data((token + "\n").utf8)
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == data.count, fsync(fd) == 0 else {
            unlink(url.path)
            throw TokenError(description: "Could not save API token")
        }
        return token
    }

    static func valid(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
