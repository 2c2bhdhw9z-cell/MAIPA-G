import Foundation

/// Keeps connector-controlled prose out of model tool definitions while preserving the JSON
/// Schema structure needed to call the tool correctly.
enum ConnectorSchemaPolicy {
    private static let proseKeys: Set<String> = ["description", "title", "examples", "default", "$comment", "markdownDescription"]
    private static let structuralKeys: Set<String> = [
        "type", "properties", "required", "items", "enum", "const", "oneOf", "anyOf", "allOf",
        "additionalProperties", "minimum", "maximum", "minLength", "maxLength", "minItems", "maxItems",
        "pattern", "format", "$ref", "$defs", "definitions", "nullable"
    ]

    static func sanitize(_ value: JSONValue, depth: Int = 0) -> JSONValue {
        guard depth < 20 else { return ["type": "object"] }
        switch value {
        case .object(let object):
            var clean: [String: JSONValue] = [:]
            for (key, child) in object where !proseKeys.contains(key) {
                if key == "properties", case .object(let properties) = child {
                    clean[key] = .object(Dictionary(uniqueKeysWithValues: properties.prefix(200).map {
                        (String($0.key.prefix(120)), sanitize($0.value, depth: depth + 1))
                    }))
                } else if structuralKeys.contains(key) {
                    clean[key] = sanitize(child, depth: depth + 1)
                }
            }
            if clean["type"] == nil && clean["properties"] != nil { clean["type"] = "object" }
            return .object(clean)
        case .array(let values): return .array(values.prefix(200).map { sanitize($0, depth: depth + 1) })
        case .string(let text): return .string(String(text.prefix(500)))
        case .null, .bool, .number: return value
        }
    }
}
