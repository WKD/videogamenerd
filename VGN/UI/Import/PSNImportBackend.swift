import Foundation
import GRDB

/// Wraps the real PSN objects (``PSNAuth`` actor, ``PSNImporter``, coordinator, matcher,
/// cache) into the shared ``ImportBackend`` seam (PLAN §13). Built **only in live mode**
/// by ``PSNImportBuilder``; every other mode uses the shared ``InertImportBackend`` so
/// nothing PSN touches the network or the Keychain. Mirrors ``LiveGOGImportBackend``.
///
/// The seam's `completeSignIn(code:)` carries an **NPSSO** for PSN (the login sheet reads
/// it from the web view's cookie store, or the owner pastes it) — ``PSNAuth`` exchanges it
/// for OAuth tokens. The NPSSO is never logged.
struct LivePSNImportBackend: ImportBackend {
    let auth: PSNAuth
    let importer: PSNImporter
    let coordinator: ImportSyncCoordinator
    let matcher: any ImportMatcher
    let cache: ImportResponseCacheStore
    let staging: ImportStagingStore
    /// Expands a bundle/pack match into its member games during matching (PLAN §13.3 "PSN bundles
    /// expand too"); nil when IGDB is not configured, so a bundle simply commits as a single.
    var bundleExpander: (any ImportBundleExpanding)? = nil

    var source: String { ImportSourceID.psn }
    var sourceLabel: String { "PlayStation" }
    var dataSets: [ImportDataSet] { importer.dataSets }
    /// Re-match uses the sync matcher, except a no-match one (IGDB not configured) hides it.
    var rematchMatcher: (any ImportMatcher)? { matcher is NoMatchImportMatcher ? nil : matcher }

    func hasSession() async -> Bool { await auth.hasSession() }

    /// The signed-in **online id** (never the account id). Read from the cached profile.
    func username() async -> String? {
        guard let record = try? await cache.entry(source: source, key: PSNEndpoint.profile),
              let profile = try? PSNJSON.decoder.decode(PSNProfile.self, from: record.body) else { return nil }
        return profile.onlineId
    }

    func cacheAges() async -> [ImportCacheAge] {
        (try? await cache.ages(source: source)) ?? []
    }

    /// `code` carries the NPSSO (cookie value or a pasted string).
    func completeSignIn(code: String) async throws {
        try await auth.completeSignIn(npsso: code)
    }

    func signOut(alsoWipeCache: Bool) async throws {
        try await auth.signOut()
        if alsoWipeCache { try await cache.wipe(source: source) }
    }

    func forceRefresh(dataSetID: String?) async throws {
        guard let dataSetID else {
            try await cache.wipe(source: source)
            return
        }
        // Drop just this data set's cached response rows so the next sync re-fetches only it
        // (PLAN §13.5). profile is a single key; trophyTitles / gameList / purchases are
        // paged (keys prefixed by the endpoint). A LIKE-prefix delete covers both, and the
        // `probe:*` markers (a different prefix) survive, so a probe is not lost.
        let src = source
        try await cache.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM import_cache WHERE source = ? AND key LIKE ?",
                           arguments: [src, "\(dataSetID)%"])
        }
    }

    func runSync(onProgress: @Sendable @escaping (ImportProgress) -> Void) async throws -> ImportSyncResult {
        try await coordinator.run(importer, matcher: matcher, bundleExpander: bundleExpander,
                                  onProgress: onProgress)
    }
}
