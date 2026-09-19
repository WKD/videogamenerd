import Foundation

/// GOG endpoint paths used for cache keys, allow-list matching and validator dispatch.
enum GOGEndpoint {
    static let userData = "userData.json"
    static let ownedGames = "user/data/games"
    static let filteredProducts = "account/getFilteredProducts"
}

/// Validates every GOG response against the §14.2 "not bogus" rules before anything
/// else happens to it. Reuses ``ImportResponseChecks`` for the transport-level gates
/// (200 / JSON / not-HTML / not-rate-limited / not-auth-challenge) then adds the
/// GOG-specific schema, paging and emptiness rules. Pure and `Sendable`; the actor
/// client and the coordinator both call it, and it never touches the network.
struct GOGResponseValidator: ImportResponseValidator {

    func validate(_ response: ImportRawResponse, context: ImportValidationContext) -> ImportValidation {
        // Source-agnostic gates first.
        if let reason = ImportResponseChecks.transportReject(response) {
            return .rejected(reason)
        }
        switch context.endpoint {
        case GOGEndpoint.userData:      return validateUserData(response)
        case GOGEndpoint.ownedGames:    return validateOwnedGames(response, context: context)
        case GOGEndpoint.filteredProducts: return validateProductsPage(response, context: context)
        default:                        return .rejected(.unknown)
        }
    }

    // MARK: - userData.json

    private func validateUserData(_ response: ImportRawResponse) -> ImportValidation {
        guard let data = try? JSONDecoder().decode(GOGUserData.self, from: response.body) else {
            return .rejected(.schemaMismatch)
        }
        // A signed-out account (`isLoggedIn: false`) is an auth failure, never cached.
        guard data.isLoggedIn else { return .rejected(.authChallenge) }
        return .valid(itemCount: 1)
    }

    // MARK: - user/data/games (owned ids)

    private func validateOwnedGames(_ response: ImportRawResponse,
                                    context: ImportValidationContext) -> ImportValidation {
        guard let data = try? JSONDecoder().decode(GOGOwnedGames.self, from: response.body) else {
            return .rejected(.schemaMismatch)
        }
        if data.owned.isEmpty, (context.previousItemCount ?? 0) >= 1 {
            return .rejected(.suspiciouslyEmpty)
        }
        return .valid(itemCount: data.owned.count)
    }

    // MARK: - getFilteredProducts (library page)

    private func validateProductsPage(_ response: ImportRawResponse,
                                      context: ImportValidationContext) -> ImportValidation {
        guard let page = try? JSONDecoder().decode(GOGProductsPage.self, from: response.body) else {
            return .rejected(.schemaMismatch)
        }
        // Page must echo the requested page.
        if let expected = context.expectedPage, page.page != expected {
            return .rejected(.incoherentPaging)
        }
        // Totals must be constant across pages.
        if let total = context.expectedTotalPages, page.totalPages != total {
            return .rejected(.incoherentPaging)
        }
        if let total = context.expectedTotalProducts, page.totalProducts != total {
            return .rejected(.incoherentPaging)
        }
        // No duplicate ids within the page or against earlier pages.
        var within = Set<String>()
        for product in page.products {
            let id = String(product.id)
            if !within.insert(id).inserted { return .rejected(.incoherentPaging) }
            if context.seenIDs.contains(id) { return .rejected(.incoherentPaging) }
        }
        // Empty page where totals promise products, or where the last cache had items.
        if page.products.isEmpty {
            if page.totalProducts > 0 && page.page <= page.totalPages {
                return .rejected(.incoherentPaging)
            }
            if (context.previousItemCount ?? 0) >= 1 {
                return .rejected(.suspiciouslyEmpty)
            }
        }
        return .valid(itemCount: page.products.count)
    }

    // MARK: - Cross-page checks (coordinator-level)

    /// Σ products across pages must equal `totalProducts` (PLAN §14.2). Checked once the
    /// last page is in.
    static func sumMatchesTotal(seenCount: Int, totalProducts: Int) -> Bool {
        seenCount == totalProducts
    }

    /// The owned-ids ↔ pages cross-check: product ids that are **not** in the owned-id
    /// list (PLAN §14.2 — "reported, not fatal"). Empty ⇒ fully consistent.
    static func ownedGap(pageIDs: [Int64], ownedIDs: Set<Int64>) -> [Int64] {
        pageIDs.filter { !ownedIDs.contains($0) }
    }
}
