import XCTest
@testable import DictationKit

/// `DictationApp settings …`, run against test settings with captured output; nothing reaches the
/// running app (`notify` only counts).
final class SettingsCommandTests: XCTestCase {
    private var out: [String] = []
    private var err: [String] = []
    private var notified = 0
    private var input: String?

    private var io: SettingsCommand.IO {
        SettingsCommand.IO(out: { self.out.append($0) }, err: { self.err.append($0) },
                           input: { self.input }, notify: { self.notified += 1 })
    }

    @discardableResult
    private func run(_ args: String..., settings: AppSettings) -> Int32 {
        out = []; err = []
        return SettingsCommand.run(args, settings: settings, io: io)
    }

    /// Every `@Setting` in Settings.swift is on the command line, so a new one can't be left out.
    func testEverySettingIsListed() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/DictationKit/Settings/Settings.swift").standardizedFileURL
        let declared = try String(contentsOf: source, encoding: .utf8).components(separatedBy: "@Setting(\"").dropFirst()
            .compactMap { $0.split(separator: "\"").first.map(String.init) }
        XCTAssertGreaterThan(declared.count, 15)
        let names = SettingsCommand.entries(makeSettings(self), io: io).map(\.name)
        XCTAssertEqual(Set(declared).subtracting(names), [])
        for name in ["setup", "launchAtLogin", "excludedApps", "openRouterKey"] { XCTAssertTrue(names.contains(name), name) }
        XCTAssertEqual(names.count, Set(names).count, "no name twice")
    }

    func testListShowsValuesAndChoices() {
        let s = makeSettings(self)
        XCTAssertEqual(run(settings: s), 0)
        let setup = out.first { $0.hasPrefix("setup ") }
        XCTAssertEqual(setup?.contains("on-device  [on-device | cloud-flash]"), true, setup ?? "")
        XCTAssertTrue(out.contains { $0.hasPrefix("aiPolishEnabled ") && $0.contains("off  [on | off]") })
        XCTAssertEqual(notified, 0)
    }

    func testListAsJSON() throws {
        let s = makeSettings(self)
        XCTAssertEqual(run("list", "--json", settings: s), 0)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.joined().utf8)) as? [[String: Any]])
        let polish = try XCTUnwrap(rows.first { $0["name"] as? String == "aiPolishEnabled" })
        XCTAssertEqual(polish["value"] as? Bool, false, "on/off settings are JSON booleans")
        let setup = try XCTUnwrap(rows.first { $0["name"] as? String == "setup" })
        XCTAssertEqual(setup["value"] as? String, "on-device")
        XCTAssertEqual(setup["choices"] as? [String], ["on-device", "cloud-flash"])
    }

    func testSetSetupSavesNotifiesAndPrints() {
        let defaults = makeDefaults(self)
        let s = makeSettings(self, defaults: defaults)
        var changes = 0
        s.onChange = { changes += 1 }
        XCTAssertEqual(run("set", "setup", "cloud-flash", settings: s), 0)
        XCTAssertEqual(s.setup, .cloudFlash)
        XCTAssertEqual(out, ["setup = cloud-flash"])
        XCTAssertEqual(notified, 1)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(makeSettings(self, defaults: defaults).setup, .cloudFlash, "saved")
        run("get", "setup", settings: s)
        XCTAssertEqual(out, ["cloud-flash"])
    }

    func testSetTypedSettings() {
        let s = makeSettings(self)
        XCTAssertEqual(run("set", "aiPolishEnabled", "true", settings: s), 0)
        XCTAssertTrue(s.polishEnabled)
        XCTAssertEqual(out, ["aiPolishEnabled = on"])
        XCTAssertEqual(run("set", "hotkey", "rightoption", settings: s), 0, "names and values ignore case")
        XCTAssertEqual(s.hotkey, .rightOption)
        XCTAssertEqual(run("set", "ACTIVATIONMODE", "toggle", settings: s), 0)
        XCTAssertEqual(s.mode, .toggle)
        XCTAssertEqual(run("set", "commandModel", "openai/gpt-5-mini", settings: s), 0)
        XCTAssertEqual(s.commandModel, "openai/gpt-5-mini")
        XCTAssertEqual(run("toggle", "aiPolishEnabled", settings: s), 0)
        XCTAssertFalse(s.polishEnabled)
        XCTAssertEqual(notified, 5)
    }

    func testBadValueOrNameChangesNothing() {
        let s = makeSettings(self)
        XCTAssertEqual(run("set", "hotkey", "capsLock", settings: s), 1)
        XCTAssertEqual(err, ["hotkey can't be \"capsLock\"; it takes: fn, rightCommand, rightOption, rightControl, rightShift"])
        XCTAssertEqual(run("set", "setup", "cloud-huge", settings: s), 1)
        XCTAssertEqual(s.setup, .onDevice)
        XCTAssertEqual(run("set", "nope", "on", settings: s), 1)
        XCTAssertEqual(run("toggle", "hotkey", settings: s), 1, "only on/off settings toggle")
        XCTAssertEqual(run("set", "hotkey", settings: s), 2)
        XCTAssertEqual(s.hotkey, .fn)
        XCTAssertEqual(notified, 0)
    }

    func testReplacedSetupIDMovesToItsSuccessor() {
        let s = makeSettings(self)
        XCTAssertEqual(run("set", "setup", "cloud-big", settings: s), 0)
        XCTAssertEqual(s.setup, .cloudFlash)
        s.setup = .onDevice
        XCTAssertEqual(run("set", "setup", "cloud-flash-deepseek", settings: s), 0)
        XCTAssertEqual(s.setup, .cloudFlash)
    }

    func testAPIKeyFromStdinIsNeverPrinted() {
        let s = makeSettings(self)
        input = "sk-or-test\n"
        XCTAssertEqual(run("set", "openRouterKey", "-", settings: s), 0)
        XCTAssertEqual(s.openRouterKey, "sk-or-test")
        XCTAssertEqual(out, ["openRouterKey = set"])
        XCTAssertEqual(run("set", "openRouterKey", "", settings: s), 0)
        XCTAssertNil(s.openRouterKey)
        XCTAssertEqual(out, ["openRouterKey = not set"])
    }

    func testExcludedAppsAreReplacedByTheList() {
        let s = makeSettings(self)
        s.exclude(ExcludedApp(bundleID: "com.example.old", name: "Old"))
        XCTAssertEqual(run("set", "excludedApps", "com.example.game, com.example.other", settings: s), 0)
        XCTAssertEqual(s.excludedApps.map(\.bundleID), ["com.example.game", "com.example.other"])
        XCTAssertEqual(s.excludedApps.first?.name, "com.example.game", "not installed: named by its ID")
        XCTAssertEqual(out, ["excludedApps = com.example.game,com.example.other"])
        XCTAssertEqual(run("set", "excludedApps", "", settings: s), 0)
        XCTAssertEqual(s.excludedApps, [])
    }

    func testMicrophoneDefault() {
        let s = makeSettings(self)
        s.microphoneUID = "some-mic"
        XCTAssertEqual(run("set", "microphoneUID", "default", settings: s), 0)
        XCTAssertEqual(s.microphoneUID, "")
        XCTAssertEqual(out, ["microphoneUID = default"])
        XCTAssertEqual(run("set", "microphoneUID", "No Such Mic \(UUID())", settings: s), 1)
    }

    /// The running app sees what the command saved: a second AppSettings on the same defaults, as the
    /// app's is to the command's.
    func testRunningAppPicksUpChanges() {
        let defaults = makeDefaults(self)
        let app = makeSettings(self, defaults: defaults), command = makeSettings(self, defaults: defaults)
        var changes = 0
        app.onChange = { changes += 1 }
        run("set", "setup", "cloud-flash", settings: command)
        run("set", "excludedApps", "com.example.game", settings: command)
        run("set", "aiPolishEnabled", "on", settings: command)
        XCTAssertEqual(app.setup, .onDevice, "not yet re-read")
        app.reloadFromDefaults()
        XCTAssertEqual(app.setup, .cloudFlash)
        XCTAssertEqual(app.excludedApps.map(\.bundleID), ["com.example.game"])
        XCTAssertTrue(app.polishEnabled)
        XCTAssertGreaterThan(changes, 0, "onChange applies them (hotkey, menu, Dock…)")
    }
}
