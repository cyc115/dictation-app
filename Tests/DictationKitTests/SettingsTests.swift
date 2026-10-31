import XCTest
@testable import DictationKit

final class SettingsTests: XCTestCase {
    func testDefaults() {
        let s = makeSettings(self)
        XCTAssertEqual(s.hotkey, .fn)
        XCTAssertEqual(s.mode, .hold)
        XCTAssertEqual(s.mouseButton, .off)
        XCTAssertFalse(s.polishEnabled)
        XCTAssertEqual(s.microphoneUID, "")
        XCTAssertTrue(s.interactionSounds, "sounds default on")
        XCTAssertFalse(s.muteWhileDictating)
        XCTAssertEqual(s.appearance, .system)
        XCTAssertFalse(s.showInDock)
    }

    func testChangesPersistAndNotify() {
        let defaults = makeDefaults(self)
        let s = makeSettings(self, defaults: defaults)
        var changes = 0
        s.onChange = { changes += 1 }
        s.hotkey = .rightOption
        s.mode = .toggle
        s.mouseButton = .button4
        s.polishEnabled = true
        s.microphoneUID = "mic-1"
        s.interactionSounds = false
        s.muteWhileDictating = true
        s.appearance = .dark
        s.showInDock = true
        XCTAssertEqual(changes, 9)

        let r = makeSettings(self, defaults: defaults)
        XCTAssertEqual(r.hotkey, .rightOption)
        XCTAssertEqual(r.mode, .toggle)
        XCTAssertEqual(r.mouseButton, .button4)
        XCTAssertTrue(r.polishEnabled)
        XCTAssertEqual(r.microphoneUID, "mic-1")
        XCTAssertFalse(r.interactionSounds)
        XCTAssertTrue(r.muteWhileDictating)
        XCTAssertEqual(r.appearance, .dark)
        XCTAssertTrue(r.showInDock)
    }

    func testMouseEnterOnByDefaultWithButton6AndPersists() {
        let defaults = makeDefaults(self)
        let s = makeSettings(self, defaults: defaults)
        XCTAssertEqual(s.mouseEnterButton, .button6)
        XCTAssertEqual(s.commandHotkey, .off, "no command key by default")
        XCTAssertTrue(s.hasCommandTrigger)
        s.mouseEnterButton = .middle
        s.commandHotkey = .rightOption
        let r = makeSettings(self, defaults: defaults)
        XCTAssertEqual(r.commandHotkey, .rightOption)
        XCTAssertEqual(r.mouseEnterButton, .middle)
        r.mouseEnterButton = .off
        XCTAssertTrue(r.hasCommandTrigger, "the key is left")
        r.commandHotkey = .off
        XCTAssertFalse(r.hasCommandTrigger)
    }

    /// "Mouse button for Enter" was a switch beside the button: off becomes the button set to None.
    func testEnterSwitchMigratesToTheButton() {
        for (enabled, button) in [(false, MouseButton.off), (true, .button4)] {
            let defaults = makeDefaults(self)
            defaults.set(enabled, forKey: "mouseEnterEnabled")
            defaults.set("button4", forKey: "mouseEnterButton")
            let s = makeSettings(self, defaults: defaults)
            XCTAssertEqual(s.mouseEnterButton, button, "enabled: \(enabled)")
            XCTAssertNil(defaults.object(forKey: "mouseEnterEnabled"), "the old key is gone")
        }
    }

    func testHint() {
        let s = makeSettings(self)
        XCTAssertEqual(s.hint, "Hold Fn to dictate — release to paste")
        s.hotkey = .rightShift
        s.mode = .toggle
        XCTAssertEqual(s.hint, "Tap Right ⇧ to start — tap again to paste")
        s.hotkey = .off
        XCTAssertEqual(s.hint, "No dictation shortcut — choose one in Settings › Shortcuts")
        s.mouseButton = .button5
        XCTAssertEqual(s.hint, "Press Button 5 (Forward) to start — press again to paste")
    }

    func testUnknownStoredValuesFallBack() {
        let defaults = makeDefaults(self)
        defaults.set("bogus", forKey: "hotkey")
        defaults.set("bogus", forKey: "activationMode")
        let s = makeSettings(self, defaults: defaults)
        XCTAssertEqual(s.hotkey, .fn)
        XCTAssertEqual(s.mode, .hold)
    }

    func testDefaultsAndPersistence() {
        let defaults = makeDefaults(self)
        let s = makeSettings(self, defaults: defaults)
        XCTAssertEqual(s.setup, .onDevice)
        s.setup = .cloudFlash
        let r = makeSettings(self, defaults: defaults)
        XCTAssertEqual(r.setup, .cloudFlash)
    }

    func testAPIKeyGoesToSecretStoreNotDefaults() {
        let defaults = makeDefaults(self)
        let secrets = InMemorySecretStore()
        let s = makeSettings(self, defaults: defaults, secrets: secrets)
        XCTAssertFalse(s.hasOpenRouterKey)
        s.setOpenRouterKey("  sk-or-v1-test  ")
        XCTAssertTrue(s.hasOpenRouterKey)
        XCTAssertEqual(secrets.get(AppSettings.openRouterAccount), "sk-or-v1-test")
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { "\($0)".contains("sk-or") })
        s.setOpenRouterKey("")
        XCTAssertFalse(s.hasOpenRouterKey)
    }
}

final class AppVersionTests: XCTestCase {
    func testReadsStampedInfo() {
        let v = AppVersion(info: ["CFBundleShortVersionString": "1.0.25", "CFBundleVersion": "525e456",
                                  "DictationBuildDate": "2026-10-07T06:05:00Z"])
        XCTAssertEqual(v.version, "1.0.25")
        XCTAssertEqual(v.short, "Version 1.0.25 (525e456)")
        XCTAssertNotNil(v.built)
        XCTAssertTrue(v.long.hasPrefix("Version 1.0.25 (525e456) · built "), v.long)
    }

    func testUnstampedBuildSaysDev() {
        let v = AppVersion(info: [:])
        XCTAssertEqual(v.short, "Version dev (-)")
        XCTAssertEqual(v.long, v.short)
    }
}
