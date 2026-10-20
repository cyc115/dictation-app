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
        CommandMode.installExamples(into: mode.folder)
        var ran: [String?] = []
        mode.runScript = { _, choice in ran.append(choice); return CommandResult(ok: true, message: "Volume 60%") }
        let hosted = HostedView(HistoryView(store: store, commandMode: mode, shown: .commands), size: NSSize(width: 760, height: 400))
        addTeardownBlock { hosted.close() }
        XCTAssertEqual(hosted.elements(id: "history.command").count, 1)
        XCTAssertTrue(hosted.click(try! XCTUnwrap(hosted.element(id: "history.runAgain"))))
        waitUntil { store.commands.count == 2 }
        XCTAssertEqual(ran, ["+10"])
        XCTAssertEqual(store.commands.first?.result, "Volume 60%")
    }

    func testSettingsListsTheCommands() {
        let hosted = HostedView(SettingsView(services: makeServices(self)), size: NSSize(width: 640, height: 2600))
        addTeardownBlock { hosted.close() }
        for name in ["return", "repeat", "create", "open", "brightness", "volume"] {
            XCTAssertNotNil(hosted.element(id: "command." + name), "missing \(name)")
        }
        XCTAssertNil(hosted.element(id: "command.switch.repeat"), "built-ins can't be turned off")
    }

    func testANewScriptShowsUpWithoutReopening() throws {
        let folder = makeTempURL(self, "Commands")
        CommandMode.installExamples(into: folder)
        let hosted = HostedView(Form { CommandsList(folder: folder) }.formStyle(.grouped), size: NSSize(width: 640, height: 600))
        addTeardownBlock { hosted.close() }
        XCTAssertNil(hosted.element(id: "command.open-website"))
        try "\"\"\"Open a website.\"\"\"\n".write(to: folder.appendingPathComponent("open-website.py"), atomically: true, encoding: .utf8)
        waitUntil { hosted.element(id: "command.open-website") != nil }
        XCTAssertNotNil(hosted.element(id: "command.open-website"), "a create command or a saved script shows right away")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("open-website.py"))
        waitUntil { hosted.element(id: "command.open-website") == nil }
        XCTAssertNil(hosted.element(id: "command.open-website"))
    }

    func testASwitchTurnsAScriptOffAndOn() throws {
        let services = makeServices(self)
        let folder = services.commands.folder
        CommandMode.installExamples(into: folder)
        let hosted = HostedView(Form { CommandsList(folder: folder) }.formStyle(.grouped), size: NSSize(width: 640, height: 600))
        addTeardownBlock { hosted.close() }
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "command.switch.volume"))))
        XCTAssertEqual(Command.disabled(in: folder).map(\.name), ["volume"])
        XCTAssertNotNil(hosted.element(id: "command.volume"), "still listed, to turn back on")
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "command.switch.volume"))))
        XCTAssertEqual(Command.disabled(in: folder), [])
        XCTAssertTrue(Command.all(in: folder).contains { $0.name == "volume" })
    }
}
