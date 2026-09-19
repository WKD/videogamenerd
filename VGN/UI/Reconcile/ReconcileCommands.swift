import SwiftUI

/// Menu-bar command for reconciling a game with IGDB (PLAN §5.1). Placed in the File
/// menu next to Quick Add and the importers (the app's convention for library-data
/// actions — see the GOG / Delicious / photo-scan commands), enabled for a single
/// library selection. PURE — it only reads the focused view model; the write happens in
/// the Button action, which opens the sheet.
struct ReconcileCommands: Commands {
    @FocusedValue(\.library) private var library

    var body: some Commands {
        CommandGroup(after: .newItem) {
            let single: Int64? = (library?.selectedGameIDs.count == 1) ? library?.selectedGameIDs.first : nil
            let isLinked = library?.selectedDetail?.igdbID != nil
            Button(isLinked ? "Change IGDB Match…" : "Link to IGDB…") {
                if let single { library?.requestLinkToIGDB(gameID: single) }
            }
            .disabled(single == nil)
        }
    }
}
