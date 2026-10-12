import XCTest
@testable import DictationKit

final class ExcludedAppsTests: XCTestCase {
    private let game = ExcludedApp(bundleID: "com.example.game", name: "Game")
    private let gfn = ExcludedApp(bundleID: "com.nvidia.gfnpc.mall", name: "GeForce NOW")

    func testPausedOnlyWhileAnExcludedAppIsInFront() {
        let watcher = ExclusionWatcher(excluded: [game, gfn])
        var changes = 0
        watcher.onChange = { changes += 1 }
        watcher.frontmostChanged(to: "com.apple.Safari")
        XCTAssertFalse(watcher.isPaused)
        watcher.frontmostChanged(to: gfn.bundleID)
        XCTAssertEqual(watcher.pausedFor, gfn)
        watcher.frontmostChanged(to: game.bundleID)
        XCTAssertEqual(watcher.pausedFor, game)
        watcher.frontmostChanged(to: nil)
        XCTAssertFalse(watcher.isPaused)
        XCTAssertEqual(changes, 3)
    }

    func testEditingTheListAppliesToTheAppInFront() {
        let watcher = ExclusionWatcher(excluded: [])
        watcher.frontmostChanged(to: game.bundleID)
        XCTAssertFalse(watcher.isPaused)
        watcher.excluded = [game]
        XCTAssertTrue(watcher.isPaused)
        watcher.excluded = []
        XCTAssertFalse(watcher.isPaused)
    }

    func testListPersistsWithoutDuplicates() {
        let defaults = makeDefaults(self)
        let s = makeSettings(self, defaults: defaults)
        XCTAssertEqual(s.excludedApps, [])
        var changes = 0
        s.onChange = { changes += 1 }
        s.exclude(game)
        s.exclude(gfn)
        s.exclude(ExcludedApp(bundleID: game.bundleID, name: "Renamed"))
        XCTAssertEqual(s.excludedApps, [game, gfn])
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(makeSettings(self, defaults: defaults).excludedApps, [game, gfn])
        s.include(game)
        XCTAssertEqual(makeSettings(self, defaults: defaults).excludedApps, [gfn])
    }

    func testReadsNameAndIDFromAnAppBundle() throws {
        let app = makeTempURL(self, "Some Game.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.somegame", "CFBundleName": "SomeGame",
                                   "CFBundleDisplayName": "Some Game", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        XCTAssertEqual(ExcludedApp(appAt: app), ExcludedApp(bundleID: "com.example.somegame", name: "Some Game"))
        XCTAssertNil(ExcludedApp(appAt: makeTempURL(self, "Empty.app")))
    }
}
