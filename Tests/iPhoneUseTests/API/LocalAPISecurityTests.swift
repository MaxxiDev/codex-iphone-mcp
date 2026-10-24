import Foundation
import XCTest

@testable import iPhoneUse

final class LocalAPISecurityTests: XCTestCase {
    private let token = String(repeating: "a", count: 64)

    private func request(_ path: String = "/devices", headers: [String: String] = [:], method: String = "GET")
        -> HTTPRequest
    {
        HTTPRequest(
            method: method, path: path, query: [:], body: [:],
            headers: ["host": "127.0.0.1:7390"].merging(headers) { _, new in new })
    }

    func testNoDeviceOrControlRouteIsAccessibleWithoutAToken() {
        let auth = LocalAPIAuthorization(port: 7390, token: token)
        for path in ["/", "/status", "/config", "/devices", "/screenshot", "/home", "/tap", "/pair", "/match"] {
            XCTAssertEqual(auth.rejection(for: request(path))?.status, 401)
        }
    }

    func testOnlyExactBearerTokenIsAccepted() {
        let auth = LocalAPIAuthorization(port: 7390, token: token)
        XCTAssertNil(auth.rejection(for: request(headers: ["authorization": "Bearer " + token])))
        for value in ["Bearer bad", "Bearer " + String(repeating: "b", count: 64), token] {
            XCTAssertEqual(auth.rejection(for: request(headers: ["authorization": value]))?.status, 401)
        }
    }

    func testMaliciousOriginOrHostCannotUseEvenAValidToken() {
        let auth = LocalAPIAuthorization(port: 7390, token: token)
        for extra in [
            ["origin": "https://evil.example"], ["origin": "null"],
            ["host": "evil.example:7390"], ["sec-fetch-site": "cross-site"],
        ] {
            let headers = ["authorization": "Bearer " + token].merging(extra) { _, new in new }
            XCTAssertEqual(auth.rejection(for: request(headers: headers))?.status, 403)
        }
        XCTAssertNil(
            auth.rejection(
                for: request(headers: [
                    "authorization": "Bearer " + token, "origin": "http://127.0.0.1:7390",
                ])))
    }

    func testViewerShellNeedsNoTokenButDoesNotEmbedOne() {
        let auth = LocalAPIAuthorization(port: 7390, token: token)
        XCTAssertNil(auth.rejection(for: request("/viewer")))
        let html = WebPreview.html(for: .en)
        XCTAssertFalse(html.contains(token))
        XCTAssertTrue(html.contains("Authorization: 'Bearer ' + API_TOKEN"))
    }

    func testTextPlainCannotSendJSONActions() {
        let auth = LocalAPIAuthorization(port: 7390, token: token)
        var headers = [
            "host": "127.0.0.1:7390", "authorization": "Bearer " + token,
            "content-type": "text/plain",
        ]
        XCTAssertEqual(
            auth.rejection(
                for: HTTPRequest(
                    method: "POST", path: "/type", query: [:], body: ["text": "hello"], headers: headers))?.status, 400)
        headers["content-type"] = "application/json; charset=utf-8"
        XCTAssertNil(
            auth.rejection(
                for: HTTPRequest(
                    method: "POST", path: "/type", query: [:], body: ["text": "hello"], headers: headers)))
    }

    func testTokenIsPrivateStableAndRejectsSymlinksAndLoosePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("api-token")
        let first = try LocalAPIToken.createIfNeeded(at: url)
        XCTAssertTrue(LocalAPIToken.valid(first))
        XCTAssertEqual(try LocalAPIToken.createIfNeeded(at: url), first)
        XCTAssertEqual(try LocalAPIToken.read(at: url), first)
        let link = directory.appendingPathComponent("linked-token")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertThrowsError(try LocalAPIToken.read(at: link))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertThrowsError(try LocalAPIToken.read(at: url))
        XCTAssertThrowsError(try LocalAPIToken.createIfNeeded(at: url))
    }

    func testMalformedHeaderLimitsAndTransferEncodingAreRejected() {
        for input in [
            "GET / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
            "GET http://evil.example/ HTTP/1.1\r\n\r\n",
            "GET / HTTP/1.1\r\nHost: local\r\nhost: evil\r\n\r\n",
            "GET / HTTP/1.1\r\nMalformed\r\n\r\n",
            String(repeating: "x", count: HTTPRequest.maxHeaderBytes + 1),
        ] {
            XCTAssertThrowsError(try HTTPRequest.parseChecked(Data(input.utf8)))
        }
    }

    func testUnreasonablyLongGesturesAndInvalidImageSizesAreRejected() {
        for value: Any in [true, "1", Double.infinity, 1.5, Int.max, 4097] {
            XCTAssertThrowsError(try RequestCoordinates.hidCount(value))
        }
        XCTAssertEqual(try RequestCoordinates.hidCount(-1500), -1500)
        for value: Any in [true, "1", -1, 0, Double.infinity, 11] {
            XCTAssertThrowsError(try RequestCoordinates.duration(value, default: 1))
        }
        for value in ["-1", "0", "8193", "bad", "999999999999999999999"] {
            XCTAssertThrowsError(try RequestCoordinates.imageLimit(value))
        }
    }
}
