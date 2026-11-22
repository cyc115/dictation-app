import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// *Learn from my edits*: watches how you edit a dictation right after it's pasted, and keeps the
/// pasted text as you left it as a captured fix on its History entry (`Capture`), waiting in
/// Corrections for your Accept. No model is asked anything.
///
/// Armed by `DictationController` after a plain text paste (never for a command, a dictation that's
/// sent, or text taken back by *Paste where you dictated*), and never with the setting off, in an
/// excluded app, in a password field or with secure input on. 0.15 s later (the app has taken the
/// ⌘V by then) the box is read: if the pasted text ends where the cursor is, the box is read back
/// again whenever typing pauses (`SpanTracker`, readback mode); otherwise your keys are applied to
/// the pasted text in memory (`TypedEdit`, keystroke mode). Keys typed before that read are kept in
/// a `TypedEdit` too, so none is lost either way.
///
/// It ends on Return, a focus or app change, a new dictation, 30 s without a key or after 2 minutes;
/// secure input turning on drops it. An edit that changes no word leaves nothing.
///
/// Nothing in it may slow typing: arming and every read but one run off the main thread; keys come
/// from `HotkeyManager`'s event tap (one nil check while nothing is watched) and cost an in-memory
/// update; only the read before a Return holds that key back, for at most 50 ms; saving waits until
/// the key has gone on. Each step that touches the Mac is a closure, as in `GoBack`, so tests run it
/// with fakes. Nothing it sees is written anywhere but the capture: not your keys, not the rest of
/// the box.
final class EditWatcher {
    /// The text box as read: its whole value, the insertion point (UTF-16 offset; nil when there's a
    /// selection or the app doesn't say), and whether it still has the focus.
    struct Read: Equatable {
        var value: String
        var cursor: Int?
        var focused: Bool
    }

    /// From the paste to the first read: the app takes the ⌘V asynchronously.
    static let probeDelay: TimeInterval = 0.15
    /// Typing pauses this long: the box is read.
    static let pause: TimeInterval = 0.7
    static let quietLimit: TimeInterval = 30
    static let timeLimit: TimeInterval = 120
    /// The longest a Return is held back for the last read.
    static let returnReadLimit: TimeInterval = 0.05
    /// A timer this close to its time counts as on time (not re-armed for a sliver).
    private static let slack: TimeInterval = 0.01

    private let settings: AppSettings
    private let history: HistoryStore
    let stats: EditWatchStats

    // MARK: The Mac (tests fake each)

    var read: (TextSpot) -> Read? = EditWatcher.readBox
    var isSecureField: (TextSpot) -> Bool = EditWatcher.isSecureField
    var secureInput: () -> Bool = { IsSecureEventInputEnabled() }
    /// An input method (Chinese, Japanese…; not a keyboard layout) is on: keys aren't the text typed.
    var inputMethodActive: () -> Bool = EditWatcher.inputMethodActive
    var bundleID: (pid_t) -> String? = { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
    /// Starts (a handler) or stops (nil) getting key-downs from the event tap (`HotkeyManager.onKey`).
    var listen: (((EditKey) -> Void)?) -> Void = { _ in }
    /// Starts or stops a passive mouse-down monitor (keystroke mode only).
    var watchClicks: ((() -> Void)?) -> Void = EditWatcher.clickMonitor()
    /// Starts or stops hearing which app comes to the front.
    var watchApps: (((pid_t) -> Void)?) -> Void = EditWatcher.appMonitor()
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var after: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    var background: (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) }
    /// Back to the main thread, after whatever it's in the middle of (a key the tap is holding).
    var toMain: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    /// A capture was saved (the idle pass counts it).
    var onCapture: () -> Void = {}

    // MARK: The watch

    private enum Mode {
        /// Waiting for the first read; keys go into `typed`.
        case probing
        case readback(SpanTracker)
        case keystrokes
    }

    private final class Watch {
        let spot: TextSpot
        let pasted: String
        /// What History has as the dictation (the paste without the space put in front).
        let text: String
        let entry: UUID
        let started: TimeInterval
        var mode = Mode.probing
        /// Keys applied to the pasted text, in every mode (in readback mode it tells the span's end
        /// apart from text typed right after it, while it agrees with the box). Nil: it gave up.
        var typed: TypedEdit?
        var keys = 0
        var lastKey: TimeInterval
        /// Keys up to here are in the last read.
        var keysRead = 0
        var reading = false
        /// Ends once the read in flight is in.
        var ending = false
        var pauseTimer = false

        init(spot: TextSpot, pasted: String, text: String, entry: UUID, at now: TimeInterval) {
            self.spot = spot
            self.pasted = pasted
            self.text = text
            self.entry = entry
            started = now
            lastKey = now
            typed = TypedEdit(pasted: pasted)
        }
    }

    private var watch: Watch?
    /// A watch is on (tests).
    var isWatching: Bool { watch != nil }

    init(settings: AppSettings, history: HistoryStore, stats: EditWatchStats) {
        self.settings = settings
        self.history = history
        self.stats = stats
    }

    /// Starts watching `spot` after `pasted` went in (leading space included) for History entry
    /// `entry`, whose text is `text`. Ends a watch already on.
    func arm(spot: TextSpot, pasted: String, text: String, entry: UUID) {
        endNow()
        guard settings.learnFromEdits, !secureInput(),
              !settings.excludedApps.contains(where: { $0.bundleID == bundleID(spot.pid) }) else { return }
        let watch = Watch(spot: spot, pasted: pasted, text: text, entry: entry, at: now())
        self.watch = watch
        listen { [weak self] key in self?.key(key) }
        watchApps { [weak self] pid in if pid != watch.spot.pid { self?.end(watch, read: true) } }
        after(Self.probeDelay) { [weak self] in self?.probe(watch) }
        scheduleQuiet(watch, in: Self.quietLimit)
        after(Self.timeLimit) { [weak self] in self?.end(watch, read: true) }
    }

    /// A new dictation is starting, or the app is pressing Return itself (the Enter button: a key the
    /// tap doesn't pass on): the watch ends from what it has, with no read (nothing waits on it).
    func endNow() {
        guard let watch else { return }
        end(watch, read: false)
    }

    // MARK: Steps

    private func probe(_ watch: Watch) {
        guard watch === self.watch else { return }
        let spot = watch.spot, read = self.read, isSecureField = self.isSecureField, toMain = self.toMain
        background { [weak self] in
            let secure = isSecureField(spot)
            let box = secure ? nil : read(spot)
            toMain { self?.probed(watch, secure: secure, box: box) }
        }
    }

    private func probed(_ watch: Watch, secure: Bool, box: Read?) {
        guard watch === self.watch else { return }
        guard !secure else { return stop() }  // a password field: as if never armed
        let app = watch.spot.name
        record { $0.armed(in: app) }
        if let box, box.focused, let tracker = SpanTracker(value: box.value, cursor: box.cursor, pasted: watch.pasted) {
            watch.mode = .readback(tracker)
            // Keys typed before this read may not be in it: read again once typing pauses.
            if watch.keys > 0 { schedulePause(watch) }
            // A click may have moved the cursor or sent the text: read now, before anything else changes.
            watchClicks { [weak self] in self?.readInBackground(watch) }
            return
        }
        record { $0.probeFailed(in: app) }
        guard watch.typed != nil, !inputMethodActive() else { return giveUp(watch) }
        watch.mode = .keystrokes
        watchClicks { [weak self] in self?.giveUp(watch) }
    }

    /// A key-down, from the event tap, before the app gets it. Only in-memory work here, except
    /// before a Return (`returnReadLimit`).
    private func key(_ key: EditKey) {
        guard let watch else { return }
        watch.keys += 1
        watch.lastKey = now()
        if key.action == .returnKey { return returnPressed(watch) }
        switch watch.mode {
        case .probing:
            if watch.typed?.apply(key) == false { watch.typed = nil }
        case .readback:
            if watch.typed?.apply(key) == false { watch.typed = nil }
            schedulePause(watch)
        case .keystrokes:
            if inputMethodActive() || watch.typed?.apply(key) != true { giveUp(watch) }
        }
    }

    /// The last read (only if keys were pressed since the one before), held to `returnReadLimit`,
    /// then the watch ends; what's saved is saved once the Return has gone on.
    private func returnPressed(_ watch: Watch) {
        if case .readback = watch.mode, watch.keys - 1 > watch.keysRead, let box = readWithin(watch.spot, Self.returnReadLimit) {
            take(box, into: watch)
        }
        if watch === self.watch { end(watch, read: false) }
    }

    /// Reads on a background thread and waits at most `limit` for it.
    private func readWithin(_ spot: TextSpot, _ limit: TimeInterval) -> Read? {
        let result = ReadBox()
        let done = DispatchSemaphore(value: 0)
        let read = self.read
        background {
            result.set(read(spot))
            done.signal()
        }
        return done.wait(timeout: .now() + limit) == .success ? result.get() : nil
    }

    private func schedulePause(_ watch: Watch) {
        guard !watch.pauseTimer else { return }
        watch.pauseTimer = true
        after(Self.pause) { [weak self] in self?.pauseFired(watch) }
    }

    /// One timer for the pause, re-armed for what's left while keys keep coming.
    private func pauseFired(_ watch: Watch) {
        watch.pauseTimer = false
        guard watch === self.watch else { return }
        let quiet = now() - watch.lastKey
        if quiet < Self.pause - Self.slack {
            watch.pauseTimer = true
            after(Self.pause - quiet) { [weak self] in self?.pauseFired(watch) }
            return
        }
        readInBackground(watch)
    }

    private func scheduleQuiet(_ watch: Watch, in delay: TimeInterval) {
        after(delay) { [weak self] in
            guard let self, watch === self.watch else { return }
            let quiet = self.now() - watch.lastKey
            if quiet >= Self.quietLimit - Self.slack { self.end(watch, read: true) } else { self.scheduleQuiet(watch, in: Self.quietLimit - quiet) }
        }
    }

    /// Reads the box off the main thread and takes the read in (one at a time); a watch that's
    /// `ending` finishes once it's in.
    private func readInBackground(_ watch: Watch) {
        guard case .readback = watch.mode, !watch.reading else { return }
        watch.reading = true
        let keys = watch.keys, spot = watch.spot, read = self.read, toMain = self.toMain
        background { [weak self] in
            let box = read(spot)
            toMain {
                guard let self else { return }
                watch.reading = false
                guard watch === self.watch else { return }
                guard let box else { return self.finish(watch) }  // the app stopped answering: what it had
                self.take(box, into: watch, keys: keys)
                if watch.ending { self.finish(watch) }
            }
        }
    }

    /// A read: the tracker follows it; a change it can't follow, or the box losing the focus, ends
    /// the watch on what it had.
    private func take(_ box: Read, into watch: Watch, keys: Int? = nil) {
        guard case .readback(var tracker) = watch.mode else { return }
        guard !secureInput() else { return stop() }
        // Followed, and either still an edit of the paste or your keys say it is.
        let followed = tracker.update(box.value)
            && (tracker.sharesAWordWithThePaste || watch.typed?.span == tracker.span)
        if followed { watch.mode = .readback(tracker) }
        watch.keysRead = keys ?? watch.keys
        if !followed || !box.focused { end(watch, read: false) }
    }

    /// Ends the watch: `read`, one last read first (readback, keys since the last one).
    private func end(_ watch: Watch, read: Bool) {
        guard watch === self.watch else { return }
        if read, case .readback = watch.mode, watch.keys > watch.keysRead || watch.reading {
            listen(nil)  // no more keys; the read decides
            watch.ending = true
            return readInBackground(watch)
        }
        finish(watch)
    }

    /// Saves the capture, if the edit changed any word: worked out and saved after whatever's in
    /// progress (a Return the tap is holding, a dictation starting). Ended before the probe had an
    /// answer, nothing is kept (it hadn't checked for a password field yet).
    private func finish(_ watch: Watch) {
        guard watch === self.watch else { return }
        let span: String?, mode: Capture.Mode
        switch watch.mode {
        case .readback(let tracker): span = Self.span(tracker.span, typed: watch.typed); mode = .readback
        case .keystrokes: span = watch.typed?.span; mode = .keystrokes
        case .probing: span = nil; mode = .keystrokes
        }
        stop()
        guard let span, !secureInput() else { return }
        let text = watch.text, entry = watch.entry, app = watch.spot.name
        toMain { [weak self] in
            let edited = span.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self, !FixIntake.changes(from: text, to: edited).isEmpty else { return }
            self.history.setCapture(Capture(edited: edited, mode: mode, app: app), for: entry)
            self.onCapture()
        }
    }

    /// The read span, less text typed right after it in the same burst (a read can't tell them
    /// apart: "cloud." → "Claude. and more"), when your keys agree with the box: they know where the
    /// span ended.
    static func span(_ read: String, typed: TypedEdit?) -> String {
        guard let typed, read != typed.span, read.hasPrefix(typed.span), String(typed.chars).hasPrefix(read) else { return read }
        return typed.span
    }

    /// Keystroke mode can't follow this: nothing is kept.
    private func giveUp(_ watch: Watch) {
        guard watch === self.watch else { return }
        let app = watch.spot.name
        record { $0.gaveUp(in: app) }
        stop()
    }

    private func stop() {
        watch = nil
        listen(nil)
        watchClicks(nil)
        watchApps(nil)
    }

    /// Counts are saved after the key or read that caused them has gone on.
    private func record(_ change: @escaping (EditWatchStats) -> Void) {
        let stats = self.stats
        toMain { change(stats) }
    }

    private final class ReadBox: @unchecked Sendable {
        private var value: Read?
        private let lock = NSLock()
        func set(_ read: Read?) { lock.withLock { value = read } }
        func get() -> Read? { lock.withLock { value } }
    }

    // MARK: The real Mac

    /// The box's value, insertion point and focus, each with the 0.1 s limit `TextSpot` sets.
    static func readBox(_ spot: TextSpot) -> Read? {
        guard let field = spot.field else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        var selection: CFTypeRef?
        var range = CFRange()
        var cursor: Int?
        if AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &selection) == .success,
           let selection, CFGetTypeID(selection) == AXValueGetTypeID(),
           AXValueGetValue(selection as! AXValue, .cfRange, &range), range.length == 0 {
            cursor = range.location
        }
        return Read(value: text, cursor: cursor, focused: TextSpot.hasFocus(spot))
    }

    static func isSecureField(_ spot: TextSpot) -> Bool {
        guard let field = spot.field else { return false }
        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXSubroleAttribute as CFString, &subrole) == .success else { return false }
        return (subrole as? String) == kAXSecureTextFieldSubrole as String
    }

    static func inputMethodActive() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let type = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return false }
        let kind = Unmanaged<CFString>.fromOpaque(type).takeUnretainedValue()
        return kind != kTISTypeKeyboardLayout
    }

    /// A passive monitor (a copy of each click; never holds one back), there only while asked for.
    static func clickMonitor() -> ((() -> Void)?) -> Void {
        var monitor: Any?
        return { handler in
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = handler.flatMap { handler in
                NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in handler() }
            }
        }
    }

    static func appMonitor() -> (((pid_t) -> Void)?) -> Void {
        var observer: NSObjectProtocol?
        return { handler in
            if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            observer = handler.map { handler in
                NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                  object: nil, queue: .main) { note in
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    handler(app?.processIdentifier ?? 0)
                }
            }
        }
    }
}

/// How the edit watcher has fared in each app: watches armed, readback probes that failed (the
/// app doesn't say what's in its box, so keystroke mode was used), and keystroke-mode give-ups.
/// Counts and app names only, in edit-watch.json.
final class EditWatchStats: ObservableObject {
    struct App: Codable, Equatable {
        var armed = 0
        var probesFailed = 0
        var gaveUp = 0
    }

    static let defaultFileURL = AppPaths.file("edit-watch.json")
    let fileURL: URL
    @Published private(set) var apps: [String: App]

    init(fileURL: URL = EditWatchStats.defaultFileURL) {
        self.fileURL = fileURL
        apps = JSONFile.read([String: App].self, from: fileURL) ?? [:]
    }

    func armed(in app: String) { change(app) { $0.armed += 1 } }
    func probeFailed(in app: String) { change(app) { $0.probesFailed += 1 } }
    func gaveUp(in app: String) { change(app) { $0.gaveUp += 1 } }

    private func change(_ app: String, _ update: (inout App) -> Void) {
        update(&apps[app, default: App()])
        JSONFile.save(apps, to: fileURL)
    }
}
