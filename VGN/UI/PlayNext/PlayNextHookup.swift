import Foundation

// App-level hookup for Play Next (PLAN §7b), kept here so the container only needs one line.

/// Builds the `claude` runner per request from the current Photo Scan settings (binary
/// override), so changing the path in Settings takes effect without relaunching. The
/// session cache lives in `PlayNextModel`, so a provider per call loses nothing.
struct SettingsBackedSecondOpinionProvider: SecondOpinionProviding {
    func secondOpinion(for request: SecondOpinionRequest) async throws -> SecondOpinion {
        let settings = UserDefaultsPhotoScanPreferences().load()
        let override = settings.binaryOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = ClaudeSecondOpinionProvider(
            runner: ClaudeProcessRunner(binaryOverride: override.isEmpty ? nil : override),
            model: nil
        )
        return try await provider.secondOpinion(for: request)
    }
}

extension PlayNextEnvironment {
    /// The live environment: stores over the app database, the shared cover loader,
    /// and the on-demand "Ask Claude" provider.
    @MainActor
    static func live(database: AppDatabase, library: LibraryStore, coverLoader: any CoverLoading,
                     viewModel: LibraryViewModel) -> PlayNextEnvironment {
        PlayNextEnvironment(
            recommendation: RecommendationStore(database),
            library: library,
            ranking: RankingStore(database),
            coverLoader: coverLoader,
            secondOpinion: SettingsBackedSecondOpinionProvider(),
            inspect: { [weak viewModel] id in
                viewModel?.selectOnly(id)
                viewModel?.showInspector()
            }
        )
    }
}
