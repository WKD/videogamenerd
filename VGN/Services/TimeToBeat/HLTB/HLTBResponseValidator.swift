import Foundation

/// Validates one HLTB **search** response (PLAN §5.3 — stop on the first unexpected
/// response). Reuses the source-agnostic transport gates (429 / 403 / wrong status /
/// HTML-or-captcha / not-JSON / error envelope) and adds the one HLTB-specific check:
/// the JSON must decode into the `{ data: [...] }` search envelope, else it is a
/// schema mismatch. On success the item count is the number of candidates.
struct HLTBResponseValidator: ImportResponseValidator {
    func validate(_ response: ImportRawResponse, context: ImportValidationContext) -> ImportValidation {
        if let reason = ImportResponseChecks.transportReject(response) {
            return .rejected(reason)
        }
        // Body is 200 + JSON — must be the search envelope.
        guard HLTBEndpoint.looksLikeSearchResponse(response.body) else {
            return .rejected(.schemaMismatch)
        }
        let count = (try? HLTBEndpoint.parseCandidates(response.body).count) ?? 0
        return .valid(itemCount: count)
    }
}
