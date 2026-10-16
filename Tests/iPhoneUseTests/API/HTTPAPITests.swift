import Foundation
import XCTest

@testable import iPhoneUse

final class HTTPMessageTests: XCTestCase {
    func testFragmentedRequestWaitsForTheDeclaredUTF8Body() throws {
        let body = Data(#"{"text":"你好"}"#.utf8)
        let header = Data("POST /type HTTP/1.1\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        XCTAssertNil(HTTPRequest.parse(Data(header.dropLast())))
        XCTAssertNil(HTTPRequest.parse(header + body.dropLast()))

        let request = try XCTUnwrap(HTTPRequest.parse(header + body))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/type")
        XCTAssertEqual(request.body["text"] as? String, "你好")
    }

    func testRequestTargetDecodesQueriesAndKeepsTheLastDuplicateValue() throws {
        let request = try XCTUnwrap(
            HTTPRequest.parse(
                Data(
                    "GET /screenshot?device=first&device=My%20iPhone&flag&format=png HTTP/1.1\r\n\r\n".utf8)))

        XCTAssertEqual(request.path, "/screenshot")
        XCTAssertEqual(request.query, ["device": "My iPhone", "flag": "", "format": "png"])
        XCTAssertTrue(request.body.isEmpty)
    }

    func testContentLengthIsCaseInsensitiveAndLastHeaderWins() throws {
        let data = Data("POST /type HTTP/1.1\r\nContent-Length: 900\r\ncOnTeNt-LeNgTh: 2\r\n\r\n{}ignored".utf8)
        let request = try XCTUnwrap(HTTPRequest.parse(data))
        XCTAssertTrue(request.body.isEmpty)
    }

    func testInvalidLengthsAndNonObjectJSONKeepTheExistingEmptyBodyFallback() throws {
        let invalidLength = Data("POST /type HTTP/1.1\r\nContent-Length: invalid\r\n\r\n".utf8)
        XCTAssertTrue(try XCTUnwrap(HTTPRequest.parse(invalidLength)).body.isEmpty)

        for body in ["[1,2]", "broken"] {
            let data = Data("POST /type HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
            XCTAssertTrue(try XCTUnwrap(HTTPRequest.parse(data)).body.isEmpty)
        }
    }

    func testResponseUsesByteLengthAndPreservesBinaryBody() {
        let body = Data([0, 127, 128, 255])
        let response = HTTPResponse(status: 503, contentType: "image/png", headers: ["X-Device": "phone"], body: body)
        let expectedHeader =
            "HTTP/1.1 503 Service Unavailable\r\nContent-Type: image/png\r\nContent-Length: 4\r\nConnection: close\r\nX-Device: phone\r\n\r\n"
        XCTAssertEqual(response.serialized, Data(expectedHeader.utf8) + body)
    }

    func testJSONResponseRetainsSortedKeysAndErrorStatus() {
        XCTAssertEqual(String(decoding: HTTPResponse.json(["z": 1, "a": 2]).body, as: UTF8.self), #"{"a":2,"z":1}"#)
        let response = HTTPResponse.error("pointer busy", status: 409)
        XCTAssertEqual(response.status, 409)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), #"{"error":"pointer busy"}"#)
        XCTAssertTrue(String(decoding: response.serialized, as: UTF8.self).hasPrefix("HTTP/1.1 409 Conflict\r\n"))
    }
}

final class RequestCoordinatesTests: XCTestCase {
    func testScreenshotDimensionsRoundAndNeverUpscale() {
        let portrait = RequestCoordinates.imageSize(CGSize(width: 750, height: 1334), maxWidth: nil, maxEdge: 1200)
        XCTAssertEqual(portrait.0, 675)
        XCTAssertEqual(portrait.1, 1200)

        let constrained = RequestCoordinates.imageSize(CGSize(width: 800, height: 400), maxWidth: 300, maxEdge: 500)
        XCTAssertEqual(constrained.0, 300)
        XCTAssertEqual(constrained.1, 150)

        let original = RequestCoordinates.imageSize(CGSize(width: 100, height: 200), maxWidth: 1000, maxEdge: 1200)
        XCTAssertEqual(original.0, 100)
        XCTAssertEqual(original.1, 200)
    }

    func testCoordinatesUseRoundedScreenshotPixels() throws {
        let point = try RequestCoordinates.point(
            ["x": 337.5, "y": 600, "maxEdge": 1200.9], "x", "y",
            screenSize: CGSize(width: 750, height: 1334), screenName: "phone")
        XCTAssertEqual(point.0, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(point.1, 0.5, accuracy: 0.000_001)
    }

    func testExplicitDimensionsOverrideScaledDimensionsIndependently() throws {
        let point = try RequestCoordinates.point(
            ["x": 100, "y": 600, "width": 200, "maxEdge": 1200], "x", "y",
            screenSize: CGSize(width: 750, height: 1334), screenName: "phone")
        XCTAssertEqual(point.0, 0.5)
        XCTAssertEqual(point.1, 0.5)
    }

    func testFractionsAvoidFrameAccessAndDoNotClampAtTheAPIBoundary() throws {
        var frameReads = 0
        func readFrame() -> CGSize? {
            frameReads += 1
            return nil
        }
        let point = try RequestCoordinates.point(
            ["x": -0.25, "y": 1.5, "fraction": true], "x", "y",
            screenSize: readFrame(), screenName: "phone")
        XCTAssertEqual(point.0, -0.25)
        XCTAssertEqual(point.1, 1.5)
        XCTAssertEqual(frameReads, 0)
    }

    func testMissingCoordinatesTakePrecedenceOverMissingFrame() {
        XCTAssertThrowsError(
            try RequestCoordinates.point(
                ["x": 12], "x", "y", screenSize: nil, screenName: "phone")
        ) { error in
            XCTAssertEqual(String(describing: error), "x and y are required")
        }
        XCTAssertThrowsError(
            try RequestCoordinates.point(
                ["x": 1, "y": 2, "width": 100, "height": 200], "x", "y",
                screenSize: nil, screenName: "phone")
        ) { error in
            XCTAssertEqual(String(describing: error), "no frame yet from phone")
        }
    }

    func testNumericBridgingAndZeroDimensionsRemainPermissive() throws {
        let point = try RequestCoordinates.point(
            ["x": true, "y": 2, "width": 2, "height": 0], "x", "y",
            screenSize: CGSize(width: 100, height: 200), screenName: "phone")
        XCTAssertEqual(point.0, 0.5)
        XCTAssertTrue(point.1.isInfinite)
    }
}

final class SwipeRequestTests: XCTestCase {
    func testMCPPathSurvivesHTTPEncodingAndEmitsOneContinuousDrag() throws {
        let action = try XCTUnwrap(
            MCPToolRequest.action(
                named: "swipe",
                arguments: [
                    "points": [["x": 0, "y": 1200], ["x": 600, "y": 600], ["x": 0, "y": 0]],
                    "duration": 0.12, "device": "phone",
                ], longEdge: 1200))
        let json = try JSONSerialization.data(withJSONObject: action.body)
        let header = Data("POST \(action.path) HTTP/1.1\r\nContent-Length: \(json.count)\r\n\r\n".utf8)
        let request = try XCTUnwrap(HTTPRequest.parse(header + json))
        XCTAssertEqual(request.path, "/swipe")
        XCTAssertEqual(request.body["device"] as? String, "phone")

        let size = CGSize(width: 600, height: 1200)
        let swipe = try SwipeRequest(request.body, screenSize: size, screenName: "phone")
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(
            host: UUID(), session: UUID(), screenSize: { size }, sleep: { _ in },
            reportSender: { reports.append(($0, $1)) })
        try input.swipe(points: swipe.points, duration: swipe.duration)

        XCTAssertEqual(reports.first?.1, [0, 0, 0, 255, 127])
        XCTAssertTrue(reports.contains { $0.0 == .absolutePointer && $0.1 == [1, 255, 127, 0, 64] })
        XCTAssertEqual(reports.filter { $0.0 == .relativeMouse }.map { $0.1 }, [[1, 0, 0, 0], [0, 0, 0, 0]])
        XCTAssertTrue(reports.dropFirst().dropLast().allSatisfy { $0.1[0] == 1 })
        XCTAssertEqual(reports.suffix(2).map { $0.1 }, [[1, 0, 0, 0, 0], [0, 0, 0, 0]])
    }

    func testJSONPathUsesOriginalScreenPixelsAndPreservesPointOrder() throws {
        let json = #"{"points":[{"x":0,"y":200},{"x":100,"y":100},{"x":50,"y":0}],"duration":0.6}"#
        let wire = Data("POST /swipe HTTP/1.1\r\nContent-Length: \(json.utf8.count)\r\n\r\n\(json)".utf8)
        let request = try XCTUnwrap(HTTPRequest.parse(wire))
        let swipe = try SwipeRequest(request.body, screenSize: CGSize(width: 100, height: 200), screenName: "phone")

        XCTAssertEqual(swipe.points.map { $0.0 }, [0, 1, 0.5])
        XCTAssertEqual(swipe.points.map { $0.1 }, [1, 0.5, 0])
        XCTAssertEqual(swipe.duration, 0.6)
    }

    func testScreenshotScalingAppliesToEveryPointAndExplicitDimensionsOverrideIt() throws {
        let body: [String: Any] = [
            "points": [["x": 337.5, "y": 600], ["x": 675, "y": 1200]], "maxEdge": 1200,
        ]
        let scaled = try SwipeRequest(body, screenSize: CGSize(width: 750, height: 1334), screenName: "phone")
        XCTAssertEqual(scaled.points.map { $0.0 }, [0.5, 1])
        XCTAssertEqual(scaled.points.map { $0.1 }, [0.5, 1])

        var resizedBody = body
        resizedBody["width"] = 1350
        let resized = try SwipeRequest(resizedBody, screenSize: CGSize(width: 750, height: 1334), screenName: "phone")
        XCTAssertEqual(resized.points.map { $0.0 }, [0.25, 0.5])
        XCTAssertEqual(resized.points.map { $0.1 }, [0.5, 1])
    }

    func testFractionPathNeedsNoFrameAndUsesDefaultDuration() throws {
        let swipe = try SwipeRequest(
            ["points": [["x": 0.2, "y": 0.8], ["x": 0.7, "y": 0.3]], "fraction": true],
            screenSize: nil, screenName: "phone")
        XCTAssertEqual(swipe.points.map { $0.0 }, [0.2, 0.7])
        XCTAssertEqual(swipe.points.map { $0.1 }, [0.8, 0.3])
        XCTAssertEqual(swipe.duration, 0.3)
    }

    func testPointLocalFieldsCannotOverridePathCoordinateSpace() throws {
        let swipe = try SwipeRequest(
            [
                "points": [["x": 25, "y": 50, "width": 25, "fraction": true], ["x": 50, "y": 100]],
                "width": 100, "height": 200,
            ], screenSize: CGSize(width: 500, height: 1000), screenName: "phone")
        XCTAssertEqual(swipe.points.map { $0.0 }, [0.25, 0.5])
        XCTAssertEqual(swipe.points.map { $0.1 }, [0.25, 0.5])
    }

    func testMissingPointsAndOldEndpointParametersAreRejected() {
        for body: [String: Any] in [[:], ["x1": 0, "y1": 0, "x2": 100, "y2": 200]] {
            XCTAssertThrowsError(try SwipeRequest(body, screenSize: nil, screenName: "phone")) { error in
                XCTAssertEqual(
                    String(describing: error), "points must contain at least two objects with numeric x and y")
            }
        }
    }

    func testInvalidArrayShapesAreRejected() {
        let invalidPoints: [Any] = [
            NSNull(), "0,0,1,1", [], [["x": 0, "y": 0]], [[0, 0], [1, 1]],
            [["x": 0, "y": 0], NSNull()],
        ]
        for points in invalidPoints {
            XCTAssertThrowsError(
                try SwipeRequest(["points": points, "fraction": true], screenSize: nil, screenName: "phone"))
        }
    }

    func testEveryPointMustHaveFiniteNumericCoordinates() {
        let invalidCoordinates: [Any] = [true, "0.5", NSNull(), Double.nan, Double.infinity]
        for invalid in invalidCoordinates {
            for axis in ["x", "y"] {
                var last: [String: Any] = ["x": 1, "y": 1]
                last[axis] = invalid
                XCTAssertThrowsError(
                    try SwipeRequest(
                        ["points": [["x": 0, "y": 0], last], "fraction": true],
                        screenSize: nil, screenName: "phone"))
            }
        }
        XCTAssertThrowsError(
            try SwipeRequest(
                ["points": [["x": 0, "y": 0], ["x": 1]], "fraction": true],
                screenSize: nil, screenName: "phone"))
    }

    func testExplicitDurationMustBePositiveAndNumeric() {
        let invalidDurations: [Any] = [0, -0.1, true, "0.3", NSNull(), Double.nan, Double.infinity]
        for duration in invalidDurations {
            XCTAssertThrowsError(
                try SwipeRequest(
                    ["points": [["x": 0, "y": 0], ["x": 1, "y": 1]], "fraction": true, "duration": duration],
                    screenSize: nil, screenName: "phone"))
        }
    }

    func testInvalidImageDimensionsCannotReachPointerInterpolation() {
        let body: [String: Any] = ["points": [["x": 0, "y": 0], ["x": 1, "y": 1]]]
        for key in ["width", "height", "maxEdge"] {
            for invalid: Any in [0, -1, true, "100", NSNull(), Double.infinity] {
                var invalidBody = body
                invalidBody[key] = invalid
                XCTAssertThrowsError(
                    try SwipeRequest(invalidBody, screenSize: CGSize(width: 100, height: 200), screenName: "phone"))
            }
        }
        for maxEdge in [0.5, Double(Int.max), Double.greatestFiniteMagnitude] {
            var invalidBody = body
            invalidBody["maxEdge"] = maxEdge
            XCTAssertThrowsError(
                try SwipeRequest(invalidBody, screenSize: CGSize(width: 100, height: 200), screenName: "phone"))
        }
        XCTAssertThrowsError(try SwipeRequest(body, screenSize: nil, screenName: "phone"))
        XCTAssertThrowsError(try SwipeRequest(body, screenSize: .zero, screenName: "phone"))
    }
}
