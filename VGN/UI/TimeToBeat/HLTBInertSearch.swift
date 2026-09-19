import Foundation

/// The no-network HLTB search used in sample / seeded / test modes (PLAN §5.3 — like
/// `InertImportBackend`): it never touches the network and always returns no
/// candidates, so the whole HLTB UI is exercisable offline (every game resolves to
/// "not found"). Live mode injects the real ``HLTBClient`` instead.
struct HLTBInertSearch: HLTBSearching {
    func search(title: String) async throws -> [HLTBCandidate] { [] }
}
