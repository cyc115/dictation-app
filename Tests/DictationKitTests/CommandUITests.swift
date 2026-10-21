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

    func testSettingsListsTheCommands() {
        let hosted = HostedView(SettingsView(services: makeServices(self)), size: NSSize(width: 640, height: 3000))
        addTeardownBlock { hosted.close() }
        for name in Command.builtIn.map(\.name) {
            XCTAssertNotNil(hosted.element(id: "command." + name), "missing \(name)")
        }
        XCTAssertNil(hosted.element(id: "command.switch.volume"), "built-ins can't be turned off")
    }

    func testANewScriptShowsUpWithoutReopening() throws {
        let folder = makeTempURL(self, "Commands")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let hosted = HostedView(Form { CommandsList(folder: folder) }.formStyle(.grouped), size: NSSize(width: 640, height: 600))
        addTeardownBlock { hosted.close() }
        XCTAssertNil(hosted.element(id: "command.battery"))
        try "\"\"\"Say the battery level.\"\"\"\n".write(to: folder.appendingPathComponent("battery.py"), atomically: true, encoding: .utf8)
        waitUntil { hosted.element(id: "command.battery") != nil }
        XCTAssertNotNil(hosted.element(id: "command.battery"), "a create command or a saved script shows right away")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("battery.py"))
        waitUntil { hosted.element(id: "command.battery") == nil }
        XCTAssertNil(hosted.element(id: "command.battery"))
    }

    func testASwitchTurnsAScriptOffAndOn() throws {
        let services = makeServices(self)
        let folder = services.commands.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "\"\"\"Say the battery level.\"\"\"\n".write(to: folder.appendingPathComponent("battery.py"), atomically: true, encoding: .utf8)
        let hosted = HostedView(Form { CommandsList(folder: folder) }.formStyle(.grouped), size: NSSize(width: 640, height: 900))
        addTeardownBlock { hosted.close() }
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "command.switch.battery"))))
        XCTAssertEqual(Command.disabled(in: folder).map(\.name), ["battery"])
        XCTAssertNotNil(hosted.element(id: "command.battery"), "still listed, to turn back on")
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "command.switch.battery"))))
        XCTAssertEqual(Command.disabled(in: folder), [])
        XCTAssertTrue(Command.all(in: folder).contains { $0.name == "battery" })
    }
}
