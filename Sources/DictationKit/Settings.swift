import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// How the hotkey starts and stops dictation.
enum ActivationMode: String, CaseIterable {
    case hold    // hold the key while speaking, release to paste
    case toggle  // tap once to start, tap again to stop and paste

    var title: String {
        switch self {
        case .hold: return "Hold to talk"
        case .toggle: return "Press to toggle"
        }
    }
}

/// Light / dark mode for the app window.
enum AppearanceMode: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Recognition language for the local (Apple) model.
enum LocalLanguage: String, CaseIterable {
    case english = "en-US"
    case mandarin = "zh-CN"

    var title: String {
        switch self {
        case .english: return "English"
        case .mandarin: return "中文（普通话）"
        }
    }
}

/// A value a `@Setting` can save in UserDefaults.
protocol SettingValue {
    init?(stored: Any)
    var stored: Any { get }
}

extension Bool: SettingValue {
    init?(stored: Any) { guard let value = stored as? Bool else { return nil }; self = value }
    var stored: Any { self }
}

extension String: SettingValue {
    init?(stored: Any) { guard let value = stored as? String else { return nil }; self = value }
    var stored: Any { self }
}

extension SettingValue where Self: RawRepresentable, RawValue == String {
    init?(stored: Any) { guard let value = (stored as? String).flatMap(Self.init(rawValue:)) else { return nil }; self = value }
    var stored: Any { rawValue }
}

extension Hotkey: SettingValue {}
extension ActivationMode: SettingValue {}
extension MouseButton: SettingValue {}
extension AppearanceMode: SettingValue {}
extension LocalLanguage: SettingValue {}

/// An `AppSettings` property saved in its UserDefaults under `key` (`fallback` when unset or
/// unreadable). Setting it updates SwiftUI and calls `onChange`.
@propertyWrapper
struct Setting<Value: SettingValue> {
    let key: String
    let fallback: Value

    init(_ key: String, default fallback: Value) {
        self.key = key
        self.fallback = fallback
    }

    @available(*, unavailable, message: "only for AppSettings properties")
    var wrappedValue: Value {
        get { fatalError() }
        set { fatalError() }
    }

    static subscript(_enclosingInstance settings: AppSettings,
                     wrapped _: ReferenceWritableKeyPath<AppSettings, Value>,
                     storage storage: ReferenceWritableKeyPath<AppSettings, Setting>) -> Value {
        get {
            let setting = settings[keyPath: storage]
            return settings.defaults.object(forKey: setting.key).flatMap(Value.init(stored:)) ?? setting.fallback
        }
        set {
            settings.objectWillChange.send()
            settings.defaults.set(newValue.stored, forKey: settings[keyPath: storage].key)
            settings.onChange?()
        }
    }
}

/// User settings, saved in UserDefaults. `onChange` fires after any change.
final class AppSettings: ObservableObject {
    static let shared = AppSettings(secrets: FileSecretStore())

    var onChange: (() -> Void)?
    fileprivate let defaults: UserDefaults

    @Setting("hotkey", default: .fn) var hotkey: Hotkey
    @Setting("activationMode", default: .hold) var mode: ActivationMode
    @Setting("mouseButton", default: .off) var mouseButton: MouseButton
    /// A mouse button presses Return, to send what you dictated without the keyboard. On by default.
    @Setting("mouseEnterEnabled", default: true) var mouseEnterEnabled: Bool
    @Setting("mouseEnterButton", default: .button6) var mouseEnterButton: MouseButton
    /// The button that presses Return, or `.off`.
    var effectiveEnterButton: MouseButton { mouseEnterEnabled ? mouseEnterButton : .off }
    @Setting("aiPolishEnabled", default: false) var polishEnabled: Bool
    /// CoreAudio device UID; empty means the system default input.
    @Setting("microphoneUID", default: "") var microphoneUID: String
    /// Also record from the other wired and built-in mics, move a dictation to whichever hears you
    /// clearly better, and make it the Microphone setting.
    @Setting("intelligentMicSelection", default: true) var intelligentMicSelection: Bool
    @Setting("interactionSounds", default: true) var interactionSounds: Bool
    @Setting("muteWhileDictating", default: false) var muteWhileDictating: Bool
    @Setting("appearance", default: .system) var appearance: AppearanceMode
    @Setting("showInDock", default: false) var showInDock: Bool
    /// Type each finished phrase into the focused app while dictating (instead of one paste at the end).
    @Setting("streamWhileSpeaking", default: false) var streamWhileSpeaking: Bool
    /// Language for the local model (kept while a cloud model is selected).
    @Setting("localLanguage", default: .english) var localLanguage: LocalLanguage
    /// Save each dictation's audio and transcript on this Mac, for benchmarks (RecordingArchive).
    @Setting("keepRecordings", default: false) var keepRecordings: Bool
    /// Also ask a faster model when the cloud model is slow (AdaptiveBackup). On by default:
    /// in an interleaved run it cut Cloud Flash's p95 from 9.35 s to 1.20 s (bench/README.md).
    @Setting("backupWhenSlow", default: true) var backupWhenSlow: Bool

    private static let setupKey = "transcriptionModel"  // the setup's id
    private static let excludedAppsKey = "excludedApps"

    /// Settings → Model: speech model, polish model and prompt (DictationSetup).
    @Published var setup: DictationSetup {
        didSet { defaults.set(setup.id, forKey: Self.setupKey); onChange?() }
    }
    /// The built-in setups, then the valid ones in `customSetupsFile`, each with its active learned
    /// prompt (`learned`) applied.
    @Published private(set) var setups: [DictationSetup] = DictationSetup.builtIns
    /// `setups` as read, before learned prompts are applied.
    private var ownSetups = DictationSetup.builtIns
    /// Prompts learned from your corrections; a kept or re-chosen one shows up in `setups` at once.
    let learned: LearnedPromptStore
    private var learnedChanges: AnyCancellable?
    /// What's wrong in `customSetupsFile`, if anything.
    @Published private(set) var setupsError: String?
    let customSetupsFile: URL
    /// Apps in which the hotkey and mouse button are ignored (ExclusionWatcher), in the order added.
    @Published private(set) var excludedApps: [ExcludedApp] {
        didSet {
            defaults.set(try? JSONEncoder().encode(excludedApps), forKey: Self.excludedAppsKey)
            onChange?()
        }
    }

    func exclude(_ app: ExcludedApp) {
        guard !excludedApps.contains(where: { $0.bundleID == app.bundleID }) else { return }
        excludedApps.append(app)
    }

    func include(_ app: ExcludedApp) {
        excludedApps.removeAll { $0.bundleID == app.bundleID }
    }

    private let secrets: SecretStore
    static let openRouterAccount = "openrouter-api-key"

    var openRouterKey: String? { secrets.get(Self.openRouterAccount) }
    var hasOpenRouterKey: Bool { openRouterKey != nil }

    func setOpenRouterKey(_ key: String?) {
        objectWillChange.send()
        secrets.set(key?.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.openRouterAccount)
        onChange?()
    }

    /// "Type as you speak" only when the setting is on and the model streams; the saved
    /// preference is kept either way.
    var effectiveStreaming: Bool { streamWhileSpeaking && setup.supportsStreaming }
    /// "Backup model when slow" only when it's on and the setup has a backup.
    var effectiveBackup: Bool { backupWhenSlow && setup.backup != nil }

    /// Mirrors macOS's login-item state; change it with setLaunchAtLogin(_:).
    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginItemNeedsApproval = false

    init(defaults: UserDefaults = .standard, secrets: SecretStore = FileSecretStore(),
         customSetupsFile: URL = DictationSetup.customFile, learned: LearnedPromptStore = .shared) {
        self.defaults = defaults
        self.secrets = secrets
        self.customSetupsFile = customSetupsFile
        self.learned = learned
        setup = .onDevice
        excludedApps = defaults.data(forKey: Self.excludedAppsKey)
            .flatMap { try? JSONDecoder().decode([ExcludedApp].self, from: $0) } ?? []
        let saved = defaults.string(forKey: Self.setupKey).map(DictationSetup.currentID)
        reloadSetups(selecting: saved)
        refreshLoginItem()
        // objectWillChange fires before the store changes; the setups are re-read once it has.
        // Settings shows the learned versions' scores through `learned`, so it's redrawn too.
        learnedChanges = learned.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send(); self?.reloadSetups() }
        }
    }

    /// Re-reads `customSetupsFile` (Settings calls this when it opens, so edits show up). The chosen
    /// setup picks up its edits; if it's gone, On-device is chosen.
    func reloadSetups(selecting id: String? = nil) {
        let custom = DictationSetup.loadCustom(from: customSetupsFile)
        ownSetups = DictationSetup.builtIns + custom.setups
        // Assigned only when changed: Settings calls this each time it opens, and every
        // assignment redraws it.
        let applied = ownSetups.map(learned.apply(to:))
        if applied != setups { setups = applied }
        if custom.error != setupsError { setupsError = custom.error }
        let wanted = id ?? setup.id
        let chosen = setups.first { $0.id == wanted } ?? .onDevice
        if chosen != setup || defaults.string(forKey: Self.setupKey) != chosen.id { setup = chosen }
    }

    /// The setup's own prompt version, under any learned one.
    func builtInPrompt(for setup: DictationSetup) -> String {
        ownSetups.first { $0.id == setup.id }?.prompt ?? setup.prompt
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("DictationApp: login item change failed: \(error.localizedDescription)")
        }
        refreshLoginItem()
    }

    func refreshLoginItem() {
        let status = SMAppService.mainApp.status
        let enabled = status == .enabled || status == .requiresApproval, pending = status == .requiresApproval
        if enabled != launchAtLogin { launchAtLogin = enabled }
        if pending != loginItemNeedsApproval { loginItemNeedsApproval = pending }
    }

    /// One-line usage hint, e.g. "Hold Fn to dictate — release to paste".
    var hint: String {
        switch mode {
        case .hold: return "Hold \(hotkey.shortName) to dictate — release to paste"
        case .toggle: return "Tap \(hotkey.shortName) to start — tap again to paste"
        }
    }
}
