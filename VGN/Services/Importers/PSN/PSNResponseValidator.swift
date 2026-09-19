import Foundation

/// PSN endpoint keys used for cache keys, allow-list context and validator dispatch.
enum PSNEndpoint {
    static let profile = "profile"
    static let trophyTitles = "trophyTitles"
    static let gameList = "gameList"
    static let purchases = "purchases"
}

/// Validates every PSN response against the §13.2 "not bogus" rules before anything else
/// happens to it. Reuses ``ImportResponseChecks`` for the source-agnostic gates (200 / JSON
/// / not-HTML / not-rate-limited / not-auth-challenge / no top-level `error`/`errors`
/// envelope — which also catches the GraphQL `errors[]` and persisted-query-not-found on a
/// 200) then adds PSN's schema, id-pattern, paging-coherence and suspicious-emptiness
/// rules. Pure and `Sendable`; the actor client calls it and it never touches the network.
struct PSNResponseValidator: ImportResponseValidator {

    func validate(_ response: ImportRawResponse, context: ImportValidationContext) -> ImportValidation {
        // GraphQL purchases run their own transport gates: the generic `errors`-key check
        // would falsely reject a valid `{ "data": …, "errors": null }` envelope, so the
        // GraphQL error test is done on the DTO (a non-empty `errors[]`) instead.
        if context.endpoint == PSNEndpoint.purchases {
            return validatePurchases(response, context: context)
        }
        if let reason = ImportResponseChecks.transportReject(response) {
            return .rejected(reason)
        }
        switch context.endpoint {
        case PSNEndpoint.profile:      return validateProfile(response)
        case PSNEndpoint.trophyTitles: return validateTrophyTitles(response, context: context)
        case PSNEndpoint.gameList:     return validateGameList(response, context: context)
        default:                       return .rejected(.unknown)
        }
    }

    /// Transport gates for the GraphQL endpoint, **without** the generic `error`/`errors`
    /// key check (a valid success envelope may carry `errors: null`). `nil` ⇒ gates pass.
    private func graphQLTransportReject(_ response: ImportRawResponse) -> ImportRejectReason? {
        if response.status == 429 {
            let after = response.header("Retry-After").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            return .rateLimited(retryAfter: after)
        }
        if response.status == 401 || response.status == 403 { return .authChallenge }
        guard response.status == 200 else { return .wrongStatus(response.status) }
        if ImportResponseChecks.looksLikeHTML(response) { return .loginPageOrHTML }
        if let ct = response.header("Content-Type"),
           !ct.lowercased().contains("json"), !ct.lowercased().contains("text/plain") {
            return .notJSON
        }
        if (try? JSONSerialization.jsonObject(with: response.body)) == nil { return .notJSON }
        return nil
    }

    // MARK: - Profile

    private func validateProfile(_ response: ImportRawResponse) -> ImportValidation {
        guard let profile = try? PSNJSON.decoder.decode(PSNProfile.self, from: response.body) else {
            return .rejected(.schemaMismatch)
        }
        // A profile that is mine carries at least an online id or account id.
        guard profile.onlineId != nil || profile.accountId != nil else {
            return .rejected(.schemaMismatch)
        }
        return .valid(itemCount: 1)
    }

    // MARK: - Trophy titles

    private func validateTrophyTitles(_ response: ImportRawResponse,
                                      context: ImportValidationContext) -> ImportValidation {
        guard let page = try? PSNJSON.decoder.decode(PSNTrophyTitlesPage.self, from: response.body) else {
            return .rejected(.schemaMismatch)
        }
        // Totals coherent: never fewer total than the items on this page.
        if page.totalItemCount < page.trophyTitles.count { return .rejected(.incoherentPaging) }
        // Ids: NPWR communication-id pattern, unique within the page and across pages.
        var within = Set<String>()
        for title in page.trophyTitles {
            guard Self.isCommunicationID(title.npCommunicationId) else { return .rejected(.schemaMismatch) }
            guard (0...100).contains(title.progress) else { return .rejected(.schemaMismatch) }
            if !within.insert(title.npCommunicationId).inserted { return .rejected(.incoherentPaging) }
            if context.seenIDs.contains(title.npCommunicationId) { return .rejected(.incoherentPaging) }
        }
        // Empty page where the totals promise more, or where the last cache had items.
        if page.trophyTitles.isEmpty {
            if page.totalItemCount > context.seenIDs.count { return .rejected(.incoherentPaging) }
            if (context.previousItemCount ?? 0) >= 1 { return .rejected(.suspiciouslyEmpty) }
        }
        return .valid(itemCount: page.trophyTitles.count)
    }

    // MARK: - Game list

    private func validateGameList(_ response: ImportRawResponse,
                                  context: ImportValidationContext) -> ImportValidation {
        guard let page = try? PSNJSON.decoder.decode(PSNGameListPage.self, from: response.body) else {
            return .rejected(.schemaMismatch)
        }
        if page.totalItemCount < page.titles.count { return .rejected(.incoherentPaging) }
        var within = Set<String>()
        for title in page.titles {
            guard Self.isTitleID(title.titleId) else { return .rejected(.schemaMismatch) }
            if !within.insert(title.titleId).inserted { return .rejected(.incoherentPaging) }
            if context.seenIDs.contains(title.titleId) { return .rejected(.incoherentPaging) }
        }
        if page.titles.isEmpty {
            if page.totalItemCount > context.seenIDs.count { return .rejected(.incoherentPaging) }
            if (context.previousItemCount ?? 0) >= 1 { return .rejected(.suspiciouslyEmpty) }
        }
        return .valid(itemCount: page.titles.count)
    }

    // MARK: - Purchases (GraphQL)

    private func validatePurchases(_ response: ImportRawResponse,
                                   context: ImportValidationContext) -> ImportValidation {
        if let reason = graphQLTransportReject(response) { return .rejected(reason) }
        guard let envelope = try? PSNJSON.decoder.decode(PSNPurchasedGamesEnvelope.self, from: response.body) else {
            return .rejected(.schemaMismatch)
        }
        // A non-empty GraphQL `errors[]` (e.g. persisted-query-not-found) is a reject.
        if let errors = envelope.errors, !errors.isEmpty { return .rejected(.errorEnvelope) }
        guard let games = envelope.data?.purchasedTitlesRetrieve?.games else {
            return .rejected(.schemaMismatch)
        }
        // Duplicate entitlement ids across the page.
        var within = Set<String>()
        for game in games {
            if let id = game.stableExternalID {
                if !within.insert(id).inserted { return .rejected(.incoherentPaging) }
                if context.seenIDs.contains(id) { return .rejected(.incoherentPaging) }
            }
        }
        // A brand-new account's empty purchases list is valid; empty where the last valid
        // cache had items is suspicious (PLAN §13.2 / §13.3 "Accounts for the build").
        if games.isEmpty, (context.previousItemCount ?? 0) >= 1 {
            return .rejected(.suspiciouslyEmpty)
        }
        return .valid(itemCount: games.count)
    }

    // MARK: - Id patterns (PLAN §13.2)

    /// Trophy communication id — `NPWR12345_00` shape (starts `NPWR`, then digits + `_`).
    static func isCommunicationID(_ id: String) -> Bool {
        guard id.hasPrefix("NPWR") else { return false }
        let rest = id.dropFirst(4)
        return rest.contains { $0.isNumber }
    }

    /// PS4/PS5 title id — four uppercase letters then digits (`CUSA12345_00`, `PPSA01234`).
    /// Tolerant of the region/`_00` suffix; only the prefix shape is checked.
    static func isTitleID(_ id: String) -> Bool {
        let prefix = id.prefix(4)
        guard prefix.count == 4, prefix.allSatisfy({ $0.isUppercase && $0.isLetter }) else { return false }
        return id.dropFirst(4).contains { $0.isNumber }
    }
}
