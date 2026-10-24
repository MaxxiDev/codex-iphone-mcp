import Foundation
import Network

/// The subset of an HTTP request consumed by the local control API.
struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let body: [String: Any]
    var headers: [String: String] = [:]
    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 1024 * 1024
    struct InvalidRequest: Error {}

    /// Returns nil until a request header and its declared body are available.
    /// The server handles one request per connection, so trailing bytes are ignored.
    static func parse(_ data: Data) -> HTTPRequest? {
        try? parseChecked(data)
    }

    static func parseChecked(_ data: Data) throws -> HTTPRequest? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count <= maxHeaderBytes else { throw InvalidRequest() }
            return nil
        }
        guard separator.lowerBound <= maxHeaderBytes,
            let header = String(data: data[..<separator.lowerBound], encoding: .utf8)
        else { throw InvalidRequest() }

        let lines = header.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(String(requestLine[2])) else {
            throw InvalidRequest()
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { throw InvalidRequest() }
            let name = String(pair[0]).lowercased()
            guard !name.isEmpty,
                name.utf8.allSatisfy({
                    (97...122).contains($0) || (48...57).contains($0) || $0 == 45
                }), headers[name] == nil
            else { throw InvalidRequest() }
            headers[name] = pair[1].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { throw InvalidRequest() }
        let rawLength = headers["content-length"] ?? "0"
        guard !rawLength.isEmpty, rawLength.utf8.allSatisfy({ (48...57).contains($0) }),
            let length = Int(rawLength), length <= maxBodyBytes
        else { throw InvalidRequest() }

        let bodyStart = separator.upperBound
        guard data.count - bodyStart >= length else { return nil }
        let bodyData = data[bodyStart..<(bodyStart + length)]
        let body: [String: Any]
        if bodyData.isEmpty {
            body = [:]
        } else {
            guard let object = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
                throw InvalidRequest()
            }
            body = object
        }

        let target = String(requestLine[1])
        guard target.hasPrefix("/"), !target.hasPrefix("//") else { throw InvalidRequest() }
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            // Repeated keys use the last value; a key without '=' has an empty value.
            query[item.name] = item.value ?? ""
        }
        return HTTPRequest(
            method: String(requestLine[0]), path: components?.path ?? target, query: query, body: body,
            headers: headers)
    }
}

struct HTTPResponse {
    var status: Int = 200
    var contentType = "application/json"
    var headers: [String: String] = [:]
    var body = Data()

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return HTTPResponse(status: status, body: data)
    }

    static func error(_ message: String, status: Int = 400) -> HTTPResponse {
        json(["error": message], status: status)
    }

    /// Encodes exactly one response. The transport closes the connection after sending it.
    var serialized: Data {
        var header = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        header += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (name, value) in headers { header += "\(name): \(value)\r\n" }
        header += "\r\n"
        return Data(header.utf8) + body
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 409: "Conflict"
        case 503: "Service Unavailable"
        default: "Error"
        }
    }
}

/// A tiny HTTP/1.1 server on localhost. One request per connection.
/// Request/response values above handle encoding independently of the listener.
final class HTTPServer {
    private let port: NWEndpoint.Port
    private let handler: (HTTPRequest) -> HTTPResponse
    private let authorization: LocalAPIAuthorization
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "iphone-use.http", attributes: .concurrent)

    init(port: UInt16, token: String, handler: @escaping (HTTPRequest) -> HTTPResponse) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.handler = handler
        authorization = LocalAPIAuthorization(port: port, token: token)
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { state in log("http \(state)") }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        let deadline = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + 15, execute: deadline)
        receive(connection, buffer: Data(), deadline: deadline)
    }

    private func receive(_ connection: NWConnection, buffer: Data, deadline: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard buffer.count <= HTTPRequest.maxHeaderBytes + HTTPRequest.maxBodyBytes else {
                deadline.cancel()
                self.send(.error("Request too large"), on: connection)
                return
            }
            do {
                if let request = try HTTPRequest.parseChecked(buffer) {
                    deadline.cancel()
                    self.send(self.authorization.rejection(for: request) ?? self.handler(request), on: connection)
                } else if done || error != nil {
                    deadline.cancel()
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer, deadline: deadline)
                }
            } catch {
                deadline.cancel()
                self.send(.error("Malformed HTTP request"), on: connection)
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        var response = response
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["X-Frame-Options"] = "DENY"
        connection.send(
            content: response.serialized,
            completion: .contentProcessed { _ in
                connection.cancel()
            })
    }
}
