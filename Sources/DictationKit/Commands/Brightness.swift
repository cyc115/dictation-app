import AppKit

/// The brightness command. With BetterDisplay (https://betterdisplay.pro) running: the display the
/// pointer is on, external monitors too (BetterDisplay does their DDC). Else the displays macOS can
/// set itself (the built-in one) through DisplayServices; external monitors need DDC, which macOS
/// doesn't do, so it says so instead.
enum Brightness {
    static let betterDisplayID = "pro.betterdisplay.BetterDisplay"

    static func set(_ choice: String?) async -> CommandResult {
        guard SystemCommands.level(choice, from: 0) != nil, let choice else { return CommandResult(ok: false, message: "No brightness given") }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: betterDisplayID).first?.executableURL,
           let display = pointerDisplay() {
            let level = await Task.detached { withBetterDisplay(app, display: display, choice: choice) }.value
            if let level { return CommandResult(ok: true, message: "Brightness \(Int(level.rounded()))%") }
        }
        return builtIn(choice)
    }

    /// The display the mouse pointer is on.
    static func pointerDisplay() -> CGDirectDisplayID? {
        guard let point = CGEvent(source: nil)?.location else { return nil }
        var display: CGDirectDisplayID = 0, count: UInt32 = 0
        return CGGetDisplaysWithPoint(point, 1, &display, &count) == .success && count == 1 ? display : nil
    }

    /// Sets `display` through BetterDisplay's command line; the new level, or nil to fall back.
    private static func withBetterDisplay(_ app: URL, display: CGDirectDisplayID, choice: String) -> Double? {
        func ask(_ arguments: [String]) -> String? {
            guard case .success(let done) = Subprocess.run(app.path, arguments, timeout: 4),
                  done.status == 0, !done.timedOut else { return nil }
            return done.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let which = "-displayID=\(display)"
        guard let current = ask(["get", which, "-brightness"]).flatMap(Double.init),
              let level = SystemCommands.level(choice, from: current * 100),
              ask(["set", which, String(format: "-brightness=%.3f", level / 100)]) != nil else { return nil }
        return level
    }

    /// Every display macOS can set the brightness of, set through DisplayServices.
    private static func builtIn(_ choice: String) -> CommandResult {
        guard let ds = DisplayServices.loaded else { return CommandResult(ok: false, message: "macOS can't set the brightness here") }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        let settable = ids.prefix(Int(count)).filter { ds.canChange($0) }
        guard !settable.isEmpty else {
            return CommandResult(ok: false, message: "No display whose brightness macOS can set (external monitors need BetterDisplay)")
        }
        var level = 0.0
        for display in settable {
            var now: Float = 0
            _ = ds.get(display, &now)
            level = SystemCommands.level(choice, from: Double(now) * 100) ?? level
            _ = ds.set(display, Float(level / 100))
        }
        return CommandResult(ok: true, message: "Brightness \(Int(level.rounded()))%")
    }

    /// macOS's private DisplayServices, looked up at run time: the built-in display's brightness.
    struct DisplayServices {
        let canChange: @convention(c) (CGDirectDisplayID) -> Bool
        let get: @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        let set: @convention(c) (CGDirectDisplayID, Float) -> Int32

        static let loaded: DisplayServices? = {
            guard let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
                  let canChange = dlsym(library, "DisplayServicesCanChangeBrightness"),
                  let get = dlsym(library, "DisplayServicesGetBrightness"),
                  let set = dlsym(library, "DisplayServicesSetBrightness") else { return nil }
            return DisplayServices(canChange: unsafeBitCast(canChange, to: (@convention(c) (CGDirectDisplayID) -> Bool).self),
                                   get: unsafeBitCast(get, to: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self),
                                   set: unsafeBitCast(set, to: (@convention(c) (CGDirectDisplayID, Float) -> Int32).self))
        }()
    }
}
