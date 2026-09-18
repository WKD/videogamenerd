import SwiftUI

/// Settings → Photo Scan (PLAN §6.2). Detected `claude` binary + version with a manual
/// override and a "Check" button, model picker, max parallel tile calls, and the engine
/// preference — all persisted in `UserDefaults`. The orchestrator swaps the placeholder
/// `PhotoScanTab` in `SettingsView` for this:
/// ```swift
/// PhotoScanSettingsTab().tabItem { Label("Photo Scan", systemImage: "camera") }
/// ```
struct PhotoScanSettingsTab: View {
    @State private var model = PhotoScanSettingsModel()

    var body: some View {
        Form {
            Section {
                LabeledContent("Detected") {
                    if model.isChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(model.detectedSummary).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier(A11yID.settingsClaudePath)
                .accessibilityValue(model.detectedSummary)
                TextField("Binary override", text: $model.binaryOverride, prompt: Text("Auto-detect (leave blank)"))
                    .onSubmit { model.persist() }
                HStack {
                    Button("Check") { model.check() }
                        .accessibilityIdentifier(A11yID.settingsCheck)
                    if let result = model.checkResult {
                        Text(result).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Claude Code")
            } footer: {
                Text("The scanner spawns the local claude CLI (subscription-billed). GUI apps don't inherit your shell PATH, so the binary is auto-detected; override it here if needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Recognition") {
                Picker("Engine", selection: $model.enginePreference) {
                    ForEach(ScanEnginePreference.allCases, id: \.self) { pref in
                        Text(pref.label).tag(pref)
                    }
                }
                .onChange(of: model.enginePreference) { _, _ in model.persist() }

                Picker("Model", selection: $model.modelPreset) {
                    ForEach(ModelPreset.allCases, id: \.self) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .onChange(of: model.modelPreset) { _, _ in model.applyPreset() }
                if model.modelPreset == .custom {
                    TextField("Model name", text: $model.model, prompt: Text("e.g. claude-opus-4"))
                        .onSubmit { model.persist() }
                }

                Stepper("Parallel tile calls: \(model.maxConcurrent)", value: $model.maxConcurrent, in: 1...4)
                    .onChange(of: model.maxConcurrent) { _, _ in model.persist() }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .onAppear { model.check() }
    }
}

/// Model presets surfaced in the picker (free-text via `.custom`).
enum ModelPreset: String, CaseIterable, Equatable {
    case `default`, cheaper, stronger, custom
    var label: String {
        switch self {
        case .default: return "Default (CLI)"
        case .cheaper: return "Cheaper (Haiku)"
        case .stronger: return "Stronger (Opus)"
        case .custom: return "Custom…"
        }
    }
    var modelString: String {
        switch self {
        case .default: return ""
        case .cheaper: return "haiku"
        case .stronger: return "opus"
        case .custom: return ""
        }
    }
    static func from(_ model: String) -> ModelPreset {
        switch model {
        case "": return .default
        case "haiku": return .cheaper
        case "opus": return .stronger
        default: return .custom
        }
    }
}

@MainActor
@Observable
final class PhotoScanSettingsModel {
    private let preferences: any PhotoScanPreferenceStoring

    var binaryOverride: String
    var model: String
    var modelPreset: ModelPreset
    var maxConcurrent: Int
    var enginePreference: ScanEnginePreference

    private(set) var checkResult: String?
    private(set) var isChecking = false
    private(set) var detectedPath: String?
    private(set) var detectedVersion: String?

    init(preferences: any PhotoScanPreferenceStoring = UserDefaultsPhotoScanPreferences()) {
        self.preferences = preferences
        let settings = preferences.load()
        self.binaryOverride = settings.binaryOverride
        self.model = settings.model
        self.modelPreset = ModelPreset.from(settings.model)
        self.maxConcurrent = settings.clampedConcurrency
        self.enginePreference = settings.enginePreference
    }

    var detectedSummary: String {
        if let path = detectedPath {
            return detectedVersion.map { "claude \($0) — \(path)" } ?? path
        }
        return "Not found"
    }

    func applyPreset() {
        if modelPreset != .custom { model = modelPreset.modelString }
        persist()
    }

    func persist() {
        var settings = PhotoScanSettings()
        settings.binaryOverride = binaryOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.maxConcurrent = maxConcurrent
        settings.enginePreference = enginePreference
        preferences.save(settings)
    }

    /// Resolve + version-check the binary (PLAN §6.2 "Check" button). Runs the shell
    /// probe off the main actor.
    func check() {
        persist()
        isChecking = true
        checkResult = nil
        let override = binaryOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { [override] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<(String, String?), ClaudeCLIError> in
                let locator = ClaudeBinaryLocator(explicitOverride: override.isEmpty ? nil : override)
                do {
                    let url = try locator.resolve()
                    let version = ClaudeShellProbe.version(ofBinaryAt: url.path)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return .success((url.path, version))
                } catch let error as ClaudeCLIError {
                    return .failure(error)
                } catch {
                    return .failure(.launchFailed("\(error)"))
                }
            }.value

            isChecking = false
            switch outcome {
            case .success(let (path, version)):
                detectedPath = path
                detectedVersion = version.flatMap { ClaudeCLIVersion(parsing: $0)?.description }
                checkResult = "Ready."
            case .failure(let error):
                detectedPath = nil
                detectedVersion = nil
                checkResult = error.shortDescription
            }
        }
    }
}

#if DEBUG
#Preview("Photo Scan settings") {
    PhotoScanSettingsTab()
        .frame(width: 500, height: 420)
}
#endif
