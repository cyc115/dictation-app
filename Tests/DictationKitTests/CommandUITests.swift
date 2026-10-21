import AppKit
import SwiftUI
import XCTest
@testable import DictationKit

final class CommandUITests: XCTestCase {
    func testHistoryShowsTheCommandsSwitchOnlyOnceThereAreCommands() {
        let store = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        store.add(text: "hello", duration: 1)
        let hosted = HostedView(HistoryView(store: store), size: NSSize(width: 760, height: 400))
        addTeardownBlock { hosted.close() }
        XCTAssertNil(hosted.element(id: "history.list"))
        store.addCommand(CommandRun(said: "mute", command: "volume", choice: "mute", ok: true, result: "Muted"))
        spinRunLoop(0.05)
        XCTAssertNotNil(hosted.element(id: "history.list"))
        XCTAssertEqual(hosted.elements(id: "history.row").count, 1, "dictations until you switch")
        XCTAssertEqual(hosted.elements(id: "history.command").count, 0)
    }

    func testRunAgainRunsTheCommandAsItWas() {
        let store = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        store.addCommand(CommandRun(said: "brighter", command: "volume", choice: "+10", ok: true, result: "Volume 50%"))
        let mode = CommandMode(folder: makeTempURL(self, "Commands"), history: store)
        var ran: [String] = []
        fakeSystem(mode, message: "Volume 60%") { ran.append($0) }
        let hosted = HostedView(HistoryView(store: store, commandMode: mode, shown: .commands), size: NSSize(width: 760, height: 400))
        addTeardownBlock { hosted.close() }
        XCTAssertEqual(hosted.elements(id: "history.command").count, 1)
        XCTAssertTrue(hosted.click(try! XCTUnwrap(hosted.element(id: "history.runAgain"))))
        waitUntil { store.commands.count == 2 }
        XCTAssertEqual(ran, ["volume +10"])
        XCTAssertEqual(store.commands.first?.result, "Volume 60%")
    }

    private let battery = "\"\"\"Say the battery level.\"\"\"\nprint('Battery 80%')\n"
    private let window = "\"\"\"Tile the front window.\n\nChoices:\n    left: the left half\n    right: the right half\n\"\"\"\n"

    /// The Commands tab over a throwaway folder holding `scripts`; deleting removes the file (never
    /// to your Trash).
    private func commandsTab(_ scripts: [String: String], services: AppServices? = nil, search: String = "",
                             onOpenSettings: (() -> Void)? = nil) throws -> (HostedView<CommandsView>, URL, AppServices) {
        let services = services ?? makeServices(self)
        let folder = services.commands.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in scripts { try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let view = CommandsView(mode: services.commands, settings: services.settings, history: services.history, search: search,
                                onOpenSettings: onOpenSettings, trash: { try FileManager.default.removeItem(at: $0) })
        let hosted = HostedView(view, size: NSSize(width: 760, height: 1400))
        addTeardownBlock { hosted.close() }
        return (hosted, folder, services)
    }

    func testTheCommandsTabListsYoursAndTheBuiltIns() throws {
        let (hosted, _, _) = try commandsTab(["battery.py": battery])
        for name in Command.builtIn.map(\.name) + ["battery"] {
            XCTAssertNotNil(hosted.element(id: "command." + name), "missing \(name)")
        }
        XCTAssertNil(hosted.element(id: "command.switch.volume"), "built-ins can't be turned off")
        XCTAssertNil(hosted.element(id: "command.delete.volume"), "or deleted")
        XCTAssertNotNil(hosted.element(id: "command.delete.battery"))
    }

    func testSettingsTurnsCommandModeOnAndSendsYouToTheTab() {
        let services = makeServices(self)
        var shown = 0
        let hosted = HostedView(SettingsView(services: services, onShowCommands: { shown += 1 }), size: NSSize(width: 640, height: 3000))
        addTeardownBlock { hosted.close() }
        XCTAssertNotNil(hosted.element(id: "setting.Command mode"))
        XCTAssertNil(hosted.element(id: "command.volume"), "the list is in the Commands tab")
        XCTAssertTrue(hosted.click(try! XCTUnwrap(hosted.element(id: "setting.Commands"))))
        XCTAssertEqual(shown, 1)
    }

    func testDeletingAScriptAsksFirstThenMovesItOut() throws {
        let (hosted, folder, _) = try commandsTab(["battery.py": battery, "window.py": window])
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "command.delete.battery"))))
        hosted.settle()
        XCTAssertNotNil(hosted.element(id: "command.confirmDelete.battery"), "asks first")
        XCTAssertNil(hosted.element(id: "command.confirmDelete.window"), "only for that one")
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "command.cancelDelete.battery"))))
        hosted.settle()
        XCTAssertNil(hosted.element(id: "command.confirmDelete.battery"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("battery.py").path), "cancel keeps it")
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "command.delete.battery"))))
        hosted.settle()
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "command.confirmDelete.battery"))))
        waitUntil { hosted.element(id: "command.battery") == nil }
        XCTAssertNil(hosted.element(id: "command.battery"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("battery.py").path))
        XCTAssertNotNil(hosted.element(id: "command.window"))
    }

    func testDeletingATurnedOffScriptWorksToo() throws {
        let (hosted, folder, _) = try commandsTab(["battery.py": battery])
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "command.switch.battery"))))
        XCTAssertEqual(Command.disabled(in: folder).map(\.name), ["battery"])
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "command.delete.battery"))))
        hosted.settle()
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "command.confirmDelete.battery"))))
        waitUntil { Command.disabled(in: folder).isEmpty }
        XCTAssertEqual(Command.disabled(in: folder), [])
    }

    func testSearchFindsCommandsByNameDescriptionOrChoice() throws {
        let (hosted, _, _) = try commandsTab(["battery.py": battery, "window.py": window], search: "left")
        XCTAssertNotNil(hosted.element(id: "command.window"), "a choice")
        XCTAssertNil(hosted.element(id: "command.battery"))
        XCTAssertNil(hosted.element(id: "command.volume"))
        let (byName, _, _) = try commandsTab(["battery.py": battery], search: "BATT")
        XCTAssertNotNil(byName.element(id: "command.battery"))
        let (bySummary, _, _) = try commandsTab([:], search: "lock the screen")
        XCTAssertNotNil(bySummary.element(id: "command.lock-screen"))
        XCTAssertNotNil(bySummary.element(id: "commands.yours.empty"))
    }

    func testEachCommandSaysHowItHasGoneAndYoursSortByLastUse() throws {
        let services = makeServices(self)
        services.history.addCommand(CommandRun(date: fixedDate(2026, 1, 5, 9, 0), said: "tile left", command: "window", choice: "left", ok: true, result: "Tiled"))
        services.history.addCommand(CommandRun(date: fixedDate(2026, 1, 6, 9, 0), said: "battery", command: "battery", ok: true, result: "Battery 80%"))
        services.history.addCommand(CommandRun(date: fixedDate(2026, 1, 7, 9, 0), said: "tile right", command: "window", choice: "right", result: "No window"))
        let (hosted, _, _) = try commandsTab(["battery.py": battery, "window.py": window, "alarm.py": "\"\"\"Set an alarm.\"\"\"\n"], services: services)
        let usage = try XCTUnwrap(hosted.element(id: "command.usage.window"))
        let said = usage.label ?? hosted.allText
        XCTAssertTrue(hosted.allText.contains("Used 2×") && hosted.allText.contains("failed: No window"), said)
        XCTAssertNil(hosted.element(id: "command.usage.alarm"), "never used")
        func order() -> [String] {
            hosted.elements { $0.identifier?.hasPrefix("command.") == true }.compactMap(\.identifier)
                .filter { ["command.alarm", "command.battery", "command.window"].contains($0) }
        }
        XCTAssertEqual(order(), ["command.alarm", "command.battery", "command.window"], "by name")
        let sort = try XCTUnwrap(hosted.elements { $0.object is NSSegmentedControl }.first?.object as? NSSegmentedControl)
        XCTAssertEqual(sort.label(forSegment: 1), "Last used")
        sort.selectedSegment = 1
        XCTAssertTrue(sort.sendAction(sort.action, to: sort.target))
        hosted.settle()
        XCTAssertEqual(order(), ["command.window", "command.battery", "command.alarm"], "newest first, never used last")
    }

    func testWithCommandModeOffTheTabSaysWhereToTurnItOn() throws {
        var opened = 0
        let (hosted, _, services) = try commandsTab([:], onOpenSettings: { opened += 1 })
        XCTAssertFalse(services.settings.commandModeOn)
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "commands.openSettings"))))
        XCTAssertEqual(opened, 1)
    }

    func testANewScriptShowsUpWithoutReopening() throws {
        let (hosted, folder, _) = try commandsTab([:])
        XCTAssertNil(hosted.element(id: "command.battery"))
        try battery.write(to: folder.appendingPathComponent("battery.py"), atomically: true, encoding: .utf8)
        waitUntil { hosted.element(id: "command.battery") != nil }
        XCTAssertNotNil(hosted.element(id: "command.battery"), "a create command or a saved script shows right away")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("battery.py"))
        waitUntil { hosted.element(id: "command.battery") == nil }
        XCTAssertNil(hosted.element(id: "command.battery"))
    }

    func testASwitchTurnsAScriptOffAndOn() throws {
        let (hosted, folder, _) = try commandsTab(["battery.py": battery])
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "command.switch.battery"))))
        XCTAssertEqual(Command.disabled(in: folder).map(\.name), ["battery"])
        XCTAssertNotNil(hosted.element(id: "command.battery"), "still listed, to turn back on")
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "command.switch.battery"))))
        XCTAssertEqual(Command.disabled(in: folder), [])
        XCTAssertTrue(Command.all(in: folder).contains { $0.name == "battery" })
    }
}
