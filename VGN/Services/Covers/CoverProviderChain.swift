import Foundation

/// Runs cover providers in order (PLAN §5.2: libretro first for platforms with a
/// repo, then the IGDB fallback), returning **all** candidates for the "Choose Cover…"
/// sheet while letting the caller take the first confident hit. "First good hit wins"
/// is expressed by `bestConfident` / the order of `allCandidates`.
struct CoverProviderChain: Sendable {
    let providers: [any CoverProvider]

    init(providers: [any CoverProvider]) {
        self.providers = providers
    }

    /// Convenience: the standard chain — libretro (retro platforms) then IGDB.
    init(catalog: PlatformCatalog, listing: LibretroRepoListing, igdbSize: IGDBImageSize = .coverBig2x) {
        self.providers = [
            LibretroCoverProvider(catalog: catalog, listing: listing),
            IGDBCoverProvider(size: igdbSize),
        ]
    }

    /// Result of running the chain: candidates in provider order (each provider's own
    /// best first), and the first confident one if any. `hadTransientFailure` is set
    /// when a provider could not reach its source — so an empty candidate list must
    /// not be treated (and negatively cached) as a genuine miss.
    struct Result: Sendable, Equatable {
        var allCandidates: [CoverCandidate]
        var bestConfident: CoverCandidate?
        var hadTransientFailure: Bool = false
    }

    /// Run every provider and collect candidates. Providers are queried in order; the
    /// first confident hit short-circuits the remaining providers (PLAN "first good
    /// hit wins") but earlier providers' plausible candidates are still returned.
    func run(_ query: CoverQuery) async -> Result {
        var all: [CoverCandidate] = []
        var best: CoverCandidate?
        var transient = false
        for provider in providers {
            let probe = await provider.probe(for: query)
            if probe.isTransientFailure { transient = true; continue }
            let candidates = probe.candidates
            all.append(contentsOf: candidates)
            if best == nil, let confident = candidates.first(where: { $0.isConfident }) {
                best = confident
                break   // good hit — stop hitting further providers
            }
        }
        return Result(allCandidates: all, bestConfident: best, hadTransientFailure: transient)
    }
}
