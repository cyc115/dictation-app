import AppKit

/// `DictationApp settings …`: every setting, read and changed from a shell, so a script can switch
/// them, e.g. Hammerspoon choosing On-device on battery and Cloud Flash on power. A change is saved
/// where Settings saves it, then the running app is told (`changed`) and re-reads it at once.
///
///   DictationApp settings [list] [--json]   every setting, its value and the values it takes
///   DictationApp settings get <name>        just the value
///   DictationApp settings set <name> <value>
///   DictationApp settings toggle <name>     an on/off setting
///
/// Names are the UserDefaults keys (`defaults read com.mikechen.DictationApp`), plus `setup`,
/// `launchAtLogin`, `excludedApps` and `openRouterKey`. Exit status: 0 done, 1 unknown name or
/// value, 2 bad usage.
enum SettingsCommand {
    /// Posted after a change; the running app re-reads its settings (`observe`).
    static let changed = Notification.Name("com.mikechen.DictationApp.settingsChanged")

    struct IO {
        var out: (String) -> Void = { print($0) }
        var err: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        /// The rest of stdin, for `set openRouterKey -` (a key on the command line shows up in `ps`).
        var input: () -> String? = { String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) }
        var notify: () -> Void = {
            UserDefaults.standard.synchronize()  // saved before the app looks
            DistributedNotificationCenter.default().postNotificationName(changed, object: nil, userInfo: nil,
                                                                         deliverImmediately: true)
        }
    }

    /// Runs the command and returns its exit status when the app was started as `DictationApp settings …`;
    /// nil otherwise (start the app).
    @MainActor
    static func runIfRequested(_ arguments: [String] = CommandLine.arguments) -> Int32? {
        guard arguments.dropFirst().first == "settings" else { return nil }
        // The same settings AppServices.live() makes.
        let settings = AppSettings(learned: LearnedPromptStore())
        return run(Array(arguments.dropFirst(2)), settings: settings)
    }

    static func run(_ arguments: [String], settings: AppSettings, io: IO = IO()) -> Int32 {
        let json = arguments.contains("--json")
        let args = arguments.filter { $0 != "--json" }
        switch (args.first, args.count) {
        case (nil, _), ("list", 1):
            list(entries(settings, io: io), json: json, io: io)
            return 0
        case ("get", 2):
            guard let entry = find(args[1], settings, io: io) else { return 1 }
            io.out(entry.value)
            return 0
        case ("set", 3), ("toggle", 2):
            guard let entry = find(args[1], settings, io: io) else { return 1 }
            let value: String
            if args[0] == "toggle" {
                guard entry.isOnOff else { io.err("\(entry.name) isn't on/off; use set"); return 1 }
                value = entry.value == "on" ? "off" : "on"
            } else {
                value = args[2]
            }
            guard entry.set(value) else {
                io.err("\(entry.name) can't be \"\(value)\"" + (entry.choices.map { "; it takes: \($0.joined(separator: ", "))" } ?? ""))
                return 1
            }
            io.notify()
            io.out("\(entry.name) = \(find(entry.name, settings, io: io)?.value ?? value)")
            return 0
        case ("help", _), ("--help", _), ("-h", _):
            io.out(usage)
            return 0
        default:
            io.err(usage)
            return 2
        }
    }

    static let usage = """
        usage: DictationApp settings [list] [--json]
               DictationApp settings get <name>
               DictationApp settings set <name> <value>
               DictationApp settings toggle <name>
        """

    /// Every setting: the setup, then each `@Setting` in Settings' order, then the rest.
    static func entries(_ settings: AppSettings, io: IO) -> [SettingEntry] {
        let setup = SettingEntry(name: "setup", value: settings.setup.id, choices: settings.setups.map(\.id)) { id in
            guard let setup = settings.setups.first(where: { $0.id == DictationSetup.currentID(id) }) else { return false }
            settings.setup = setup
            return true
        }
        let ownEntries = settings.entries.map { $0.name == "microphoneUID" ? microphone(settings) : $0 }
        let login = SettingEntry(name: "launchAtLogin", value: settings.launchAtLogin.text, choices: Bool.choices) { text in
            guard let on = Bool(text: text) else { return false }
            settings.setLaunchAtLogin(on)
            return true
        }
        let excluded = SettingEntry(name: "excludedApps", value: settings.excludedApps.map(\.bundleID).joined(separator: ","),
                                    choices: nil) { text in
            let ids = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            for app in settings.excludedApps where !ids.contains(app.bundleID) { settings.include(app) }
            for id in ids { settings.exclude(excludedApp(id)) }
            return true
        }
        let key = SettingEntry(name: "openRouterKey", value: settings.hasOpenRouterKey ? "set" : "not set", choices: nil) { text in
            settings.setOpenRouterKey(text == "-" ? io.input() : text)
            return true
        }
        return [setup] + ownEntries + [login, excluded, key]
    }

    /// The mic by name or UID, or `default` for the system's; shown as its UID.
    private static func microphone(_ settings: AppSettings) -> SettingEntry {
        let mics = AudioDevices.inputDevices()
        return SettingEntry(name: "microphoneUID", value: settings.microphoneUID.isEmpty ? "default" : settings.microphoneUID,
                            choices: ["default"] + mics.map(\.name)) { text in
            if text.isEmpty || text == "default" { settings.microphoneUID = ""; return true }
            guard let mic = mics.first(where: { $0.uid == text || $0.name.caseInsensitiveCompare(text) == .orderedSame })
            else { return false }
            settings.microphoneUID = mic.uid
            return true
        }
    }

    /// The installed app with this bundle ID, named; just the ID when it isn't installed.
    private static func excludedApp(_ bundleID: String) -> ExcludedApp {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).flatMap(ExcludedApp.init(appAt:))
            ?? ExcludedApp(bundleID: bundleID, name: bundleID)
    }

    private static func find(_ name: String, _ settings: AppSettings, io: IO) -> SettingEntry? {
        let all = entries(settings, io: io)
        if let entry = all.first(where: { $0.name == name })
            ?? all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return entry
        }
        io.err("no setting \"\(name)\"; `DictationApp settings` lists them")
        return nil
    }

    private static func list(_ entries: [SettingEntry], json: Bool, io: IO) {
        if json {
            let rows: [[String: Any]] = entries.map { entry in
                let value: Any = entry.isOnOff ? entry.value == "on" : entry.value
                var row: [String: Any] = ["name": entry.name, "value": value]
                if let choices = entry.choices { row["choices"] = choices }
                return row
            }
            let data = (try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            io.out(String(decoding: data, as: UTF8.self))
            return
        }
        let width = entries.map(\.name.count).max() ?? 0
        for entry in entries {
            let name = entry.name.padding(toLength: width, withPad: " ", startingAt: 0)
            io.out("\(name)  \(entry.value)" + (entry.choices.map { "  [\($0.joined(separator: " | "))]" } ?? ""))
        }
    }

    /// Re-reads `settings` whenever `DictationApp settings` changes one. Keep the token for as long as
    /// the app runs.
    static func observe(_ settings: AppSettings) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: changed, object: nil, queue: .main) { [weak settings] _ in
            settings?.reloadFromDefaults()
        }
    }
}
