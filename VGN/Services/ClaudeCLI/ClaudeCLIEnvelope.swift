import Foundation

/// The JSON envelope printed by `claude -p --output-format json` (a single result
/// object). We decode the metadata fields we care about for the progress UI and,
/// separately, the structured payload.
///
/// Two payload shapes are handled (verified against the installed CLI, 2.1.277):
/// - With `--json-schema`, the envelope carries **both** `structured_output` (a
///   parsed JSON object) and `result` (its string form). We prefer
///   `structured_output`.
/// - Without a schema (text calls), only `result` (a plain string) is present.
struct ClaudeCLIEnvelope: Decodable, Sendable {
    let type: String?
    let subtype: String?
    let isError: Bool
    /// The text result (present on text calls; the string form of the structured
    /// output on schema calls).
    let result: String?
    /// The parsed structured output when `--json-schema` was used.
    let structuredOutput: ClaudeJSONValue?
    let totalCostUSD: Double?
    let numTurns: Int?
    let durationMS: Int?
    let durationAPIMS: Int?
    let usage: Usage?
    let apiErrorStatus: Int?

    struct Usage: Decodable, Sendable, Equatable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadInputTokens: Int?
        let cacheCreationInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, subtype, result, usage
        case isError = "is_error"
        case structuredOutput = "structured_output"
        case totalCostUSD = "total_cost_usd"
        case numTurns = "num_turns"
        case durationMS = "duration_ms"
        case durationAPIMS = "duration_api_ms"
        case apiErrorStatus = "api_error_status"
    }

    /// Decode the envelope from raw stdout bytes, tolerating any leading/trailing
    /// noise around the JSON object (some environments prepend a line).
    static func decode(from data: Data) throws -> ClaudeCLIEnvelope {
        // Fast path: the whole buffer is the JSON object.
        if let envelope = try? JSONDecoder().decode(ClaudeCLIEnvelope.self, from: data) {
            return envelope
        }
        // Fallback: locate the last top-level `{ … }` object in the stream.
        guard let sliced = Self.lastJSONObject(in: data),
              let envelope = try? JSONDecoder().decode(ClaudeCLIEnvelope.self, from: sliced)
        else {
            let preview = String(decoding: data.prefix(400), as: UTF8.self)
            throw ClaudeCLIError.malformedOutput("could not parse CLI envelope. First 400 bytes: \(preview)")
        }
        return envelope
    }

    /// The structured payload as JSON bytes, preferring `structured_output`, falling
    /// back to the `result` string. Throws `malformedOutput` when neither is present.
    func structuredPayload() throws -> Data {
        if let structuredOutput {
            return try structuredOutput.encodedData()
        }
        if let result {
            return Data(result.utf8)
        }
        throw ClaudeCLIError.malformedOutput("envelope carried neither structured_output nor result")
    }

    /// Find the last balanced `{ … }` object in `data` (ignoring braces inside
    /// strings). Handles CLIs that emit a warning line before the JSON.
    private static func lastJSONObject(in data: Data) -> Data? {
        let bytes = [UInt8](data)
        let open = UInt8(ascii: "{")
        let close = UInt8(ascii: "}")
        let quote = UInt8(ascii: "\"")
        let backslash = UInt8(ascii: "\\")

        // Scan forward tracking depth; remember the span of the outermost object
        // that starts latest. Simpler: find the first '{' whose matching '}' ends the
        // buffer's final object. We take the earliest '{' at depth 0 that balances.
        var depth = 0
        var start: Int? = nil
        var inString = false
        var escaped = false
        var best: (Int, Int)? = nil
        for (i, byte) in bytes.enumerated() {
            if inString {
                if escaped { escaped = false }
                else if byte == backslash { escaped = true }
                else if byte == quote { inString = false }
                continue
            }
            switch byte {
            case quote: inString = true
            case open:
                if depth == 0 { start = i }
                depth += 1
            case close:
                depth -= 1
                if depth == 0, let s = start { best = (s, i) }
            default: break
            }
        }
        guard let (s, e) = best else { return nil }
        return data.subdata(in: s..<(e + 1))
    }
}
