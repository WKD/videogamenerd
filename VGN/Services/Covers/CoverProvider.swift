import Foundation

/// PLAN §5.2 provider protocol: given a `CoverQuery`, return ordered cover
/// candidates (best first). Providers fail soft — a network or lookup failure yields
/// an empty list, never a throw, so the chain always makes progress.
protocol CoverProvider: Sendable {
    var id: String { get }
    func candidates(for query: CoverQuery) async -> [CoverCandidate]

    /// **Every** candidate this provider can offer for the "Choose Cover…" sheet
    /// (PLAN §5.2 step 4) — not just the single best one `candidates(for:)` returns
    /// for the automatic path. A provider that can enumerate variants (e.g. libretro
    /// boxarts across every region) overrides this; the default returns whatever
    /// ``candidates(for:)`` produced.
    func allCandidates(for query: CoverQuery) async -> [CoverCandidate]

    /// Richer variant the chain uses to tell a genuine miss (the source was
    /// reached and had nothing) from a transient failure (the source could not be
    /// reached). Defaults to wrapping ``candidates(for:)`` as `.found`; a provider
    /// whose empty result may be a transient outage (e.g. a network listing fetch)
    /// overrides this so the negative cache is not poisoned by a blip.
    func probe(for query: CoverQuery) async -> CoverProbe
}

extension CoverProvider {
    func probe(for query: CoverQuery) async -> CoverProbe {
        .found(await candidates(for: query))
    }

    func allCandidates(for query: CoverQuery) async -> [CoverCandidate] {
        await candidates(for: query)
    }
}

/// Outcome of probing one cover provider (see ``CoverProvider/probe(for:)``).
enum CoverProbe: Sendable {
    /// The source was reached; these are its candidates (possibly empty = a
    /// genuine miss, which is safe to negatively cache).
    case found([CoverCandidate])
    /// The source could not be reached; the empty result is not a real miss and
    /// must not poison the negative cache.
    case transientFailure

    var candidates: [CoverCandidate] {
        if case let .found(c) = self { return c }
        return []
    }

    var isTransientFailure: Bool {
        if case .transientFailure = self { return true }
        return false
    }
}
