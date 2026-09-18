import Foundation

/// The one reviewable place the "Ask Claude" prompt and its JSON schema live
/// (PLAN §7b). Everything the prompt says is built **only** from the
/// ``SecondOpinionRequest`` — the tier list, the "didn't click" titles, the
/// shortlist and the bracket. No other library data can leak in, by construction.
enum SecondOpinionPrompt {

    // MARK: - Schema (structured output)

    /// The `--json-schema` contract: an ordered list of at most five picks, each a
    /// shortlist id with a short reason and an optional caveat.
    static let schema = """
    {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "picks": {
          "type": "array",
          "maxItems": 5,
          "items": {
            "type": "object",
            "additionalProperties": false,
            "properties": {
              "id": { "type": "integer", "description": "A candidate id from the shortlist. Never invent ids." },
              "reason": { "type": "string", "description": "1–2 sentences: why this game, for this player and time budget. Be concrete about pacing, tone, difficulty." },
              "caveat": { "type": "string", "description": "Optional single caveat, e.g. 'slow first 10 hours' or 'needs the first game'." }
            },
            "required": ["id", "reason"]
          }
        }
      },
      "required": ["picks"]
    }
    """

    /// The decoded structured payload.
    struct Response: Decodable, Sendable {
        struct Pick: Decodable, Sendable {
            var id: Int64
            var reason: String
            var caveat: String?
        }
        var picks: [Pick]
    }

    // MARK: - Prompt

    /// Build the full instruction prompt from the request. Deterministic given the
    /// request, so tests can assert exactly what is (and is not) sent.
    static func build(for request: SecondOpinionRequest) -> String {
        var lines: [String] = []

        lines.append("""
        You are helping a player decide which game from their own backlog to play next. \
        Re-rank ONLY the candidates listed below for this player and time budget. Be concrete \
        about pacing, tone and difficulty. You may re-order the candidates, but you must NEVER \
        invent games and must NEVER add ids that are not in the shortlist. Answer with the \
        shortlist ids only.
        """)

        lines.append("")
        lines.append("TIME BUDGET: \(request.bracket)\(request.completionist ? " (aiming to complete games 100%)" : "")")

        // Tier list — the player's own taste, best first.
        if !request.topRanked.isEmpty {
            lines.append("")
            lines.append("THE PLAYER'S TIER LIST (their own ranking, best first — tier in brackets):")
            for game in request.topRanked {
                lines.append("  \(game.globalPosition). \(game.title) [\(game.tier)]")
            }
        }

        // Didn't click.
        if !request.didntClick.isEmpty {
            lines.append("")
            lines.append("GAMES THEY DIDN'T CLICK WITH (ranked low):")
            for game in request.didntClick {
                lines.append("  - \(game.title) [\(game.tier)]")
            }
        }

        // Shortlist — the only games Claude may name.
        lines.append("")
        lines.append("CANDIDATES TO RE-RANK (use these ids only):")
        for game in request.shortlist {
            var facts: [String] = []
            if let platform = game.platform { facts.append(platform) }
            if let hours = game.estimateHours { facts.append("≈ \(trimHours(hours)) h") }
            if let status = game.status { facts.append(status) }
            let suffix = facts.isEmpty ? "" : " — \(facts.joined(separator: ", "))"
            lines.append("  id \(game.id): \(game.title)\(suffix) (engine rank \(game.engineRank))")
        }

        // Engine's own order, for reference.
        lines.append("")
        lines.append("The engine's current order (hero first) is: "
            + request.engineOrdering.map(String.init).joined(separator: ", ") + ".")

        lines.append("")
        lines.append("""
        Return an ordered list of up to 5 picks (best first), each with the candidate id, a \
        1–2 sentence reason grounded in what this player ranked highly, and an optional caveat. \
        Include only ids from the shortlist above.
        """)

        return lines.joined(separator: "\n")
    }

    /// Trim a trailing ".0" so "20.0" reads "20".
    private static func trimHours(_ hours: Double) -> String {
        if hours == hours.rounded() { return String(Int(hours)) }
        return String(hours)
    }
}
