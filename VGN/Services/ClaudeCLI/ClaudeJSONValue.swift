import Foundation

/// A minimal, `Codable` representation of an arbitrary JSON value. Used by the
/// `claude` CLI envelope decoder to carry the `structured_output` payload (whose
/// shape is caller-defined) so it can be re-encoded and decoded into the caller's
/// concrete `Decodable` type. Deliberately local to `ClaudeCLI/` and generic — it
/// has no recognition knowledge.
enum ClaudeJSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ClaudeJSONValue])
    case object([String: ClaudeJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ClaudeJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ClaudeJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Re-encode this value to JSON bytes so a caller can decode a concrete type.
    func encodedData() throws -> Data {
        try JSONEncoder().encode(self)
    }
}
