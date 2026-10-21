import Foundation

/// Public tool descriptions and input schemas, kept separate from execution.
/// Descriptions are localized per language; names, keys, and constraints stay
/// byte-identical so every client keeps working regardless of language.
enum MCPToolCatalog {
    static func device(for table: StringsMCP) -> [String: Any] {
        ["type": "string", "description": table.deviceParam]
    }

    static func tools(for language: AppLanguage) -> [[String: Any]] {
        let table = StringsMCP(language: language)
        let device = device(for: table)
        return [
            tool("list_devices", table.toolListDevices, [:], readOnly: true),
            tool("screenshot", table.toolScreenshot, ["device": device], readOnly: true),
            tool(
                "move_pointer",
                table.toolMovePointer,
                ["x": number(table.xPixels), "y": number(table.yPixels), "device": device],
                required: ["x", "y"]),
            tool(
                "adjust_pointer",
                table.toolAdjustPointer,
                [
                    "dx": ["type": "integer", "minimum": -32, "maximum": 32],
                    "dy": ["type": "integer", "minimum": -32, "maximum": 32], "device": device,
                ], required: ["dx", "dy"]),
            tool(
                "click_pointer",
                table.toolClickPointer,
                ["device": device]),
            tool(
                "tap", table.toolTap,
                ["x": number(table.xPixels), "y": number(table.yPixels), "device": device],
                required: ["x", "y"]),
            tool(
                "long_press", table.toolLongPress,
                [
                    "x": number(table.xPixels), "y": number(table.yPixels),
                    "seconds": number(table.holdSeconds), "device": device,
                ], required: ["x", "y"]),
            tool(
                "swipe",
                table.toolSwipe,
                [
                    "points": [
                        "type": "array", "minItems": 2,
                        "description": table.swipePointsDesc,
                        "items": [
                            "type": "object",
                            "properties": ["x": number(table.xPixels), "y": number(table.yPixels)],
                            "required": ["x", "y"],
                        ],
                    ],
                    "duration": [
                        "type": "number", "exclusiveMinimum": 0,
                        "description": table.swipeDurationDesc,
                    ],
                    "device": device,
                ], required: ["points"]),
            tool(
                "type_text", table.toolTypeText,
                ["text": ["type": "string"], "device": device], required: ["text"]),
            tool(
                "press_key",
                table.toolPressKey,
                [
                    "key": ["type": "string"], "modifiers": ["type": "array", "items": ["type": "string"]],
                    "device": device,
                ],
                required: ["key"]),
            tool(
                "keyboard_sequence",
                table.toolKeyboardSequence,
                ["steps": MCPKeyboardSequence.schema, "device": device], required: ["steps"]),
            tool("home", table.toolHome, ["device": device]),
        ]
    }

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
    /// `language` defaults to English so direct callers (tests, embeddings) stay stable.
    static func action(
        named name: String, arguments: [String: Any], longEdge: Int, language: AppLanguage = .en
    ) throws -> MCPToolRequest? {
        let device = arguments["device"] as? String
        switch name {
        case "move_pointer":
            let body = try scaled(arguments, ["x", "y"], longEdge: longEdge, language: language)
            for key in ["x", "y"] {
                guard let value = arguments[key] as? NSNumber,
                    CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite, value.doubleValue >= 0
                else {
                    throw MCPServer.MCPError(StringsMCP(language: language).coordinateFinite(key))
                }
            }
            return MCPToolRequest(path: "/move", body: body)
        case "adjust_pointer":
            var body: [String: Any] = ["click": false]
            for key in ["dx", "dy"] {
                guard let value = arguments[key] as? NSNumber,
                    CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
                    (-32...32).contains(value.doubleValue), value.doubleValue.rounded() == value.doubleValue
                else { throw MCPServer.MCPError(StringsMCP(language: language).hidCountRange(key)) }
                body[key] = value.intValue
            }
            return MCPToolRequest(path: "/nudge", body: withDevice(body, device))
        case "click_pointer":
            return MCPToolRequest(path: "/nudge", body: withDevice(["dx": 0, "dy": 0, "click": true], device))
        case "tap":
            return MCPToolRequest(
                path: "/tap", body: try scaled(arguments, ["x", "y"], longEdge: longEdge, language: language))
        case "long_press":
            var body = try scaled(arguments, ["x", "y"], longEdge: longEdge, language: language)
            body["hold"] = arguments["seconds"] ?? 1.0
            return MCPToolRequest(path: "/tap", body: body)
        case "swipe":
            var body = try scaled(arguments, ["points"], longEdge: longEdge, language: language)
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
    private static func scaled(
        _ arguments: [String: Any], _ keys: [String], longEdge: Int, language: AppLanguage
    ) throws -> [String: Any] {
        var body: [String: Any] = ["maxEdge": longEdge]
        for key in keys {
            guard let value = arguments[key] else {
                throw MCPServer.MCPError(StringsMCP(language: language).parameterRequired(key))
            }
            body[key] = value
        }
        return withDevice(body, arguments["device"] as? String)
    }

    private static func withDevice(_ body: [String: Any], _ device: String?) -> [String: Any] {
        guard let device else { return body }
        return body.merging(["device": device]) { $1 }
    }
}
