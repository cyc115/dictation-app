import SwiftUI
import XCTest
@testable import DictationKit

/// Sparkle's updater, without the network: counts checks and keeps the automatic-check switch.
final class FakeUpdater: UpdaterBackend {
    var automaticallyChecksForUpdates = true
    var lastUpdateCheckDate: Date?
    var canCheckForUpdates = true
    private(set) var checks = 0

    init(lastChecked: Date? = nil) { lastUpdateCheckDate = lastChecked }

    func checkForUpdates() { checks += 1 }
}

final class UpdatesTests: XCTestCase {
    func testCheckNowAsksSparkleOnlyWhenItCan() {
        let fake = FakeUpdater()
        let updates = Updates(backend: fake)
        updates.checkNow()
        XCTAssertEqual(fake.checks, 1)
        fake.canCheckForUpdates = false  // a check is already showing
        updates.checkNow()
        XCTAssertEqual(fake.checks, 1)
    }

    func testOutsideTheInstalledAppThereIsNothingToUpdate() {
        let updates = Updates(backend: nil)
        XCTAssertFalse(updates.isAvailable)
        XCTAssertFalse(updates.automaticallyChecks)
        updates.checkNow()  // no-op, no crash
    }

    func testAvailableUpdateTellsTheMenu() {
        let updates = Updates(backend: FakeUpdater())
        var changes = 0
        updates.onChange = { changes += 1 }
        updates.setAvailable("1.0.220")
        updates.setAvailable("1.0.220")
        XCTAssertEqual(updates.available, "1.0.220")
        XCTAssertEqual(changes, 1, "only on a change")
        updates.setAvailable(nil)
        XCTAssertEqual(changes, 2)
    }

    /// Sparkle quits the app to install: never in the middle of a dictation, but right after it.
    func testInstallWaitsForTheDictation() {
        let updates = Updates(backend: FakeUpdater())
        updates.relaunch.delay = 0
        var busy = false
        updates.relaunch.isBusy = { busy }
        var installs = 0
        XCTAssertFalse(updates.shouldPostpone(install: { installs += 1 }), "idle: install now")
        XCTAssertEqual(installs, 0, "Sparkle installs itself when not postponed")

        busy = true
        XCTAssertTrue(updates.shouldPostpone(install: { installs += 1 }))
        updates.relaunchIfIdle()
        spinRunLoop(0.05)
        XCTAssertEqual(installs, 0, "still dictating")
        busy = false
        updates.relaunchIfIdle()
        waitUntil { installs == 1 }
        updates.relaunchIfIdle()
        spinRunLoop(0.05)
        XCTAssertEqual(installs, 1, "once")
    }
}

final class UpdatesSectionUITests: XCTestCase {
    private func hostSection(_ updates: Updates) -> HostedView<some View> {
        host(Form { UpdatesSection(updates: updates, version: "1.0.213") }.formStyle(.grouped), size: NSSize(width: 640, height: 220))
    }

    func testToggleTurnsDailyChecksOff() {
        let fake = FakeUpdater()
        let hosted = hostSection(Updates(backend: fake))
        guard let toggle = hosted.element(id: "setting.Check for updates automatically") else { return XCTFail("no toggle") }
        XCTAssertTrue(hosted.click(toggle))
        XCTAssertFalse(fake.automaticallyChecksForUpdates)
    }

    func testShowsLastCheckAndChecksNow() {
        let fake = FakeUpdater(lastChecked: fixedDate(2026, 10, 7, 1, 5))
        let hosted = hostSection(Updates(backend: fake))
        XCTAssertTrue(hosted.allText.contains("Last checked Oct 7"), hosted.allText)
        guard let button = hosted.elements(where: { $0.text.contains("Check Now") }).last else { return XCTFail("no button") }
        XCTAssertTrue(hosted.click(button))
        XCTAssertEqual(fake.checks, 1)
    }

    func testFoundUpdateOffersInstall() {
        let fake = FakeUpdater()
        let updates = Updates(backend: fake)
        updates.setAvailable("1.0.220")
        let hosted = hostSection(updates)
        XCTAssertTrue(hosted.allText.contains("Version 1.0.220 is available."), hosted.allText)
        guard let button = hosted.elements(where: { $0.text.contains("Install…") }).last else { return XCTFail("no button") }
        XCTAssertTrue(hosted.click(button))
        XCTAssertEqual(fake.checks, 1, "opens Sparkle's window on the found update")
    }

    func testSaysWhenNotTheInstalledApp() {
        let hosted = hostSection(Updates(backend: nil))
        XCTAssertTrue(hosted.allText.contains("Updates work in the installed app."), hosted.allText)
    }
}
