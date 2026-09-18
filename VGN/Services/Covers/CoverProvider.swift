import Foundation

/// PLAN §5.2 provider protocol: given a `CoverQuery`, return ordered cover
/// candidates (best first). Providers fail soft — a network or lookup failure yields
/// an empty list, never a throw, so the chain always makes progress.
protocol CoverProvider: Sendable {
    var id: String { get }
    func candidates(for query: CoverQuery) async -> [CoverCandidate]
}
