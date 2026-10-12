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
        XCTAssertFalse(s.streamWhileSpeaking, "type-as-you-speak is off by default")
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
        s.streamWhileSpeaking = true
        XCTAssertEqual(changes, 10)

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
        XCTAssertTrue(r.streamWhileSpeaking)
    }

    func testMouseEnterOnByDefaultWithButton6AndPersists() {
        let defaults = makeDefaults(self)
        let s = makeSettings(self, defaults: defaults)
        XCTAssertTrue(s.mouseEnterEnabled)
        XCTAssertEqual(s.effectiveEnterButton, .button6)
        s.mouseEnterButton = .middle
        s.mouseEnterEnabled = false
        XCTAssertEqual(s.effectiveEnterButton, .off, "off keeps the chosen button")
        let r = makeSettings(self, defaults: defaults)
        XCTAssertFalse(r.mouseEnterEnabled)
        XCTAssertEqual(r.mouseEnterButton, .middle)
    }

    func testHint() {
        let s = makeSettings(self)
        XCTAssertEqual(s.hint, "Hold Fn to dictate — release to paste")
        s.hotkey = .rightShift
        s.mode = .toggle
        XCTAssertEqual(s.hint, "Tap Right ⇧ to start — tap again to paste")
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
        XCTAssertEqual(s.localLanguage, .english)
        s.setup = .cloudBig
        s.localLanguage = .mandarin
        let r = makeSettings(self, defaults: defaults)
        XCTAssertEqual(r.setup, .cloudBig)
        XCTAssertEqual(r.localLanguage, .mandarin)
    }

    func testStreamingDisabledForCloudButRemembered() {
        let s = makeSettings(self)
        s.streamWhileSpeaking = true
        XCTAssertTrue(s.effectiveStreaming)
        s.setup = .cloudBig
        XCTAssertFalse(s.effectiveStreaming, "batch model can't stream")
        XCTAssertTrue(s.streamWhileSpeaking, "the saved preference survives")
        s.setup = .onDevice
        XCTAssertTrue(s.effectiveStreaming, "and comes back with the local model")
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
