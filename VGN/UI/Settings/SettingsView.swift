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

    /// The services lane's connection probe, injected by the app once services are
    /// built. Nil in the test host / DB-failure path (the button stays disabled).
    var connectionTester: IGDBConnectionTester?
    /// GOG account pane state (PLAN §14.2), injected once the app has built services.
    /// Nil in the test host / DB-failure path (the pane is omitted).
    var gogAccount: GOGAccountModel?
    /// Called after credentials are saved or cleared so the enrichment coordinator
    /// can resume / idle (`coordinator.credentialsDidChange()`).
    var onCredentialsChanged: () -> Void = {}
    private(set) var isTesting = false
    private(set) var testResult: String?

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
            testResult = nil
            onCredentialsChanged()
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
        testResult = nil
        onCredentialsChanged()
    }

    var hasCredentials: Bool { clientIDSaved && secretSaved }

    /// The credentials to probe: the typed values, falling back to the saved secret
    /// when the (write-only) secret field is empty.
    private func currentCredentials() -> IGDBCredentials? {
        let id = igdbClientID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        let typed = igdbClientSecretInput.trimmingCharacters(in: .whitespaces)
        let secret = typed.isEmpty ? ((try? secretStore.string(for: .igdbClientSecret)) ?? "") : typed
        guard !secret.isEmpty else { return nil }
        return IGDBCredentials(clientID: id, secret: secret)
    }

    /// Run the "Test connection" probe (PLAN §5.1) and show a human-readable result.
    func testConnection() {
        guard let tester = connectionTester else { return }
        guard let credentials = currentCredentials() else {
            testResult = "Enter a Client ID and Secret (or save them) first."
            return
        }
        isTesting = true
        testResult = nil
        Task {
            let result = await tester.test(credentials: credentials)
            isTesting = false
            switch result {
            case .success(let success):
                let n = success.sampleCount
                testResult = "\(success.message) Probe returned \(n) result\(n == 1 ? "" : "s")."
            case .failure(let failure):
                testResult = failure.message
            }
        }
    }
}

/// The Settings scene: Accounts (IGDB, Keychain-backed), Photo Scan (`PhotoScanSettingsTab`)
/// and General (a placeholder for a later milestone).
struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        TabView {
            AccountsTab(model: model)
                .accessibilityIdentifier(A11yID.settingsTabAccounts)
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            PhotoScanSettingsTab()
                .accessibilityIdentifier(A11yID.settingsTabPhotoScan)
                .tabItem { Label("Photo Scan", systemImage: "camera") }
            GeneralTab()
                .accessibilityIdentifier(A11yID.settingsTabGeneral)
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

            if let gog = model.gogAccount {
                Section {
                    GOGAccountPane(model: gog)
                } header: {
                    Text("GOG")
                }
            }

            Section {
                HStack {
                    Button("Save") { model.saveIGDB() }
                        .keyboardShortcut(.defaultAction)
                    Button("Clear", role: .destructive) { model.clearIGDB() }
                        .disabled(!model.clientIDSaved && !model.secretSaved)
                    Spacer()
                    if model.isTesting { ProgressView().controlSize(.small) }
                    Button("Test connection") { model.testConnection() }
                        .disabled(model.connectionTester == nil || model.isTesting)
                        .help(model.connectionTester == nil
                              ? "Available once the app finishes launching."
                              : "Fetch a token and run one IGDB query.")
                }
                if let message = model.statusMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if let result = model.testResult {
                    Text(result).font(.caption).foregroundStyle(.secondary)
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

private struct GeneralTab: View {
    /// The same weekly-play-pace store the sidebar "By Length" header edits, so both
    /// stay in sync (PLAN §8). Reloads on appear to pick up a change made there.
    @State private var pace = PlayPaceModel(store: UserDefaultsPlayPacePreferences())

    var body: some View {
        Form {
            Section {
                PaceEditor(model: pace, title: "")
            } header: {
                Text("Weekly play time")
            } footer: {
                Text("Sets the hour ranges of the sidebar’s “By Length” shelves — the same control lives in the sidebar’s BY LENGTH header. A short game is one you can finish in an evening at this pace.")
                    .font(.caption).foregroundStyle(.secondary)
            }

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
