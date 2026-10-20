import XCTest
@testable import DictationKit

/// A decider that answers with `decision` and logs what it was asked.
struct FakeDecider: CommandDecider {
    var decision: CommandDecision
    var error: Error?
    var log = EventLog()

    func decide(_ said: String, among commands: [Command]) async throws -> CommandDecision {
        log.add("decide: \(said) among \(commands.map(\.name).joined(separator: ","))")
        if let error { throw error }
        return decision
    }
}

final class CommandTests: XCTestCase {
    private let brightness = """
        #!/usr/bin/env -S uv run --script
        \"\"\"Set the screen brightness.

        Choices:
            +10: a bit brighter
            50: half
            not a choice line
            max value: has a space, skipped

        More notes, not choices.
            x: y
        \"\"\"
        print("hi")
        """

    private func folder(_ scripts: [String: String]) -> URL {
        let dir = makeTempURL(self, "commands")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, text) in scripts { try! text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        return dir
    }

    // MARK: Scripts → commands

    func testParsesNameSummaryAndChoicesFromTheDocstring() {
        let url = URL(fileURLWithPath: "/tmp/brightness.py")
        let command = Command.parse(brightness, script: url)
        XCTAssertEqual(command?.name, "brightness")
        XCTAssertEqual(command?.summary, "Set the screen brightness.")
        XCTAssertEqual(command?.choices, [.init(value: "+10", meaning: "a bit brighter"), .init(value: "50", meaning: "half")])
        XCTAssertEqual(command?.script, url)
    }

    func testNoDocstringNoCommand() {
        XCTAssertNil(Command.parse("print('hi')", script: URL(fileURLWithPath: "/tmp/x.py")))
        XCTAssertEqual(Command.parse("'''Says hi.'''", script: URL(fileURLWithPath: "/tmp/hi.py"))?.choices, [])
    }

    func testFolderListsBuiltInsThenScriptsByName() {
        let dir = folder(["volume.py": "\"\"\"Set the volume.\"\"\"", "brightness.py": brightness,
                          "return.py": "\"\"\"Mine.\"\"\"", "notes.txt": "\"\"\"Not a script.\"\"\"", "broken.py": "no docstring"])
        XCTAssertEqual(Command.all(in: dir).map(\.name), ["return", "repeat", "brightness", "volume"])
        XCTAssertEqual(Command.all(in: dir.appendingPathComponent("missing")).map(\.name), ["return", "repeat"])
    }

    // MARK: Jev

    func testJevIsAskedWhichCommandAndEachCommandsChoice() throws {
        let commands = [Command.pressReturn, Command.parse(brightness, script: URL(fileURLWithPath: "/tmp/brightness.py"))!]
        let request = JevDecider.request("把亮度调到一半", among: commands, apiKey: "k")
        XCTAssertEqual(request.url, JevDecider.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "~typesafe/jev-latest")
        XCTAssertEqual(body["state"] as? String, "The user said: 把亮度调到一半")
        let questions = try XCTUnwrap(body["questions"] as? [String: [String: Any]])
        XCTAssertEqual(Set(questions.keys), ["command", "choice:brightness"])
        XCTAssertEqual(questions["command"]?["criteria"] as? [String: String],
                       ["return": "Press Return (send) in the front app", "brightness": "Set the screen brightness.",
                        "none": "None of these does what the user asked"])
        XCTAssertEqual(questions["choice:brightness"]?["criteria"] as? [String: String], ["+10": "a bit brighter", "50": "half"])
    }

    func testReadsJevsAnswer() throws {
        let answer = #"{"answers":{"command":{"type":"choice","choice":"brightness","confidence":0.96},"choice:brightness":{"type":"choice","choice":"+10","confidence":1}}}"#
        XCTAssertEqual(try JevDecider.parse(data: Data(answer.utf8), status: 200).get(),
                       CommandDecision(command: "brightness", choice: "+10", confidence: 0.96))
        let none = #"{"answers":{"command":{"type":"choice","choice":"none","confidence":1}}}"#
        XCTAssertEqual(try JevDecider.parse(data: Data(none.utf8), status: 200).get(), CommandDecision(command: nil, confidence: 1))
        let failed = JevDecider.parse(data: Data(#"{"error":{"message":"No credits"}}"#.utf8), status: 402)
        XCTAssertThrowsError(try failed.get()) { XCTAssertEqual($0.localizedDescription, "Couldn't pick a command: No credits") }
    }

    // MARK: Running

    func testResultIsTheFirstLineOfOutputOrTheLastLineOfErrors() {
        XCTAssertEqual(CommandResult.from(status: 0, output: "\nBrightness 70%\nmore\n", errors: "", timedOut: false, name: "b"),
                       CommandResult(ok: true, message: "Brightness 70%"))
        XCTAssertEqual(CommandResult.from(status: 0, output: "", errors: "", timedOut: false, name: "b"),
                       CommandResult(ok: true, message: "Ran b"))
        XCTAssertEqual(CommandResult.from(status: 1, output: "", errors: "Traceback\n  ...\nValueError: bad\n", timedOut: false, name: "b"),
                       CommandResult(ok: false, message: "ValueError: bad"))
        XCTAssertEqual(CommandResult.from(status: 3, output: "", errors: "", timedOut: false, name: "b"),
                       CommandResult(ok: false, message: "Exited with 3"))
        XCTAssertEqual(CommandResult.from(status: 15, output: "", errors: "", timedOut: true, name: "b").message, "Took longer than 10 s")
    }

    /// The real runner, with uv: the choice reaches the script as one argument, never through a shell.
    func testRunsTheScriptWithUvAndPassesTheChoiceAsIs() async throws {
        guard CommandMode.uvPaths.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("uv isn't installed")
        }
        let dir = folder(["echo.py": "\"\"\"Echo.\"\"\"\nimport sys\nprint('got', sys.argv[1:])\n",
                          "fail.py": "\"\"\"Fail.\"\"\"\nimport sys\nsys.exit('no display')\n"])
        let echoed = await CommandMode.run(script: dir.appendingPathComponent("echo.py"), choice: "+10; touch /tmp/x")
        XCTAssertEqual(echoed, CommandResult(ok: true, message: "got ['+10; touch /tmp/x']"))
        let failed = await CommandMode.run(script: dir.appendingPathComponent("fail.py"), choice: nil)
        XCTAssertEqual(failed, CommandResult(ok: false, message: "no display"))
    }

    // MARK: Command mode

    private var ran: [String] = []
    private var returns = 0

    private func makeMode(_ decision: CommandDecision, log: EventLog = EventLog()) -> CommandMode {
        let mode = CommandMode(folder: folder(["brightness.py": brightness]), history: HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self)))
        mode.makeDecider = { _ in FakeDecider(decision: decision, log: log) }
        mode.runScript = { [unowned self] url, choice in
            ran.append(url.deletingPathExtension().lastPathComponent + " " + (choice ?? "-"))
            return CommandResult(ok: true, message: "Brightness 60%")
        }
        mode.pressReturn = { [unowned self] in returns += 1 }
        return mode
    }

    @MainActor
    func testRunsThePickedCommandAndSavesIt() async {
        let log = EventLog()
        let mode = makeMode(CommandDecision(command: "brightness", choice: "+10", confidence: 0.97), log: log)
        let run = await mode.handle("a bit brighter", apiKey: "k")
        XCTAssertEqual(log.events, ["decide: a bit brighter among return,repeat,brightness"])
        XCTAssertEqual(ran, ["brightness +10"])
        XCTAssertEqual(run.command, "brightness")
        XCTAssertEqual(run.choice, "+10")
        XCTAssertTrue(run.ok)
        XCTAssertEqual(run.result, "Brightness 60%")
        XCTAssertEqual(mode.history.commands, [run])
    }

    @MainActor
    func testNothingFittingOrUnsureRunsNothing() async {
        for decision in [CommandDecision(command: nil, confidence: 1), CommandDecision(command: "brightness", choice: "+10", confidence: 0.3)] {
            let run = await makeMode(decision).handle("open the pod bay doors", apiKey: "k")
            XCTAssertNil(run.command)
            XCTAssertFalse(run.ok)
            XCTAssertEqual(run.result, "Command not found")
        }
        XCTAssertEqual(ran, [])
    }

    @MainActor
    func testADeciderErrorIsTheResult() async {
        let mode = makeMode(CommandDecision(command: nil, confidence: 0))
        mode.makeDecider = { _ in FakeDecider(decision: CommandDecision(command: nil, confidence: 0),
                                             error: TranscriptionError.message("Couldn't pick a command: HTTP 500")) }
        let run = await mode.handle("brighter", apiKey: "k")
        XCTAssertEqual(run.result, "Couldn't pick a command: HTTP 500")
        XCTAssertEqual(mode.history.commands.count, 1)
    }

    @MainActor
    func testReturnPressesReturn() async {
        let run = await makeMode(CommandDecision(command: "return", confidence: 0.93)).handle("send it", apiKey: "k")
        XCTAssertEqual(returns, 1)
        XCTAssertEqual(run.result, "Pressed Return")
        XCTAssertTrue(run.ok)
    }

    @MainActor
    func testRepeatRunsTheLastCommandThatWorkedAgain() async {
        let mode = makeMode(CommandDecision(command: "repeat", confidence: 0.9))
        let nothing = await mode.handle("again", apiKey: "k")
        XCTAssertEqual(nothing.result, "Nothing to repeat")
        mode.history.addCommand(CommandRun(said: "brighter", command: "brightness", choice: "+10", ok: true, result: "Brightness 60%"))
        mode.history.addCommand(CommandRun(said: "open the pod bay doors", result: "Command not found"))
        let again = await mode.handle("repeat", apiKey: "k")
        XCTAssertEqual(ran, ["brightness +10"])
        XCTAssertEqual(again.command, "repeat")
        XCTAssertEqual(again.result, "Brightness 60%")
        // A repeat of a repeat still runs brightness, not itself.
        _ = await mode.handle("repeat", apiKey: "k")
        XCTAssertEqual(ran, ["brightness +10", "brightness +10"])
    }

    @MainActor
    func testRunAgainFromHistoryRunsItAsItWas() async {
        let mode = makeMode(CommandDecision(command: nil, confidence: 1))
        let first = CommandRun(said: "brighter", command: "brightness", choice: "+10", ok: true, result: "Brightness 60%")
        let again = await mode.again(first)
        XCTAssertEqual(ran, ["brightness +10"])
        XCTAssertEqual(again.said, "brighter")
        XCTAssertNotEqual(again.id, first.id)
        XCTAssertEqual(mode.history.commands, [again])
    }

    // MARK: History

    func testCommandsAreSavedBesideHistoryAndFollowRetention() {
        let url = makeTempURL(self)
        let defaults = makeDefaults(self)
        let store = HistoryStore(fileURL: url, defaults: defaults)
        XCTAssertEqual(store.commandsURL.lastPathComponent, "history-commands.json")
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())  // whole seconds, as saved
        let run = CommandRun(date: now, said: "mute", command: "volume", choice: "mute", ok: true, result: "Muted")
        let old = CommandRun(date: now.addingTimeInterval(-10 * 86_400), said: "brighter", result: "Command not found")
        store.addCommand(old)
        store.addCommand(run)
        store.add(text: "hello", duration: 1)
        let reloaded = HistoryStore(fileURL: url, defaults: defaults)
        XCTAssertEqual(reloaded.commands, [run, old])
        XCTAssertEqual(reloaded.entries.map(\.text), ["hello"], "commands aren't dictations")
        reloaded.retention = .days7
        XCTAssertEqual(reloaded.commands, [run])
        reloaded.clearCommands()
        XCTAssertEqual(HistoryStore(fileURL: url, defaults: defaults).commands, [])
        XCTAssertEqual(reloaded.entries.map(\.text), ["hello"])
        reloaded.retention = .off
        reloaded.addCommand(run)
        XCTAssertEqual(reloaded.commands, [])
    }

    // MARK: Live

    /// The real Jev, through `CommandMode.handle` with the example commands (scripts faked, so
    /// nothing on this Mac changes). Opt-in: ./test.sh --live (LIVE_OPENROUTER=1 OPENROUTER_API_KEY=…, ~$0.0002).
    @MainActor
    func testLiveJevPicksTheExampleCommands() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LIVE_OPENROUTER"] == "1", let key = env["OPENROUTER_API_KEY"] else {
            throw XCTSkip("set LIVE_OPENROUTER=1 and OPENROUTER_API_KEY to run")
        }
        let mode = CommandMode(folder: makeTempURL(self, "Commands"), history: HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self)))
        CommandMode.installExamples(into: mode.folder)
        mode.runScript = { url, choice in CommandResult(ok: true, message: url.deletingPathExtension().lastPathComponent + " " + (choice ?? "-")) }
        mode.pressReturn = {}
        for (said, expected) in [("make the screen a bit brighter", "brightness +10"), ("把亮度调到一半", "brightness 50"),
                                 ("声音小一点", "volume -10"), ("mute", "volume mute"), ("send it", "return"),
                                 ("open the pod bay doors", "none")] {
            let started = Date()
            let run = await mode.handle(said, apiKey: key)
            print("[live] \(said) → \(run.label) in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
            XCTAssertEqual(run.label, expected, said)
        }
    }

    // MARK: Examples

    func testExamplesAreCopiedTheFirstTimeOnly() throws {
        let folder = makeTempURL(self, "Commands")
        CommandMode.installExamples(into: folder)
        XCTAssertEqual(Command.all(in: folder).map(\.name), ["return", "repeat", "brightness", "volume"])
        XCTAssertEqual(Command.all(in: folder).first { $0.name == "volume" }?.choices.last?.value, "unmute")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("volume.py"))
        CommandMode.installExamples(into: folder)
        XCTAssertEqual(Command.all(in: folder).map(\.name), ["return", "repeat", "brightness"], "a deleted one stays deleted")
    }
}
