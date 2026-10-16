import Foundation

/// `iphone-use mcp`: an MCP server over stdio that forwards to the running app's HTTP API.
/// Screenshots are scaled so the long edge is at most `longEdge`; tap and swipe
/// coordinates are read in that scaled image's pixels.
enum MCPServer {
    static let longEdge = 1200
    static var base = URL(string: "http://127.0.0.1:7390")!

    static let device = MCPToolCatalog.device
    static let tools = MCPToolCatalog.tools

    private static var client: MCPHTTPClient { MCPHTTPClient(base: base) }

    static func run() -> Never {
        if let port = ProcessInfo.processInfo.environment["IPHONE_USE_PORT"] {
            base = URL(string: "http://127.0.0.1:\(port)")!
        }
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let response = response(to: message, callTool: call) {
                write(response)
            }
        }
        exit(0)
    }

    /// Builds one JSON-RPC reply. Notifications and malformed envelopes are silent.
    /// Injecting tool execution keeps protocol handling independent of the HTTP bridge.
    static func response(
        to message: [String: Any], callTool: (String, [String: Any]) -> [String: Any]
    ) -> [String: Any]? {
        guard let id = message["id"], let method = message["method"] as? String else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch method {
        case "initialize":
            result = [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "iphone-use", "version": "0.2.0"],
                "instructions":
                    "Controls real iPhones. Take a screenshot first, then tap using pixel coordinates from the most recent screenshot of that phone. Take another screenshot to check the result. With several phones connected, call list_devices and pass device to every tool.",
            ]
        case "tools/list":
            result = ["tools": tools]
        case "tools/call":
            result = callTool(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
        case "ping":
            result = [:]
        default:
            let error: [String: Any] = ["code": -32601, "message": "method not found: \(method)"]
            return ["jsonrpc": "2.0", "id": id, "error": error]
        }
        return ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func call(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        let device = arguments["device"] as? String
        do {
            switch name {
            case "list_devices":
                let (data, _) = try client.get("/devices")
                return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]
            case "screenshot":
                return try screenshot(device)
            default:
                guard let action = try MCPToolRequest.action(named: name, arguments: arguments, longEdge: longEdge)
                else {
                    return failure("unknown tool \(name)")
                }
                try client.post(action.path, action.body)
            }
            // Successful actions settle before their confirmation screenshot. Preserve
            // this order so the image reflects the action rather than the prior frame.
            Thread.sleep(forTimeInterval: 0.6)
            return try screenshot(device)
        } catch {
            return failure("\(error)")
        }
    }

    private static func screenshot(_ device: String?) throws -> [String: Any] {
        var path = "/screenshot?maxEdge=\(longEdge)"
        if let device, let encoded = device.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "&device=\(encoded)"
        }
        let (image, response) = try client.get(path)
        let width = response.value(forHTTPHeaderField: "X-Image-Width") ?? "?"
        let height = response.value(forHTTPHeaderField: "X-Image-Height") ?? "?"
        let id = response.value(forHTTPHeaderField: "X-Device") ?? ""
        return [
            "content": [
                ["type": "image", "data": image.base64EncodedString(), "mimeType": "image/jpeg"],
                [
                    "type": "text",
                    "text": "Screenshot of \(id), \(width)x\(height) px. Use these pixels for tap and swipe.",
                ],
            ]
        ]
    }

    private static func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    private static func failure(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    struct MCPError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

/// The stdio server's synchronous bridge to the app's local HTTP API.
/// Keep the semaphore wait and URLSession callback together: each MCP tool completes
/// its HTTP action before the server reads and processes the next input line.
private struct MCPHTTPClient {
    let base: URL

    func get(_ path: String) throws -> (Data, HTTPURLResponse) {
        try request(URLRequest(url: URL(string: path, relativeTo: base)!))
    }

    @discardableResult
    func post(_ path: String, _ body: [String: Any]) throws -> Data {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try self.request(request).0
    }

    private func request(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        var result: Result<(Data, HTTPURLResponse), Error> = .failure(MCPServer.MCPError("no response"))
        let done = DispatchSemaphore(value: 0)
        var request = request
        request.timeoutInterval = 60
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(MCPServer.MCPError("iPhone Use app is not running (\(error.localizedDescription))"))
            } else if let data, let http = response as? HTTPURLResponse {
                if http.statusCode == 200 {
                    result = .success((data, http))
                } else {
                    let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"]
                    result = .failure(MCPServer.MCPError(message as? String ?? "HTTP \(http.statusCode)"))
                }
            }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }
}
