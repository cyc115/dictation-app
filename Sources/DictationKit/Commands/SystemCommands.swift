import AppKit

/// What the built-in commands that work the Mac do with their choice (brightness, volume, lock-screen,
/// media-control, open-website, switch-app). `CommandMode.system` holds them, so tests can fake them.
enum SystemCommands {
    typealias Action = @MainActor (_ choice: String?, _ said: String) async -> CommandResult

    static let live: [String: Action] = [
        Command.brightness.name: { choice, _ in await Brightness.set(choice) },
        Command.volume.name: { choice, _ in Volume.set(choice) },
        Command.lockScreen.name: { _, _ in LockScreen.lock() },
        Command.media.name: { choice, _ in MediaKeys.press(choice) },
        Command.openWebsite.name: { choice, said in Websites.open(choice, said: said) },
        Command.switchApp.name: { choice, _ in await SwitchApp.switchTo(choice) },
    ]

    /// The new level, 0–100, for a choice: "+10" / "-10" change `current` by that much, "50" sets it;
    /// nil when the choice isn't a number.
    static func level(_ choice: String?, from current: Double) -> Double? {
        guard let choice, let value = Double(choice) else { return nil }
        let level = choice.hasPrefix("+") || choice.hasPrefix("-") ? current + value : value
        return min(100, max(0, level))
    }
}

/// The volume command: the current output device, through AppleScript's volume settings (run in
/// the app, so it needs no permission).
enum Volume {
    @MainActor
    static func set(_ choice: String?) -> CommandResult {
        if choice == "mute" || choice == "unmute" {
            if let error = run("set volume output muted \(choice == "mute")").error { return failed(error) }
            return CommandResult(ok: true, message: choice == "mute" ? "Muted" : "Unmuted")
        }
        let current = run("output volume of (get volume settings)")
        if let error = current.error { return failed(error) }
        guard current.value?.descriptorType == typeSInt32, let now = current.value?.int32Value else {
            return CommandResult(ok: false, message: "This output's volume can't be set")
        }
        guard let level = SystemCommands.level(choice, from: Double(now)).map({ Int($0.rounded()) }) else {
            return CommandResult(ok: false, message: "No volume given")
        }
        if let error = run("set volume output volume \(level) without output muted").error { return failed(error) }
        return CommandResult(ok: true, message: "Volume \(level)%")
    }

    private static func failed(_ error: String) -> CommandResult {
        CommandResult(ok: false, message: "Couldn't set the volume", details: error)
    }

    /// The script's result, or why it failed.
    @MainActor
    private static func run(_ source: String) -> (value: NSAppleEventDescriptor?, error: String?) {
        var error: NSDictionary?
        let value = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return (value, error.map { "AppleScript: \($0[NSAppleScript.errorMessage] ?? $0)" })
    }
}

/// The lock-screen command: locks at once, whatever the screen saver's password setting, as
/// Control-Command-Q does (macOS's private SACLockScreenImmediate, as Hammerspoon uses).
enum LockScreen {
    static func lock() -> CommandResult {
        guard let library = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let symbol = dlsym(library, "SACLockScreenImmediate") else {
            return CommandResult(ok: false, message: "macOS can't lock the screen from here",
                                 details: "SACLockScreenImmediate not found in login.framework")
        }
        _ = unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)()  // what it returns isn't documented
        return CommandResult(ok: true, message: "Locked the screen")
    }

    /// Whether this macOS has it (tests check without locking).
    static var available: Bool {
        dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY)
            .flatMap { dlsym($0, "SACLockScreenImmediate") } != nil
    }
}

/// The media-control command: presses the keyboard's play/pause, next or previous key, so it
/// controls whatever is playing (Music, Spotify, a video in the browser), as the keys do.
enum MediaKeys {
    /// The key's code (NX_KEYTYPE_PLAY, _NEXT, _PREVIOUS) and what's shown.
    static let keys: [String: (code: Int, done: String)] = [
        "play-pause": (16, "Play/pause"), "next": (17, "Next track"), "previous": (18, "Previous track"),
    ]

    static func press(_ choice: String?, post: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) -> CommandResult {
        guard let choice, let key = keys[choice] else { return CommandResult(ok: false, message: "No media key given") }
        guard AXIsProcessTrusted() else { return CommandResult(ok: false, message: "Needs Accessibility permission to press keys") }
        for event in events(key.code) { post(event) }
        return CommandResult(ok: true, message: key.done)
    }

    /// Key down then up, as the media keys send them: system-defined events, subtype 8
    /// (NX_SUBTYPE_AUX_CONTROL_BUTTONS), the key in data1's high half and its state (0xA down, 0xB up)
    /// in bits 8–15.
    static func events(_ code: Int) -> [CGEvent] {
        [0xA, 0xB].compactMap { state in
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state) << 8),
                               timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                               data1: code << 16 | state << 8, data2: -1)?.cgEvent
        }
    }
}
