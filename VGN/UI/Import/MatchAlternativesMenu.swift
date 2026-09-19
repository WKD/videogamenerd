import SwiftUI

/// The "Alternatives" section shared by the photo-scan review and the import review
/// sheet (PLAN §14.3 — "reuse the photo-scan alternatives UI … extract"). Both offer the
/// same list of ``ScanMatch`` candidates inside a `Menu`; this is the one place that
/// renders them, so neither sheet forks the row markup.
struct MatchAlternativesSection: View {
    let alternatives: [ScanMatch]
    let onPick: (ScanMatch) -> Void

    var body: some View {
        if !alternatives.isEmpty {
            Section("Alternatives") {
                ForEach(Array(alternatives.enumerated()), id: \.offset) { _, alt in
                    Button {
                        onPick(alt)
                    } label: {
                        Text("\(alt.name)\(alt.releaseYear.map { " (\($0))" } ?? "")")
                    }
                }
            }
        }
    }
}
