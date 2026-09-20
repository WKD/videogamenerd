import AppKit
import SwiftUI

/// The dependency bundle the Batocera catalogue browser + Play Next "Discover" row need
/// (PLAN §15), injected through the SwiftUI environment (like ``PlayNextEnvironment``) so the
/// views never reach into the app container. Everything here reads **local** tables; the only
/// thing that ever touches the share is the thumbnail loader (read-only) and the "Show in
/// Finder" action. Built once by ``BatoceraBuilder`` and set with
/// `.environment(\.batoceraEnvironment, …)`; `nil` before wiring / in previews.
@MainActor
final class BatoceraEnvironment {
    let catalog: RomCatalogStore
    /// Reads ROM box art from the share (read-only), or a nil-root loader outside live.
    let thumbnails: BatoceraThumbnailLoader
    /// Loads remote PS Plus cover art into an in-memory cache (never the cover folder, PLAN §16).
    let vaultCovers: VaultCoverLoader
    /// The Discover data seam (ranked games + never-played pool).
    let discover: any DiscoverBackend
    /// Whether the share is reachable right now (drives "Show in Finder" + placeholders).
    let isLive: Bool

    /// Open the promotion review over a hand-picked set of catalogue ids ("Add to Library…").
    let addToLibrary: (@MainActor ([Int64]) -> Void)?
    /// Reveal a promoted game in the library inspector (the "In Library" marker).
    let inspectGame: (@MainActor (Int64) -> Void)?
    /// Select the ROM Catalogue sidebar row (Discover "Show in Catalogue").
    let showCatalogue: (@MainActor () -> Void)?
    /// The share roms root, for "Show in Finder" (nil outside live / unconfigured).
    let romsRoot: URL?
    /// The manual "Find match…" seam for PS Plus entries (PLAN §16). nil unless IGDB is configured.
    let findMatch: VaultFindMatchSeam?
    /// Opens a URL — the vault card "Open on IGDB" button (D7). Defaults to the system browser;
    /// injected in tests so nothing is opened.
    let openURL: @MainActor (URL) -> Void

    init(catalog: RomCatalogStore,
         thumbnails: BatoceraThumbnailLoader,
         vaultCovers: VaultCoverLoader = VaultCoverLoader(),
         discover: any DiscoverBackend,
         isLive: Bool,
         romsRoot: URL?,
         addToLibrary: (@MainActor ([Int64]) -> Void)? = nil,
         inspectGame: (@MainActor (Int64) -> Void)? = nil,
         showCatalogue: (@MainActor () -> Void)? = nil,
         findMatch: VaultFindMatchSeam? = nil,
         openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.catalog = catalog
        self.thumbnails = thumbnails
        self.vaultCovers = vaultCovers
        self.discover = discover
        self.isLive = isLive
        self.romsRoot = romsRoot
        self.addToLibrary = addToLibrary
        self.inspectGame = inspectGame
        self.showCatalogue = showCatalogue
        self.findMatch = findMatch
        self.openURL = openURL
    }

    /// Reveal a catalogue entry's ROM file (or its folder) in Finder, when the share is
    /// mounted. Read-only — never writes, moves or copies anything.
    func showInFinder(_ entry: RomCatalogEntry) {
        guard let romsRoot else { return }
        let url = BatoceraThumbnailLoader.resolve(romsRoot: romsRoot, system: entry.system,
                                                  relative: entry.relativePath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // The ROM itself may not be reachable; reveal its system folder instead.
            let folder = romsRoot.appendingPathComponent(entry.system, isDirectory: true)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }
}

// MARK: - Environment key

private struct BatoceraEnvironmentKey: EnvironmentKey {
    static let defaultValue: BatoceraEnvironment? = nil
}

extension EnvironmentValues {
    /// The injected Batocera catalogue dependencies, or `nil` before wiring.
    var batoceraEnvironment: BatoceraEnvironment? {
        get { self[BatoceraEnvironmentKey.self] }
        set { self[BatoceraEnvironmentKey.self] = newValue }
    }
}
