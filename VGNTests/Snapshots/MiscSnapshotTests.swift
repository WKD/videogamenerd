#if DEBUG
import SwiftUI
import Testing
@testable import VGN

/// Settings, the compilation editor, ownership/copy-removal sheets, the stats
/// popover, the database-error screen and the small shared components.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct MiscSnapshotTests {
    private let settingsGroup = "07 Settings"
    private let sheetsGroup = "08 Sheets & Popovers"
    private let compGroup = "09 Compilations"
    private let compsGroup = "10 Components"

    // MARK: Settings

    @Test func settings() async {
        let model = SettingsModel(secretStore: InMemorySecretStore(seed: [.igdbClientID: "abc123"]))
        await SnapshotHarness.settle(rounds: 3)
        await SnapshotHarness.capture(group: settingsGroup, "settings-accounts",
                                      size: SnapSize(width: 560, height: 440)) {
            SettingsView(model: model)
        }
    }

    @Test func photoScanSettings() async {
        await SnapshotHarness.capture(group: settingsGroup, "settings-photo-scan",
                                      size: SnapSize(width: 560, height: 460)) {
            PhotoScanSettingsTab().frame(width: 500, height: 420)
        }
    }

    // MARK: Compilation editor

    @Test func compilationEditor() async {
        let model = PreviewCompilationEditor.mgsLegacy()
        await model.load()
        await SnapshotHarness.settle(rounds: 4)
        await SnapshotHarness.capture(group: compGroup, "compilation-editor",
                                      size: SnapSize(width: 640, height: 620)) {
            CompilationEditorView(model: model)
        }
    }

    // MARK: Ownership sheets

    private var somePlatforms: [PlatformInfo] {
        let want: Set<String> = ["ps5", "ps4", "ps3", "ps2", "pc", "switch"]
        return PlatformLabels.all.filter { want.contains($0.id) }
    }

    @Test func ownershipPicker() async {
        let request = OwnershipRequest(
            gameID: 1, title: "Elden Ring",
            gamePlatforms: somePlatforms.filter { ["ps5", "ps4"].contains($0.id) },
            allPlatforms: somePlatforms,
            perform: { _, _ in })
        await SnapshotHarness.capture(group: sheetsGroup, "sheet-ownership",
                                      size: SnapSize(width: 460, height: 360)) {
            OwnershipPickerSheet(request: request, onClose: {})
        }
    }

    @Test func copyRemoval() async {
        let request = CopyRemovalRequest(
            title: "Metal Gear Solid 2",
            copies: [
                .init(productID: 1, label: "PS2 · Physical", isCompilation: false, compilationMembers: []),
                .init(productID: 2, label: "Part of Metal Gear Solid: The Legacy Collection (PS3)",
                      isCompilation: true,
                      compilationMembers: ["Metal Gear Solid 2", "Metal Gear Solid 3", "Metal Gear Solid 4"]),
            ],
            perform: { _ in })
        await SnapshotHarness.capture(group: sheetsGroup, "sheet-copy-removal",
                                      size: SnapSize(width: 500, height: 420)) {
            CopyRemovalSheet(request: request, onClose: {})
        }
    }

    @Test func groupCompilation() async {
        let request = GroupCompilationRequest(
            games: [(id: 1, title: "Ico"), (id: 2, title: "Shadow of the Colossus")],
            platforms: somePlatforms.filter { ["ps3", "ps2"].contains($0.id) },
            perform: { _, _, _, _ in })
        await SnapshotHarness.capture(group: sheetsGroup, "sheet-group-compilation",
                                      size: SnapSize(width: 480, height: 400)) {
            GroupCompilationSheet(request: request, onClose: {})
        }
    }

    // MARK: Stats popover

    @Test func statsPopover() async {
        await SnapshotHarness.capture(group: sheetsGroup, "stats-popover",
                                      size: SnapSize(width: 420, height: 520), settle: 3) {
            LibraryStatsPopover(
                stats: LibraryStats(
                    total: 812, owned: 540, played: 655, backlog: 157, totalPlaytimeSeconds: 1_240 * 3600,
                    byPlatform: [
                        .init(platformID: "ps4", count: 210), .init(platformID: "ps2", count: 140),
                        .init(platformID: "pc", count: 120), .init(platformID: "snes", count: 80),
                        .init(platformID: "ps5", count: 62),
                    ],
                    byTier: [
                        .init(tierID: 1, letter: "S", count: 20), .init(tierID: 2, letter: "A", count: 55),
                        .init(tierID: 3, letter: "B", count: 120), .init(tierID: 4, letter: "C", count: 90),
                        .init(tierID: 5, letter: "D", count: 30), .init(tierID: 6, letter: "F", count: 8),
                    ]),
                tiers: TierInfo.defaultTiers)
        }
    }

    // MARK: Database error

    @Test func databaseError() async {
        await SnapshotHarness.capture(group: sheetsGroup, "database-error",
                                      size: SnapSize(width: 640, height: 480)) {
            DatabaseErrorView(failure: .init(
                message: "The library file exists but is not a valid SQLite database. It may be from a newer version of VGN, or corrupted.",
                path: "~/Library/Application Support/VGN/vgn.sqlite"))
        }
    }

    // MARK: Small components

    @Test func components() async {
        await SnapshotHarness.capture(group: compsGroup, "components-chips",
                                      size: SnapSize(width: 340, height: 160), settle: 3) {
            VStack(spacing: 12) {
                HStack {
                    TierChip(letter: "S", colorHex: "#FF3B30")
                    TierChip(letter: "A", colorHex: "#FF9500")
                    TierChip(letter: "F", colorHex: "#8E8E93")
                }
                HStack {
                    PlatformChip(slug: "ps5")
                    PlatformChip(slug: "snes")
                    PlatformChip(slug: "pc")
                }
            }
            .padding()
        }
    }

    @Test func placeholderCovers() async {
        await SnapshotHarness.capture(group: compsGroup, "components-placeholders",
                                      size: SnapSize(width: 420, height: 240), settle: 3) {
            HStack(spacing: 12) {
                PlaceholderCover(title: "Bloodborne", platformID: "ps4")
                PlaceholderCover(title: "Metal Gear Solid 3: Snake Eater", platformID: "ps2")
                PlaceholderCover(title: "Ico", platformID: "ps2")
            }
            .frame(height: 200).padding()
        }
    }

    @Test func rankingCovers() async {
        await SnapshotHarness.capture(group: compsGroup, "components-ranking-covers",
                                      size: SnapSize(width: 420, height: 400), settle: 4) {
            HStack(spacing: 16) {
                RankingCoverView(title: "Bloodborne", platformID: "ps4", loader: NoopCoverLoader())
                RankingCoverView(title: "Metal Gear Solid 3", platformID: "ps2", loader: NoopCoverLoader())
            }
            .frame(height: 360).padding()
        }
    }
}
#endif
