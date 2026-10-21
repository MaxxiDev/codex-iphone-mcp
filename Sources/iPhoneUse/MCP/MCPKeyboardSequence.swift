import Foundation

/// Validate the complete sequence before the server acquires locks or sends input.
enum MCPKeyboardSequence {
    static let schema: [String: Any] = [
        "type": "array", "minItems": 1, "maxItems": 16,
        "items": [
            "oneOf": [
                [
                    "type": "object", "additionalProperties": false,
                    "properties": ["text": ["type": "string", "minLength": 1, "maxLength": 256]],
                    "required": ["text"],
                ],
                [
                    "type": "object", "additionalProperties": false,
                    "properties": [
                        "key": ["type": "string", "minLength": 1],
                        "modifiers": [
                            "type": "array", "items": ["type": "string", "enum": KeyboardMap.modifiers.keys.sorted()],
                        ],
                    ],
                    "required": ["key"],
                ],
            ]
        ],
    ]

    static func actions(arguments: [String: Any], language: AppLanguage = .en) throws -> [MCPToolRequest] {
        let table = StringsMCP(language: language)
        guard Set(arguments.keys).isSubset(of: ["steps", "device"]),
            arguments["device"] == nil || arguments["device"] is String,
            let steps = arguments["steps"] as? [[String: Any]], (1...16).contains(steps.count)
        else { throw MCPServer.MCPError(table.keyboardSequenceRange) }

        var textCount = 0
        return try steps.enumerated().map { index, step in
            let label = table.kbStepLabel(index + 1)
            if let text = step["text"] as? String, Set(step.keys) == ["text"] {
                textCount += text.count
                guard !text.isEmpty, textCount <= 256,
                    text.allSatisfy({ KeyboardMap.stroke(for: $0) != nil })
                else {
                    throw MCPServer.MCPError(table.kbAscii(label))
                }
                return MCPToolRequest(path: "/type", body: ["text": text])
            }
            guard let key = step["key"] as? String,
                Set(step.keys).isSubset(of: ["key", "modifiers"]),
                // Character(String) traps for unknown multi-character names.
                KeyboardMap.named[key.lowercased()] != nil || key.count == 1,
                KeyboardMap.code(for: key) != nil,
                step["modifiers"] == nil || step["modifiers"] is [String]
            else { throw MCPServer.MCPError(table.kbExpected(label)) }
            let modifiers = step["modifiers"] as? [String] ?? []
            guard KeyboardMap.modifierMask(for: modifiers) != nil else {
                throw MCPServer.MCPError(table.kbUnknownModifier(label))
            }
            return MCPToolRequest(path: "/key", body: ["key": key, "modifiers": modifiers])
        }
    }
}
