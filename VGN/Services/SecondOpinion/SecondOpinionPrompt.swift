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
        if request.kind == .vault { return buildVault(for: request) }
        var lines: [String] = []

        lines.append("""
        You are helping a player decide which game from their own backlog to play next. \
        Re-rank ONLY the candidates listed below for this player and time budget. Be concrete \
        about pacing, tone and difficulty. You may re-order the candidates, but you must NEVER \
        invent games and must NEVER add ids that are not in the shortlist. Answer with the \
        shortlist ids only.
        """)

        appendBudgetAndTaste(request, to: &lines)

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

    /// The time budget + the player's tier list + "didn't click" — identical for the regular
    /// picks and the "From the vault" variant.
    private static func appendBudgetAndTaste(_ request: SecondOpinionRequest, to lines: inout [String]) {
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
    }

    // MARK: - "From the vault" variant (PLAN §7b, scheduled 2026-09-25)

    /// The vault prompt: the same tier list, then the vault shortlist — each candidate's title,
    /// platform/system, source (ROM / PS Plus claim / owned, not in backlog), IGDB genres /
    /// themes / year / rating when matched, the time estimate, and "leaves with PS Plus in N
    /// months" for a claim. An **unmatched** entry is sent with title + system only, and Claude
    /// is told it may say it doesn't know such a game. Same response schema; re-order, never add.
    static func buildVault(for request: SecondOpinionRequest) -> String {
        var lines: [String] = []

        lines.append("""
        You are helping a player pick a game to try from their "vault": games they can already \
        play but never put on their backlog — ROMs on their retro console, PlayStation Plus \
        catalogue games they claimed, and games they own but set aside. Re-rank ONLY the \
        candidates listed below for this player and time budget. Be concrete about pacing, tone, \
        difficulty and how well an older game has aged. You may re-order the candidates, but you \
        must NEVER invent games and must NEVER add ids that are not in the shortlist. Answer with \
        the shortlist ids only.
        """)
        if request.shortlist.contains(where: { $0.known == false }) {
            lines.append("")
            lines.append("""
            Some candidates are given with only a title and a system (no catalogue data). If you \
            do not recognise one of those games, say so plainly in its reason or leave it out — \
            never guess what it is.
            """)
        }

        appendBudgetAndTaste(request, to: &lines)

        lines.append("")
        lines.append("VAULT CANDIDATES TO RE-RANK (use these ids only):")
        for game in request.shortlist {
            lines.append("  id \(game.id): \(game.title) — \(vaultFacts(game)) (engine rank \(game.engineRank))")
        }

        lines.append("")
        lines.append("The engine's current order (best first) is: "
            + request.engineOrdering.map(String.init).joined(separator: ", ") + ".")

        lines.append("")
        lines.append("""
        Return an ordered list of up to 5 picks (best first), each with the candidate id, a \
        1–2 sentence reason grounded in what this player ranked highly, and an optional caveat \
        (for example "aged controls", "Japanese-only text", "needs the first game"). Include \
        only ids from the shortlist above.
        """)

        return lines.joined(separator: "\n")
    }

    /// One vault candidate's facts line. Unmatched → the system only (plus a marker).
    static func vaultFacts(_ game: SecondOpinionRequest.Shortlisted) -> String {
        let system = game.platform ?? "unknown system"
        if game.known == false {
            return "\(system) (title and system only)"
        }
        var facts: [String] = [system]
        if let source = game.vaultSource { facts.append(source) }
        if let months = game.leavesPSPlusInMonths {
            facts.append(months <= 0 ? "leaves with PS Plus this month"
                         : "leaves with PS Plus in \(months) month\(months == 1 ? "" : "s")")
        }
        if let year = game.year { facts.append(String(year)) }
        if let genres = game.genres, !genres.isEmpty { facts.append("genres: " + genres.joined(separator: ", ")) }
        if let themes = game.themes, !themes.isEmpty { facts.append("themes: " + themes.joined(separator: ", ")) }
        if let rating = game.rating { facts.append("IGDB rating \(Int(rating.rounded()))") }
        if let hours = game.estimateHours { facts.append("≈ \(trimHours(hours)) h") }
        return facts.joined(separator: ", ")
    }

    /// Trim a trailing ".0" so "20.0" reads "20".
    private static func trimHours(_ hours: Double) -> String {
        if hours == hours.rounded() { return String(Int(hours)) }
        return String(hours)
    }
}
