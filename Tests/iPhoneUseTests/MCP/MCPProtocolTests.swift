import Foundation
import XCTest

@testable import iPhoneUse

final class MCPProtocolTests: XCTestCase {
    func testNotificationsAndMalformedMessagesProduceNoReplyOrToolCall() {
        let call: (String, [String: Any]) -> [String: Any] = { _, _ in
            XCTFail("A notification must not execute a tool")
            return [:]
        }
        XCTAssertNil(MCPServer.response(to: ["method": "tools/call"], callTool: call))
        XCTAssertNil(MCPServer.response(to: ["id": 1], callTool: call))
        XCTAssertNil(MCPServer.response(to: ["id": 1, "method": 99], callTool: call))
    }

    func testInitializeEchoesTheRequestedVersionAndSuppliesTheExistingDefault() throws {
        for version in [nil, "2024-11-05"] as [String?] {
            var message: [String: Any] = ["id": 7, "method": "initialize"]
            if let version { message["params"] = ["protocolVersion": version] }
            let reply = try XCTUnwrap(MCPServer.response(to: message) { _, _ in [:] })
            let result = try XCTUnwrap(reply["result"] as? [String: Any])
            XCTAssertEqual(reply["jsonrpc"] as? String, "2.0")
            XCTAssertEqual(reply["id"] as? Int, 7)
            XCTAssertEqual(result["protocolVersion"] as? String, version ?? "2025-06-18")
            XCTAssertEqual(result["serverInfo"] as? [String: String], ["name": "iphone-use", "version": "0.2.0"])
        }
    }

    func testUnknownMethodUsesJSONRPCErrorAndPreservesTheID() throws {
        let reply = try XCTUnwrap(MCPServer.response(to: ["id": "request", "method": "unknown"]) { _, _ in [:] })
        let error = try XCTUnwrap(reply["error"] as? [String: Any])
        XCTAssertEqual(reply["id"] as? String, "request")
        XCTAssertEqual(error["code"] as? Int, -32601)
        XCTAssertEqual(error["message"] as? String, "method not found: unknown")
        XCTAssertNil(reply["result"])
    }

    func testToolCallsKeepEmptyParameterDefaultsAndReturnTheToolResult() throws {
        var receivedName: String?
        var receivedArguments: [String: Any]?
        let reply = try XCTUnwrap(
            MCPServer.response(to: ["id": 1, "method": "tools/call", "params": ["arguments": []]]) {
                name, arguments in
                receivedName = name
                receivedArguments = arguments
                return ["isError": true]
            })
        XCTAssertEqual(receivedName, "")
        XCTAssertTrue(try XCTUnwrap(receivedArguments).isEmpty)
        XCTAssertEqual(reply["result"] as? [String: Bool], ["isError": true])
    }

    func testTapAndLongPressPreserveScalingDeviceAndDurationDefaults() throws {
        let args: [String: Any] = ["x": 50, "y": 80, "device": "phone"]
        let tap = try XCTUnwrap(MCPToolRequest.action(named: "tap", arguments: args, longEdge: 1200))
        XCTAssertEqual(tap.path, "/tap")
        XCTAssertEqual(tap.body["maxEdge"] as? Int, 1200)
        XCTAssertEqual(tap.body["device"] as? String, "phone")
        XCTAssertEqual(tap.body["x"] as? Int, 50)
        XCTAssertNil(tap.body["hold"])

        let longPress = try XCTUnwrap(MCPToolRequest.action(named: "long_press", arguments: args, longEdge: 1200))
        XCTAssertEqual(longPress.path, "/tap")
        XCTAssertEqual(longPress.body["hold"] as? Double, 1.0)
    }

    func testSwipeSchemaRequiresAnOrderedPointArrayAndPositiveDuration() throws {
        let reply = try XCTUnwrap(
            MCPServer.response(to: ["id": 1, "method": "tools/list"]) { _, _ in
                XCTFail("Listing tools must not execute an action")
                return [:]
            })
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let swipe = try XCTUnwrap(tools.first { $0["name"] as? String == "swipe" })
        let schema = try XCTUnwrap(swipe["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["points"])
        let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        XCTAssertEqual(Set(properties.keys), ["points", "duration", "device"])
        let points = try XCTUnwrap(properties["points"])
        XCTAssertEqual(points["type"] as? String, "array")
        XCTAssertEqual(points["minItems"] as? Int, 2)
        let point = try XCTUnwrap(points["items"] as? [String: Any])
        XCTAssertEqual(point["type"] as? String, "object")
        XCTAssertEqual(point["required"] as? [String], ["x", "y"])
        let coordinates = try XCTUnwrap(point["properties"] as? [String: [String: Any]])
        XCTAssertEqual(coordinates["x"]?["type"] as? String, "number")
        XCTAssertEqual(coordinates["y"]?["type"] as? String, "number")
        XCTAssertEqual(properties["duration"]?["type"] as? String, "number")
        XCTAssertEqual(properties["duration"]?["exclusiveMinimum"] as? Int, 0)
    }

    func testSwipePreservesPointOrderScalingDeviceAndExplicitDuration() throws {
        let points = [["x": 300.5, "y": 900.0], ["x": 100.0, "y": 600.25], ["x": 400.0, "y": 300.0]]
        let args: [String: Any] = ["points": points, "duration": 0.8, "device": "phone"]
        let swipe = try XCTUnwrap(MCPToolRequest.action(named: "swipe", arguments: args, longEdge: 1200))
        XCTAssertEqual(swipe.path, "/swipe")
        XCTAssertEqual(swipe.body["points"] as? [[String: Double]], points)
        XCTAssertEqual(swipe.body["duration"] as? Double, 0.8)
        XCTAssertEqual(swipe.body["maxEdge"] as? Int, 1200)
        XCTAssertEqual(swipe.body["device"] as? String, "phone")
        XCTAssertEqual(Set(swipe.body.keys), ["points", "duration", "maxEdge", "device"])
    }

    func testSwipeDefaultsDurationWithoutAcceptingTheFormerSecondsParameter() throws {
        let points = [["x": 1, "y": 2], ["x": 3, "y": 4]]
        for arguments: [String: Any] in [["points": points], ["points": points, "seconds": 9.0]] {
            let swipe = try XCTUnwrap(MCPToolRequest.action(named: "swipe", arguments: arguments, longEdge: 1200))
            XCTAssertEqual(swipe.body["duration"] as? Double, 0.3)
            XCTAssertNil(swipe.body["seconds"])
            XCTAssertNil(swipe.body["device"])
        }
    }

    func testSwipeRequiresPointsEvenWhenFormerEndpointParametersArePresent() {
        let oldArguments: [String: Any] = ["x1": 1, "y1": 2, "x2": 3, "y2": 4, "seconds": 0.5]
        for arguments in [[:], oldArguments] {
            XCTAssertThrowsError(try MCPToolRequest.action(named: "swipe", arguments: arguments, longEdge: 1200)) {
                error in
                XCTAssertEqual(String(describing: error), "points is required")
            }
        }
    }

    func testMissingCoordinatesReportTheFirstMissingKeyButPresentNullIsForwarded() throws {
        XCTAssertThrowsError(try MCPToolRequest.action(named: "tap", arguments: ["x": 1], longEdge: 1200)) { error in
            XCTAssertEqual(String(describing: error), "y is required")
        }
        let action = try XCTUnwrap(
            MCPToolRequest.action(
                named: "tap", arguments: ["x": NSNull(), "y": "unchecked"], longEdge: 1200))
        XCTAssertTrue(action.body["x"] is NSNull)
        XCTAssertEqual(action.body["y"] as? String, "unchecked")
    }

    func testKeyboardAndHomeDefaultsKeepTheirHTTPMappings() throws {
        let type = try XCTUnwrap(MCPToolRequest.action(named: "type_text", arguments: [:], longEdge: 1200))
        XCTAssertEqual(type.path, "/type")
        XCTAssertEqual(type.body["text"] as? String, "")
        let key = try XCTUnwrap(MCPToolRequest.action(named: "press_key", arguments: [:], longEdge: 1200))
        XCTAssertEqual(key.path, "/key")
        XCTAssertEqual(key.body["key"] as? String, "")
        XCTAssertEqual(key.body["modifiers"] as? [String], [])
        let home = try XCTUnwrap(MCPToolRequest.action(named: "home", arguments: ["device": "phone"], longEdge: 1200))
        XCTAssertEqual(home.path, "/home")
        XCTAssertEqual(home.body as? [String: String], ["device": "phone"])
        XCTAssertNil(try MCPToolRequest.action(named: "unknown", arguments: [:], longEdge: 1200))
    }
}
