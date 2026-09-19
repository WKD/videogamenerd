import Foundation

/// Pure GOG product → staging-row mapping (PLAN §14.3). Foundation only, no I/O, so it
/// is trivially testable: platform rule, noise rules (each with a reason for the review
/// sheet), and release-year extraction for the matcher tie-breaker.
///
/// ASSUMPTION(G0): the noise heuristics below key off `isGame` / `isHidden` / `category`
/// / title keywords — the only signals `getFilteredProducts` gives without a per-game
/// `gameDetails` call (which is off the allow-list). G4/G5 confirm the real fields; the
/// reasons are deliberately conservative so nothing owned is silently dropped, only
/// moved to the restorable *Ignored* bucket.
enum GOGMapping {

    /// VGN platform slug for a product (PLAN §14.3). `mac` when `worksOn.Mac` under the
    /// default policy, else `pc`; a Linux-only title also maps to `pc`.
    static func platform(for product: GOGProduct, policy: ImportPlatformPolicy) -> String {
        switch policy {
        case .alwaysPC:
            return "pc"
        case .macWhenAvailable:
            return product.worksOn.runsOnMac ? "mac" : "pc"
        }
    }

    /// The noise reason for a product, or nil if it is an ordinary game (PLAN §14.3).
    static func ignoreReason(for product: GOGProduct) -> ImportIgnoreReason? {
        if product.isGame == false { return .notAGame }
        if product.isMovie == true { return .notAGame }
        if product.isHidden == true { return .hidden }

        let haystack = (product.title + " " + (product.category ?? "")).lowercased()

        if containsAny(haystack, Self.demoKeywords) { return .demoOrPrologue }
        if containsAny(haystack, Self.soundtrackKeywords) { return .soundtrackOrGoodies }
        if containsAny(haystack, Self.dlcKeywords) { return .dlcOrExpansion }
        return nil
    }

    /// A title that runs only on Linux (not Windows, not Mac) — it maps to `pc` with a
    /// note (PLAN §14.3). Surfaced transiently on the staging row for the review sheet.
    static func isLinuxOnly(_ product: GOGProduct) -> Bool {
        let w = product.worksOn
        return w.runsOnLinux && !w.runsOnWindows && !w.runsOnMac
    }

    /// Map one product to a staging row (owned; noise rows carry their reason). The
    /// transient `macAvailable` / `linuxOnly` flags let the review sheet re-map the
    /// platform on the policy switch and show the Linux-only note (PLAN §14.3).
    static func stagingRow(for product: GOGProduct, policy: ImportPlatformPolicy) -> ImportStagingRow {
        ImportStagingRow(
            source: ImportSourceID.gog,
            externalID: String(product.id),
            name: product.title,
            platform: platform(for: product, policy: policy),
            signals: [.owned],
            releaseYear: product.releaseDate?.year,
            ignoreReason: ignoreReason(for: product),
            macAvailable: product.worksOn.runsOnMac,
            linuxOnly: isLinuxOnly(product))
    }

    /// Map a page (or a whole library) of products to staging rows, order preserved.
    static func stagingRows(for products: [GOGProduct], policy: ImportPlatformPolicy) -> [ImportStagingRow] {
        products.map { stagingRow(for: $0, policy: policy) }
    }

    // MARK: - Keyword sets (ASSUMPTION(G0): tuned against real titles at G4/G5)

    private static let demoKeywords = ["(demo)", " demo", "prologue"]
    private static let soundtrackKeywords = ["soundtrack", "ost", "artbook", "art book",
                                             "goodies", "wallpaper", "avatars", "extras"]
    private static let dlcKeywords = ["dlc", "expansion", "season pass", "- pack"]

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}
