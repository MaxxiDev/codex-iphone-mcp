import Foundation

/// Public tool descriptions and input schemas, kept separate from execution.
enum MCPToolCatalog {
    static let device: [String: Any] = [
        "type": "string",
        "description": "Which iPhone (id or name from list_devices). Only needed when several are connected.",
    ]

    static let tools: [[String: Any]] = [
        tool("list_devices", "List the connected iPhones.", [:], readOnly: true),
        tool("screenshot", "Take a screenshot of the iPhone screen.", ["device": device], readOnly: true),
        tool(
            "move_pointer",
            "Move the pointer without clicking, then return a screenshot to inspect the actual landing. Coordinates are pixels of the latest screenshot. Useful when a calibrated tap drifts.",
            ["x": number("X in screenshot pixels"), "y": number("Y in screenshot pixels"), "device": device],
            required: ["x", "y"]),
        tool(
            "adjust_pointer",
            "Nudge the current pointer without clicking and return a screenshot. dx and dy are relative HID counts, not pixels; use small corrections and inspect the actual landing. Does not change the saved calibration.",
            [
                "dx": ["type": "integer", "minimum": -32, "maximum": 32],
                "dy": ["type": "integer", "minimum": -32, "maximum": 32], "device": device,
            ], required: ["dx", "dy"]),
        tool(
            "click_pointer",
            "Click at the current pointer position without moving it, then return a screenshot. First verify the pointer over the intended target with move_pointer or adjust_pointer. Other sessions may move it between calls.",
            ["device": device]),
        tool(
            "tap", "Tap a point on the iPhone screen. Coordinates are pixels of the latest screenshot.",
            ["x": number("X in screenshot pixels"), "y": number("Y in screenshot pixels"), "device": device],
            required: ["x", "y"]),
        tool(
            "long_press", "Press and hold a point, e.g. to open a context menu.",
            [
                "x": number("X in screenshot pixels"), "y": number("Y in screenshot pixels"),
                "seconds": number("How long to hold (default 1)"), "device": device,
            ], required: ["x", "y"]),
        tool(
            "swipe",
            "Drag continuously through an ordered path of at least two points, keeping contact until the last point. Coordinates are pixels of the latest screenshot.",
            [
                "points": [
                    "type": "array", "minItems": 2,
                    "description": "Ordered points of the swipe path in screenshot pixels",
                    "items": [
                        "type": "object",
                        "properties": ["x": number("X in screenshot pixels"), "y": number("Y in screenshot pixels")],
                        "required": ["x", "y"],
                    ],
                ],
                "duration": [
                    "type": "number", "exclusiveMinimum": 0,
                    "description": "Movement duration in seconds for the entire path (default 0.3)",
                ],
                "device": device,
            ], required: ["points"]),
        tool(
            "type_text", "Type text into the focused field with the Bluetooth keyboard (US layout, ASCII only).",
            ["text": ["type": "string"], "device": device], required: ["text"]),
        tool(
            "press_key",
            "Press a key, optionally with modifiers. Keys: enter, escape, backspace, tab, space, up, down, left, right, or a character. Modifiers: cmd, shift, alt, ctrl. cmd+space opens Spotlight.",
            [
                "key": ["type": "string"], "modifiers": ["type": "array", "items": ["type": "string"]],
                "device": device,
            ],
            required: ["key"]),
        tool(
            "keyboard_sequence",
            "Run a short, known keyboard sequence in the current app with one final screenshot. All steps are validated before input; the same-phone MCP lock covers the whole sequence. Stops on error without replay. Use separate calls when an intermediate screen needs inspection. Up to 16 steps and 256 total text characters; US keyboard ASCII only.",
            ["steps": MCPKeyboardSequence.schema, "device": device], required: ["steps"]),
        tool("home", "Go to the Home Screen.", ["device": device]),
    ]

    private static func tool(
        _ name: String, _ description: String, _ properties: [String: Any],
        required: [String] = [], readOnly: Bool = false
    ) -> [String: Any] {
        [
            "name": name, "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required],
            "annotations": ["readOnlyHint": readOnly],
        ]
    }

    private static func number(_ description: String) -> [String: Any] {
        ["type": "number", "description": description]
    }
}

/// An action translated to the app's HTTP API. Building it has no device side effects.
struct MCPToolRequest {
    let path: String
    let body: [String: Any]

    /// Nil means the name is not an action tool. Listing and screenshots have no POST body.
    static func action(named name: String, arguments: [String: Any], longEdge: Int) throws -> MCPToolRequest? {
        let device = arguments["device"] as? String
        switch name {
        case "move_pointer":
            let body = try scaled(arguments, ["x", "y"], longEdge: longEdge)
            for key in ["x", "y"] {
                guard let value = arguments[key] as? NSNumber,
                    CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite, value.doubleValue >= 0
                else { throw MCPServer.MCPError("\(key) must be a finite, nonnegative screenshot coordinate") }
            }
            return MCPToolRequest(path: "/move", body: body)
        case "adjust_pointer":
            var body: [String: Any] = ["click": false]
            for key in ["dx", "dy"] {
                guard let value = arguments[key] as? NSNumber,
                    CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
                    (-32...32).contains(value.doubleValue), value.doubleValue.rounded() == value.doubleValue
                else { throw MCPServer.MCPError("\(key) must be an integer HID count in -32...32") }
                body[key] = value.intValue
            }
            return MCPToolRequest(path: "/nudge", body: withDevice(body, device))
        case "click_pointer":
            return MCPToolRequest(path: "/nudge", body: withDevice(["dx": 0, "dy": 0, "click": true], device))
        case "tap":
            return MCPToolRequest(path: "/tap", body: try scaled(arguments, ["x", "y"], longEdge: longEdge))
        case "long_press":
            var body = try scaled(arguments, ["x", "y"], longEdge: longEdge)
            body["hold"] = arguments["seconds"] ?? 1.0
            return MCPToolRequest(path: "/tap", body: body)
        case "swipe":
            var body = try scaled(arguments, ["points"], longEdge: longEdge)
            body["duration"] = arguments["duration"] ?? 0.3
            return MCPToolRequest(path: "/swipe", body: body)
        case "type_text":
            return MCPToolRequest(path: "/type", body: withDevice(["text": arguments["text"] ?? ""], device))
        case "press_key":
            return MCPToolRequest(
                path: "/key",
                body: withDevice(["key": arguments["key"] ?? "", "modifiers": arguments["modifiers"] ?? []], device))
        case "home":
            return MCPToolRequest(path: "/home", body: withDevice([:], device))
        default:
            return nil
        }
    }

    /// Forward coordinate values unchanged. The HTTP API interprets them against
    /// the screenshot's maxEdge; this bridge checks presence without adding type rules.
    private static func scaled(_ arguments: [String: Any], _ keys: [String], longEdge: Int) throws -> [String: Any] {
        var body: [String: Any] = ["maxEdge": longEdge]
        for key in keys {
            guard let value = arguments[key] else { throw MCPServer.MCPError("\(key) is required") }
            body[key] = value
        }
        return withDevice(body, arguments["device"] as? String)
    }

    private static func withDevice(_ body: [String: Any], _ device: String?) -> [String: Any] {
        guard let device else { return body }
        return body.merging(["device": device]) { $1 }
    }
}
