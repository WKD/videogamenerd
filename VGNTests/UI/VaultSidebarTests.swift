import Foundation
import Testing
@testable import VGN

/// The Vault's sidebar wiring (PLAN §16): the per-source selection ids, the section's row
/// visibility (hidden at 0), and the one-time sort-key rename from the old "ROM Catalogue" id.
@Suite struct VaultSidebarTests {

    @Test func selectionIDsAreStablePerSource() {
        #expect(SidebarSelection.vault(.batocera).id == "vault:batocera")
        #expect(SidebarSelection.vault(.psn).id == "vault:psn")
        // Selections compare by source.
        #expect(SidebarSelection.vault(.batocera) != SidebarSelection.vault(.psn))
    }

    @Test func nonEmptySourcesDriveVisibility() {
        var counts = VaultSourceCounts()
        #expect(counts.nonEmptySources.isEmpty)          // both rows hidden
        #expect(counts.total == 0)

        counts.psn = 5
        #expect(counts.nonEmptySources == [.psn])        // only PS Plus shown
        #expect(counts.count(.psn) == 5)
        #expect(counts.count(.batocera) == 0)

        counts.batocera = 11_000
        #expect(counts.nonEmptySources == [.batocera, .psn])   // both, in display order
        #expect(counts.total == 11_005)
    }

    @Test func labelsAndIcons() {
        #expect(VaultSource.batocera.rowTitle == "Batocera ROMs")
        #expect(VaultSource.psn.rowTitle == "PS Plus")
        #expect(SidebarView.title(for: .vault(.psn)) == "PS Plus")
        #expect(!SidebarView.icon(for: .vault(.batocera)).isEmpty)
    }

    @Test func sortKeyMigratesFromOldRomCatalogueID() {
        let suite = "vgn-vault-sort-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Seed a sort under the OLD id ("romCatalogue").
        let old = UserDefaultsSortPreferences(defaults: defaults)
        old.setSortSetting(SortSetting(sort: .year, ascending: false), for: "romCatalogue")

        // A fresh store (its init runs the migration) sees it under the NEW id.
        let migrated = UserDefaultsSortPreferences(defaults: defaults)
        #expect(migrated.sortSetting(for: "vault:batocera") == SortSetting(sort: .year, ascending: false))
        // Old key removed.
        #expect(migrated.sortSetting(for: "romCatalogue") == nil)
    }

    @Test func migrationDoesNotClobberAnExistingNewKey() {
        let suite = "vgn-vault-sort-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = UserDefaultsSortPreferences(defaults: defaults)
        store.setSortSetting(SortSetting(sort: .title, ascending: true), for: "vault:batocera")
        // Now also seed an old key and re-init: the existing new value wins.
        defaults.set(try! JSONEncoder().encode(SortSetting(sort: .year, ascending: false)),
                     forKey: "VGNSort.romCatalogue")
        let reopened = UserDefaultsSortPreferences(defaults: defaults)
        #expect(reopened.sortSetting(for: "vault:batocera") == SortSetting(sort: .title, ascending: true))
    }
}
