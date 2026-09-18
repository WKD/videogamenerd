import SwiftUI

/// State behind the Settings window (PLAN §5.1, §10 M0). Owns a `SecretStoring`
/// and never logs secrets. The IGDB client secret is write-only from the UI:
/// it's saved to the Keychain but never read back into a field.
@MainActor
@Observable
final class SettingsModel {
    let secretStore: any SecretStoring

    var igdbClientID: String = ""
    /// Transient input — deliberately never populated from the store so the
    /// secret is not surfaced back into the UI.
    var igdbClientSecretInput: String = ""

    private(set) var clientIDSaved = false
    private(set) var secretSaved = false
    private(set) var statusMessage: String?

    init(secretStore: any SecretStoring) {
        self.secretStore = secretStore
        // Intentionally no Keychain read here — the Accounts tab reloads on
        // appear, so nothing touches the Keychain at app launch.
    }

    func reload() {
        igdbClientID = (try? secretStore.string(for: .igdbClientID)) ?? ""
        clientIDSaved = !igdbClientID.isEmpty
        secretSaved = secretStore.hasValue(for: .igdbClientSecret)
    }

    func saveIGDB() {
        do {
            try secretStore.set(igdbClientID.trimmingCharacters(in: .whitespaces), for: .igdbClientID)
            let secret = igdbClientSecretInput.trimmingCharacters(in: .whitespaces)
            if !secret.isEmpty {
                try secretStore.set(secret, for: .igdbClientSecret)
                igdbClientSecretInput = ""
            }
            reload()
            statusMessage = "Saved to Keychain."
        } catch {
            // Never include the secret in the message.
            statusMessage = "Could not save to Keychain."
        }
    }

    func clearIGDB() {
        try? secretStore.set(nil, for: .igdbClientID)
        try? secretStore.set(nil, for: .igdbClientSecret)
        igdbClientSecretInput = ""
        reload()
        statusMessage = "Cleared."
    }

    var hasCredentials: Bool { clientIDSaved && secretSaved }
}

/// The Settings scene: Accounts (IGDB, Keychain-backed), Photo Scan and General
/// (both placeholders for later milestones).
struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        TabView {
            AccountsTab(model: model)
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            PhotoScanTab()
                .tabItem { Label("Photo Scan", systemImage: "camera") }
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 500, height: 380)
    }
}

private struct AccountsTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                TextField("Client ID", text: $model.igdbClientID)
                SecureField(model.secretSaved ? "Client Secret (saved — type to replace)" : "Client Secret",
                            text: $model.igdbClientSecretInput)
            } header: {
                Text("IGDB (Twitch)")
            } footer: {
                Text("Create a Twitch application to get a client id and secret. Stored in the macOS Keychain, never in the app's files.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    savedIndicator("Client ID", saved: model.clientIDSaved)
                    savedIndicator("Client Secret", saved: model.secretSaved)
                }
            }

            Section {
                HStack {
                    Button("Save") { model.saveIGDB() }
                        .keyboardShortcut(.defaultAction)
                    Button("Clear", role: .destructive) { model.clearIGDB() }
                        .disabled(!model.clientIDSaved && !model.secretSaved)
                    Spacer()
                    // The IGDB client is built concurrently by the services lane.
                    Button("Test connection") {}
                        .disabled(true)
                        .help("TODO: enabled once the IGDB client lands (services lane).")
                }
                if let message = model.statusMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .onAppear { model.reload() }
    }

    private func savedIndicator(_ label: String, saved: Bool) -> some View {
        Label(
            "\(label): \(saved ? "saved" : "not set")",
            systemImage: saved ? "checkmark.seal.fill" : "circle.dashed"
        )
        .font(.caption)
        .foregroundStyle(saved ? .green : .secondary)
    }
}

private struct PhotoScanTab: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("claude binary", value: "Auto-detected")
                LabeledContent("Model", value: "—")
            } header: {
                Text("Shelf photo recognition")
            } footer: {
                Text("Configured in milestone 6 (photo scan). The scanner spawns the local claude CLI for spine recognition.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

private struct GeneralTab: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Default grid size", value: "Medium")
            } footer: {
                Text("Grid defaults and other preferences arrive in a later milestone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

#if DEBUG
#Preview("Settings") {
    SettingsView(model: SettingsModel(
        secretStore: InMemorySecretStore(seed: [.igdbClientID: "abc123"])
    ))
}
#endif
