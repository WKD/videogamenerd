import SwiftUI

/// One PS Plus row in the Vault browser (PLAN §16): the remote cover (through the in-memory
/// ``VaultCoverLoader`` — never the cover folder), the title, a platform pill, the "+" PS Plus
/// marker (the grid badge's colours), any cross-gen note, the IGDB year / genre / rating once
/// matched, and the match state ("not matched yet" / "no IGDB match — Find match…"). Actions:
/// Add to Library…, Not Interested, Find match…. No PlayStation Store link — a correct product
/// URL is not derivable from the stored fields (the entitlement id is not a store/concept id).
struct VaultBrowserRow: View {
    let entry: RomCatalogEntry
    let env: BatoceraEnvironment
    let isSelected: Bool
    let onTap: () -> Void
    let onCommandTap: () -> Void
    let onAdd: () -> Void
    let onNotInterested: () -> Void
    let onFindMatch: () -> Void
    let onInspect: (Int64) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VaultCoverThumb(entry: entry, loader: env.vaultCovers)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    psPlusBadge
                    Text(entry.name).font(.body).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(PlatformLabels.short(entry.system))
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.tint.opacity(0.2), in: Capsule())
                    if let note = entry.crossGenNote, !note.isEmpty {
                        Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if entry.matchState == .matched {
                        if let year = entry.releaseYear { Text(String(year)).font(.caption2).foregroundStyle(.secondary) }
                        if let genre = entry.genre, !genre.isEmpty {
                            Text(genre).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                matchStateLine
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .contextMenu { contextMenu }
    }

    /// The PlayStation-blue "+" in a yellow circle (PLAN §13.3 grid-badge colours).
    private var psPlusBadge: some View {
        Text("+")
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .foregroundStyle(Color(hex: "#0070D1") ?? .blue)
            .frame(width: 15, height: 15)
            .background(Color(hex: "#FFC300") ?? .yellow, in: Circle())
            .appKitTooltip("PS Plus — expires with the subscription")
            .accessibilityIdentifier("vault.psPlusMarker.\(entry.id)")
    }

    @ViewBuilder
    private var matchStateLine: some View {
        switch entry.matchState {
        case .matched:
            if let rating = entry.crowdRating0to100 {
                Label(String(format: "IGDB %.0f", rating), systemImage: "star.fill")
                    .font(.caption2).foregroundStyle(.yellow).labelStyle(.titleAndIcon)
            }
        case .noMatch:
            Text("no IGDB match — Find match…").font(.caption2).foregroundStyle(.secondary)
        case nil:
            Text("not matched yet").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var trailing: some View {
        HStack(spacing: 10) {
            if let gid = entry.promotedGameID {
                Button { onInspect(gid) } label: {
                    Label("In Library", systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(.green)
                }
                .buttonStyle(.borderless)
                .help("Already in your library — click to reveal it.")
            } else {
                Button("Add…") { onAdd() }
                    .controlSize(.small).buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("vault.add.\(entry.id)")
            }
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if entry.promotedGameID == nil {
            Button("Add to Library…") { onAdd() }
            if env.findMatch != nil, entry.matchState != .matched {
                Button("Find match…") { onFindMatch() }
            }
            Button("Not Interested") { onNotInterested() }
        }
        if let gid = entry.promotedGameID {
            Button("Reveal in Library") { onInspect(gid) }
        }
    }
}
