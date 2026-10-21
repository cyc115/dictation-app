import AppKit
import SwiftUI
import XCTest
@testable import DictationKit

/// Drives the real views through the accessibility tree, the same way assistive tech
/// (and a user) would, and checks the app state they change.
final class SettingsUITests: XCTestCase {
    private func host(_ settings: AppSettings, history: HistoryStore? = nil) -> HostedView<SettingsView> {
        let history = history ?? HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        let hosted = HostedView(SettingsView(services: makeServices(self, settings: settings, history: history)),
                                size: NSSize(width: 640, height: 3000))
        addTeardownBlock { hosted.close() }
        return hosted
    }

    func testEverySettingIsReachable() {
        let hosted = host(makeSettings(self))
        for title in ["Appearance", "Launch app at login", "Show app in Dock", "Microphone",
                      "Interaction sounds", "Mute when dictating", "Hotkey", "Activation",
                      "Mouse button", "AI polish", "Model", "On-device model", "Keep history", "Keep recordings",
                      "Backup model when slow", "Pause in these apps", "Show detailed analytics",
                      "Mouse button for Enter", "Enter button", "Command mode", "Commands folder"] {
            XCTAssertNotNil(hosted.element(id: "setting." + title), "missing control: \(title)")
        }
    }

    func testTogglesChangeAndPersistSettings() {
        let defaults = makeDefaults(self)
        let settings = makeSettings(self, defaults: defaults)
        let hosted = host(settings)
        for (title, read) in [("Interaction sounds", { settings.interactionSounds }),
                              ("Mute when dictating", { settings.muteWhileDictating }),
                              ("Show app in Dock", { settings.showInDock }),
                              ("AI polish", { settings.polishEnabled }),
                              ("Keep recordings", { settings.keepRecordings }),
                              ("Show detailed analytics", { settings.showDetailedAnalytics })] as [(String, () -> Bool)] {
            let before = read()
            guard let toggle = hosted.element(id: "setting." + title) else { XCTFail("no \(title)"); continue }
            XCTAssertTrue(hosted.click(toggle), "\(title) not clickable")
            XCTAssertEqual(read(), !before, "\(title) did not flip")
        }
        let reloaded = makeSettings(self, defaults: defaults)
        XCTAssertFalse(reloaded.interactionSounds)
        XCTAssertTrue(reloaded.muteWhileDictating)
        XCTAssertTrue(reloaded.showInDock)
        XCTAssertTrue(reloaded.polishEnabled)
        XCTAssertTrue(reloaded.keepRecordings)
        XCTAssertTrue(reloaded.showDetailedAnalytics)
    }

    func testRecordingsFolderOnlyShownWhileKeepingRecordings() {
        let settings = makeSettings(self)
        let hosted = host(settings)
        XCTAssertNil(hosted.element(id: "setting.Recordings folder"))
        guard let toggle = hosted.element(id: "setting.Keep recordings") else { return XCTFail("no toggle") }
        XCTAssertTrue(hosted.click(toggle))
        hosted.settle()
        XCTAssertNotNil(hosted.element(id: "setting.Recordings folder"))
    }

    func testKeepHistoryLivesInSettings() {
        let defaults = makeDefaults(self)
        let history = HistoryStore(fileURL: makeTempURL(self), defaults: defaults)
        let hosted = host(makeSettings(self), history: history)
        XCTAssertNotNil(hosted.element(id: "setting.Keep history"))
        history.retention = .days30
        hosted.settle()
        XCTAssertEqual(HistoryStore(fileURL: makeTempURL(self), defaults: defaults).retention, .days30, "remembered")
    }

    func testBackupModelForCloudModelsOnByDefaultAndPersists() {
        let defaults = makeDefaults(self)
        let settings = makeSettings(self, defaults: defaults)
        XCTAssertTrue(settings.backupWhenSlow, "on by default")
        let hosted = host(settings)
        let id = "setting.Backup model when slow"
        XCTAssertEqual(hosted.element(id: id)?.object.value(forKey: "accessibilityEnabled") as? Bool, false,
                       "On-device has no backup")

        settings.setOpenRouterKey("sk-or-v1-test")
        settings.setup = .cloudFlash
        hosted.settle()
        XCTAssertTrue(settings.effectiveBackup)
        guard let toggle = hosted.element(id: id) else { return XCTFail("no toggle") }
        XCTAssertTrue(hosted.click(toggle))
        XCTAssertFalse(settings.backupWhenSlow)
        XCTAssertFalse(makeSettings(self, defaults: defaults).backupWhenSlow,
                       "turning it off is remembered")
        XCTAssertTrue(hosted.click(toggle))

        settings.setup = .cloudBig
        hosted.settle()
        XCTAssertTrue(settings.effectiveBackup, "Cloud Big falls back to Cloud Flash")
        XCTAssertEqual(hosted.element(id: id)?.object.value(forKey: "accessibilityEnabled") as? Bool, true)

        settings.setup = .onDevice
        hosted.settle()
        XCTAssertFalse(settings.effectiveBackup)
        XCTAssertEqual(hosted.element(id: id)?.value, "0", "unavailable toggle shows off")
        XCTAssertTrue(settings.backupWhenSlow, "the saved choice is kept")
    }

    func testPolishRunsWhereTheSpeechModelRuns() {
        let settings = makeSettings(self)
        settings.polishEnabled = true
        let hosted = host(settings)
        XCTAssertTrue(settings.setup.polishesOnDevice, "On-device speech: nothing leaves the Mac")
        XCTAssertTrue(hosted.allText.contains("nothing leaves it"))
        settings.setOpenRouterKey("sk-or-v1-test")
        for model in [DictationSetup.cloudFlash, .cloudBig] {
            settings.setup = model
            hosted.settle()
            XCTAssertFalse(settings.setup.polishesOnDevice, model.title)
            XCTAssertTrue(hosted.allText.contains("with a cloud model"), model.title)
        }
        XCTAssertNil(hosted.element(id: "setting.Polish model"), "no separate choice: it follows the speech model")
    }

    func testAPIKeyRowOnlyForCloudModels() {
        let settings = makeSettings(self)
        let hosted = host(settings)
        XCTAssertNil(hosted.element(id: "setting.Cloud API key"), "key row only for cloud models")
        settings.setOpenRouterKey("sk-or-v1-test")
        for setup in [DictationSetup.cloudBig, .cloudFlash] {
            settings.setup = setup
            hosted.settle()
            XCTAssertNotNil(hosted.element(id: "setting.Cloud API key"), "same key for every cloud model")
        }
    }

    func testNoVendorOrModelNamesInSettings() {
        let settings = makeSettings(self)
        settings.setOpenRouterKey("sk-or-v1-test")
        let hosted = host(settings)
        for model in DictationSetup.builtIns {
            settings.setup = model
            hosted.settle()
            let text = hosted.allText.lowercased()
            for banned in ["openrouter", "muse", "qwen", "meta", "alibaba", "sk-or"] {
                XCTAssertFalse(text.contains(banned), "\(model.title): settings mention \(banned)")
            }
        }
    }

    func testEnterButtonGreyedOutWhileMouseEnterIsOff() {
        let settings = makeSettings(self)
        let hosted = host(settings)
        func enabled() -> Bool? {
            hosted.element(id: "setting.Enter button")?.object.value(forKey: "accessibilityEnabled") as? Bool
        }
        XCTAssertEqual(enabled(), true)
        XCTAssertTrue(hosted.element(id: "setting.Mouse button for Enter").map { hosted.click($0) } ?? false)
        XCTAssertFalse(settings.mouseEnterEnabled)
        XCTAssertEqual(enabled(), false)
    }

    func testCommandModeGreyedOutWithoutTheAPIKey() {
        let settings = makeSettings(self)
        let hosted = host(settings)
        func enabled() -> Bool? {
            hosted.element(id: "setting.Command mode")?.object.value(forKey: "accessibilityEnabled") as? Bool
        }
        XCTAssertEqual(enabled(), false)
        XCTAssertFalse(settings.commandModeOn)
        XCTAssertNotNil(hosted.element(id: "badge.Command mode"), "says it's online, not on-device")
        settings.setOpenRouterKey("test-key")
        spinRunLoop(0.1)
        XCTAssertEqual(enabled(), true)
        XCTAssertTrue(settings.commandModeOn)
    }

    func testExcludedAppsListedAndRemovable() {
        let settings = makeSettings(self)
        settings.exclude(ExcludedApp(bundleID: "com.example.game", name: "Some Game"))
        let hosted = host(settings)
        XCTAssertTrue(hosted.allText.contains("Some Game"))
        let remove = try? XCTUnwrap(hosted.element(id: "excluded.remove.com.example.game"))
        XCTAssertTrue(remove.map { hosted.click($0) } ?? false)
        XCTAssertEqual(settings.excludedApps, [])
        XCTAssertFalse(hosted.allText.contains("Some Game"))
    }

    func testFnTipOnlyShownForFn() {
        let settings = makeSettings(self)
        let hosted = host(settings)
        func tipShown() -> Bool { hosted.allText.contains("Press 🌐 key to") }
        XCTAssertTrue(tipShown())
        settings.hotkey = .rightCommand
        hosted.settle()
        XCTAssertFalse(tipShown())
    }
}
