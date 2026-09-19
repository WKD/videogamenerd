import SwiftUI

/// The Quick Add palette (PLAN §6.1) — a Spotlight-style card. Keyboard handling
/// lives in ``QuickAddPanelController`` (an AppKit `NSEvent` monitor on the key
/// panel), which is what makes ↑↓ / Tab / ⌘O·P·D / ⌃S…F / ↩ / ⌘↩ / esc reliable
/// while the text field holds focus for typing. This view is a thin render shell;
/// all logic is in ``QuickAddModel``.
struct QuickAddView: View {
    @Bindable var model: QuickAddModel
    let coverLoader: any CoverLoading
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            content
            footer
        }
        .frame(width: 560)
        .frame(maxHeight: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 0.5))
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { fieldFocused = true }
    }

    // MARK: Search field

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Add a game…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title2)
                .focused($fieldFocused)
                .accessibilityIdentifier(A11yID.quickAddField)
            if model.isSearchingRemote {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: Content (results + manual row + hint)

    @ViewBuilder
    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if !model.credentialsAvailable {
                        offlineHint
                    }
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                        QuickAddRowView(
                            result: result,
                            isSelected: index == model.selectedIndex,
                            selectedPlatform: index == model.selectedIndex ? model.effectivePlatform : result.platformSlugs.first,
                            isBundleLoading: model.bundleInFlightID == result.id,
                            coverLoader: coverLoader
                        )
                        .id(result.id)
                        .accessibilityIdentifier(A11yID.quickAddRow(index))
                        .contentShape(Rectangle())
                        .onTapGesture { model.select(index) }
                    }
                    if model.canAddManual {
                        manualRow
                    }
                }
                .padding(8)
            }
            .onChange(of: model.selectedIndex) { _, index in
                guard model.results.indices.contains(index) else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(model.results[index].id, anchor: .center)
                }
            }
        }
        .frame(minHeight: model.results.isEmpty && !model.canAddManual ? 0 : 120)
    }

    private var offlineHint: some View {
        Label("Add IGDB credentials in Settings to search the catalogue. Local library and manual add still work.",
              systemImage: "wifi.slash")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(A11yID.quickAddOfflineHint)
    }

    private var manualRow: some View {
        Button {
            model.addManualRow()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .frame(width: 34, height: 46)
                    .foregroundStyle(.secondary)
                Text(model.manualRowTitle).font(.body)
                Spacer()
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(A11yID.quickAddManualRow)
    }

    // MARK: Footer (flags + confirmation + shortcut hints)

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            if let confirmation = model.confirmation {
                confirmationRow(confirmation)
                Divider()
            }
            HStack(spacing: 12) {
                flagChip(model.flags.owned ? "Owned" : "Not owned",
                         system: model.flags.owned ? "shippingbox.fill" : "shippingbox",
                         on: model.flags.owned, help: "⌘O", identifier: A11yID.quickAddOwnedState)
                if model.flags.owned {
                    flagChip(model.flags.format.label, system: formatIcon, on: true,
                             help: "⌘D cycles format", identifier: A11yID.quickAddFormatState)
                }
                flagChip(model.flags.played ? "Played" : "Backlog",
                         system: model.flags.played ? "gamecontroller.fill" : "tray.full",
                         on: model.flags.played, help: "⌘P", identifier: A11yID.quickAddPlayedState)
                if let tier = model.tierLetter {
                    flagChip("Tier \(tier)", system: "star.fill", on: true, help: "⌃0 clears")
                }
                Spacer()
                Text(shortcutHint).font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
        }
    }

    private func confirmationRow(_ confirmation: QuickAddConfirmation) -> some View {
        HStack(spacing: 8) {
            Image(systemName: confirmation.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(confirmation.isError ? .orange : .green)
            Text(confirmation.message).font(.callout)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func flagChip(_ text: String, system: String, on: Bool, help: String,
                          identifier: String? = nil) -> some View {
        Label(text, systemImage: system)
            .font(.caption)
            .foregroundStyle(on ? Color.primary : Color.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.15) : Color.clear))
            .help(help)
            // The chip conveys state visually only; expose it as a queryable value
            // (owned/played/format) for the UI smoke suite and VoiceOver.
            .accessibilityIdentifier(identifier ?? "")
            .accessibilityValue(text)
    }

    private var formatIcon: String {
        switch model.flags.format {
        case .physical: return "opticaldisc"
        case .digital: return "arrow.down.circle"
        case .rom: return "memorychip"
        }
    }

    private var shortcutHint: String {
        "↑↓ select · Tab platform · ↩ add · ⇧↩ add & keep list · ⌘↩ add & open · ⌃S…⌃F tier · esc close"
    }
}

// MARK: - Row

private struct QuickAddRowView: View {
    let result: QuickAddResult
    let isSelected: Bool
    let selectedPlatform: String?
    let isBundleLoading: Bool
    let coverLoader: any CoverLoading

    var body: some View {
        HStack(spacing: 10) {
            cover
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(result.title).font(.body).lineLimit(1)
                    if let year = result.year {
                        Text(String(year)).font(.caption).foregroundStyle(.secondary)
                    }
                    if result.isBundle {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.caption2).foregroundStyle(.secondary)
                            .help("Compilation")
                    }
                }
                HStack(spacing: 4) {
                    ForEach(platformChips, id: \.self) { slug in
                        Text(PlatformLabels.short(slug))
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4)
                                .fill(slug == selectedPlatform ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.15)))
                    }
                    if let match = result.libraryMatch {
                        Text(libraryBadge(match)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if isBundleLoading {
                ProgressView().controlSize(.small)
            } else if result.isBundle {
                Text("Add as compilation").font(.caption2).foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor.opacity(0.2) : .clear))
    }

    private var platformChips: [String] { Array(result.platformSlugs.prefix(6)) }

    private func libraryBadge(_ match: QuickAddLibraryMatch) -> String {
        var parts = ["✓ In library"]
        if !match.platformIDs.isEmpty {
            parts.append("on " + match.platformIDs.map(PlatformLabels.short).joined(separator: ", "))
        }
        if match.hasROM { parts.append("(ROM)") }
        return parts.joined(separator: " ")
    }

    @ViewBuilder
    private var cover: some View {
        if result.source == .catalog, let imageID = result.coverImageID,
           let url = IGDBImageURL.cover(imageID: imageID, size: .coverSmall) {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                coverPlaceholder
            }
            .frame(width: 34, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        } else if let coverFile = result.coverFile {
            LocalCoverThumb(coverFile: coverFile, loader: coverLoader)
                .frame(width: 34, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            coverPlaceholder.frame(width: 34, height: 46)
        }
    }

    private var coverPlaceholder: some View {
        RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            .overlay(Image(systemName: "gamecontroller").font(.caption2).foregroundStyle(.tertiary))
    }
}

/// A small local-cover thumbnail loaded through the cover seam (for library rows
/// that already have art).
private struct LocalCoverThumb: View {
    let coverFile: String
    let loader: any CoverLoading
    @State private var image: CGImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            if let image {
                Image(decorative: image, scale: displayScale).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .task(id: coverFile) {
            let px = CGSize(width: 34 * displayScale, height: 46 * displayScale)
            let loaded = await loader.thumbnail(for: coverFile, pixelSize: px)
            if !Task.isCancelled { image = loaded }
        }
    }
}
