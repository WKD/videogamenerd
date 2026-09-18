import Foundation

/// The live "Ask Claude" provider (PLAN §7b). Builds the prompt from the request
/// only, runs the shared headless `claude` CLI in structured mode with **no tools**
/// (there is nothing to read), validates the answer against the shortlist, and maps
/// every CLI failure to a friendly ``SecondOpinionError``.
///
/// It never touches the database or the network directly — the only data it sees is
/// the ``SecondOpinionRequest`` handed to it, and the only side effect is spending
/// the signed-in subscription's usage. A drop-in for an API-key variant later.
struct ClaudeSecondOpinionProvider: SecondOpinionProviding {
    let runner: any ClaudeCLIRunning
    /// Optional model override; nil uses the CLI default (PLAN §6.2).
    let model: String?

    init(runner: any ClaudeCLIRunning, model: String? = nil) {
        self.runner = runner
        self.model = model
    }

    func secondOpinion(for request: SecondOpinionRequest) async throws -> SecondOpinion {
        let prompt = SecondOpinionPrompt.build(for: request)
        let options = ClaudeRunOptions(model: model, maxTurns: 1,
                                       permissionMode: "dontAsk", timeout: 90)
        let allowedIDs = Set(request.shortlist.map(\.id))

        let raw: [SecondOpinionPrompt.Response.Pick]
        let metrics: ClaudeRunMetrics
        do {
            let run = try await runner.runStructured(
                SecondOpinionPrompt.Response.self,
                prompt: prompt,
                schema: SecondOpinionPrompt.schema,
                allowedTools: [],                 // no tools — nothing to read (PLAN §7b)
                files: [],
                options: options)
            raw = run.value.picks
            metrics = run.metrics
        } catch let error as ClaudeCLIError {
            // The structured entry point works with an empty tool list on the
            // installed CLI. Only if the schema path returns something unreadable do
            // we fall back to a plain text call and parse a fenced JSON block.
            if case .malformedOutput = error {
                return try await textFallback(prompt: prompt, options: options, allowedIDs: allowedIDs)
            }
            throw SecondOpinionError.from(error)
        } catch {
            throw SecondOpinionError.wrap(error)
        }

        return try Self.validate(raw, allowedIDs: allowedIDs, model: metrics.model ?? model, metrics: metrics)
    }

    // MARK: - Text fallback

    private func textFallback(
        prompt: String, options: ClaudeRunOptions, allowedIDs: Set<Int64>
    ) async throws -> SecondOpinion {
        do {
            let run = try await runner.runText(prompt: prompt, options: options)
            guard let json = Self.extractJSONObject(from: run.value),
                  let data = json.data(using: .utf8),
                  let response = try? JSONDecoder().decode(SecondOpinionPrompt.Response.self, from: data) else {
                throw SecondOpinionError.failed("Claude Code returned output that could not be read.")
            }
            return try Self.validate(response.picks, allowedIDs: allowedIDs,
                                     model: run.metrics.model ?? model, metrics: run.metrics)
        } catch let error as ClaudeCLIError {
            throw SecondOpinionError.from(error)
        } catch {
            throw SecondOpinionError.wrap(error)
        }
    }

    // MARK: - Validation (foreign ids discarded, dupes dropped, ≤ 5, trimmed)

    static func validate(
        _ raw: [SecondOpinionPrompt.Response.Pick],
        allowedIDs: Set<Int64>,
        model: String?,
        metrics: ClaudeRunMetrics?
    ) throws -> SecondOpinion {
        var seen = Set<Int64>()
        var picks: [SecondOpinion.Pick] = []
        for pick in raw {
            guard allowedIDs.contains(pick.id) else { continue }   // never add ids
            guard seen.insert(pick.id).inserted else { continue }  // drop duplicates
            let reason = pick.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            let caveat = pick.caveat?.trimmingCharacters(in: .whitespacesAndNewlines)
            picks.append(SecondOpinion.Pick(
                gameID: pick.id,
                reason: reason,
                caveat: (caveat?.isEmpty ?? true) ? nil : caveat))
            if picks.count == 5 { break }                          // at most five
        }
        guard !picks.isEmpty else { throw SecondOpinionError.empty }
        return SecondOpinion(picks: picks, model: model, metrics: metrics)
    }

    // MARK: - JSON extraction (defensive text-fallback parsing)

    /// Pull the first balanced top-level `{ … }` object out of free text (tolerates
    /// ```json fences and surrounding prose).
    static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let ch = text[index]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else {
                switch ch {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return String(text[start...index]) }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
