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
        XCTAssertEqual(Command.all(in: dir).map(\.name), ["return", "repeat", "create", "open", "brightness", "volume"])
        XCTAssertEqual(Command.all(in: dir.appendingPathComponent("missing")).map(\.name), ["return", "repeat", "create", "open"])
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

    // MARK: Chat models

    func testAChatModelIsToldTheCommandsAndLimitedToThem() throws {
        let commands = [Command.pressReturn, Command.parse(brightness, script: URL(fileURLWithPath: "/tmp/brightness.py"))!]
        let request = ChatDecider.request("brighter", among: commands, model: "deepseek/deepseek-v4.1-flash", apiKey: "k")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "deepseek/deepseek-v4.1-flash")
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertTrue(messages[0]["content"]!.contains("- brightness: Set the screen brightness.. Choices: +10 = a bit brighter; 50 = half"))
        XCTAssertEqual(messages[1]["content"], "brighter")
        let schema = try XCTUnwrap(((body["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])?["schema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        XCTAssertEqual(properties["command"]?["enum"] as? [String], ["return", "brightness", "none"])
        XCTAssertEqual(properties["choice"]?["enum"] as? [String], ["", "+10", "50"])
    }

    func testReadsAChatModelsAnswer() throws {
        let commands = [Command.parse(brightness, script: URL(fileURLWithPath: "/tmp/brightness.py"))!]
        func answer(_ content: String) -> Data {
            try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        }
        XCTAssertEqual(try ChatDecider.parse(data: answer(#"{"command":"brightness","choice":"+10"}"#), status: 200, among: commands).get(),
                       CommandDecision(command: "brightness", choice: "+10", confidence: 1))
        XCTAssertEqual(try ChatDecider.parse(data: answer(#"```json {"command":"brightness","choice":"mute"} ```"#), status: 200, among: commands).get(),
                       CommandDecision(command: "brightness", choice: nil, confidence: 1), "not one of its choices")
        XCTAssertEqual(try ChatDecider.parse(data: answer(#"{"command":"none","choice":""}"#), status: 200, among: commands).get(),
                       CommandDecision(command: nil, confidence: 1))
        XCTAssertThrowsError(try ChatDecider.parse(data: Data(#"{"error":{"message":"No endpoints"}}"#.utf8), status: 404, among: commands).get())
    }

    func testTheModelSettingPicksTheDecider() {
        XCTAssertTrue(makeCommandDecider(model: "jev", apiKey: "k") is JevDecider)
        XCTAssertEqual((makeCommandDecider(model: "google/gemini-3.5-flash-lite", apiKey: "k") as? ChatDecider)?.model,
                       "google/gemini-3.5-flash-lite")
        XCTAssertEqual(makeSettings(self).commandModel, "jev")
    }

    // MARK: Running

    func testResultIsTheFirstLineOfOutputOrTheLastLineOfErrors() {
        func result(_ status: Int32, _ output: String = "", _ errors: String = "", timedOut: Bool = false) -> CommandResult {
            CommandResult.from(CommandMode.Finished(status: status, output: output, errors: errors, timedOut: timedOut), name: "b")
        }
        XCTAssertEqual(result(0, "\nBrightness 70%\nmore\n"), CommandResult(ok: true, message: "Brightness 70%"))
        XCTAssertEqual(result(0), CommandResult(ok: true, message: "Ran b"))
        XCTAssertEqual(result(1, "", "Traceback\n  ...\nValueError: bad\n"), CommandResult(ok: false, message: "ValueError: bad", scriptFailed: true))
        XCTAssertEqual(result(3), CommandResult(ok: false, message: "Exited with 3", scriptFailed: true))
        XCTAssertEqual(result(15, timedOut: true), CommandResult(ok: false, message: "Took longer than 10 s", scriptFailed: true))
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
        XCTAssertEqual(failed, CommandResult(ok: false, message: "no display", scriptFailed: true))
    }

    // MARK: Command mode

    private var ran: [String] = []
    private var returns = 0

    private func makeMode(_ decision: CommandDecision, log: EventLog = EventLog()) -> CommandMode {
        let mode = CommandMode(folder: folder(["brightness.py": brightness]), history: HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self)))
        mode.makeDecider = { _, _ in FakeDecider(decision: decision, log: log) }
        mode.runScript = { [unowned self] url, choice in
            ran.append(url.deletingPathExtension().lastPathComponent + " " + (choice ?? "-"))
            return CommandResult(ok: true, message: "Brightness 60%")
        }
        mode.pressReturn = { [unowned self] in returns += 1 }
        mode.apps = { [:] }
        mode.openApp = { _ in XCTFail("opened an app") }
        return mode
    }

    @MainActor
    func testRunsThePickedCommandAndSavesIt() async {
        let log = EventLog()
        let mode = makeMode(CommandDecision(command: "brightness", choice: "+10", confidence: 0.97), log: log)
        let run = await mode.handle("a bit brighter", apiKey: "k")
        XCTAssertEqual(log.events, ["decide: a bit brighter among return,repeat,create,open,brightness"])
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
        mode.makeDecider = { _, _ in FakeDecider(decision: CommandDecision(command: nil, confidence: 0),
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

    func testThePillSaysHowItWent() {
        XCTAssertEqual(CommandRun(said: "mute", command: "volume", choice: "mute", ok: true, result: "Muted").message,
                       PillMessage(title: "Muted", tone: .done, seconds: 1.5))
        XCTAssertEqual(CommandRun(said: "brighter", command: "brightness", choice: "+10", result: "No display").message,
                       PillMessage(title: "Brightness didn’t work", detail: "No display", tone: .failed, seconds: 3))
        XCTAssertEqual(CommandRun(said: "open the pod bay doors", result: "Command not found").message,
                       PillMessage(title: "Command not found", detail: "“open the pod bay doors”", tone: .failed, seconds: 2.5))
    }

    // MARK: Turning commands off

    func testATurnedOffScriptIsLeftOutUntilTurnedBackOn() throws {
        let dir = folder(["brightness.py": brightness, "volume.py": "\"\"\"Set the volume.\"\"\""])
        let off = try Command.setEnabled(false, script: dir.appendingPathComponent("volume.py"), folder: dir)
        XCTAssertEqual(off, Command.disabledFolder(dir).appendingPathComponent("volume.py"))
        XCTAssertEqual(Command.all(in: dir).map(\.name), ["return", "repeat", "create", "open", "brightness"])
        XCTAssertEqual(Command.disabled(in: dir).map(\.name), ["volume"])
        try Command.setEnabled(true, script: off, folder: dir)
        XCTAssertEqual(Command.all(in: dir).map(\.name), ["return", "repeat", "create", "open", "brightness", "volume"])
        XCTAssertEqual(Command.disabled(in: dir), [])
    }

    func testTurningOnBesideOneWithTheSameNameKeepsBoth() throws {
        let dir = folder(["volume.py": "\"\"\"Old.\"\"\""])
        let off = try Command.setEnabled(false, script: dir.appendingPathComponent("volume.py"), folder: dir)
        try "\"\"\"New.\"\"\"".write(to: dir.appendingPathComponent("volume.py"), atomically: true, encoding: .utf8)
        try Command.setEnabled(true, script: off, folder: dir)
        XCTAssertEqual(Command.all(in: dir).map(\.name), ["return", "repeat", "create", "open", "volume", "volume-2"])
        XCTAssertEqual(Command.freeURL(for: "create", in: dir).lastPathComponent, "create-2.py", "a built-in's name is taken")
    }

    @MainActor
    func testAScriptThatFailsIsTurnedOff() async {
        let mode = makeMode(CommandDecision(command: "brightness", choice: "+10", confidence: 0.97))
        mode.runScript = { _, _ in CommandResult(ok: false, message: "No display", scriptFailed: true) }
        let run = await mode.handle("brighter", apiKey: "k")
        XCTAssertFalse(run.ok)
        XCTAssertEqual(run.result, "No display · turned off")
        XCTAssertEqual(Command.disabled(in: mode.folder).map(\.name), ["brightness"])
        XCTAssertFalse(mode.commands.contains { $0.name == "brightness" })
    }

    @MainActor
    func testUvMissingDoesntTurnTheScriptOff() async {
        let mode = makeMode(CommandDecision(command: "brightness", choice: "+10", confidence: 0.97))
        mode.runScript = { _, _ in CommandResult(ok: false, message: "uv isn't installed") }
        let run = await mode.handle("brighter", apiKey: "k")
        XCTAssertEqual(run.result, "uv isn't installed")
        XCTAssertEqual(Command.disabled(in: mode.folder), [])
    }

    // MARK: Open

    func testInstalledAppsComeFromTheAppFoldersFirstFoundWins() throws {
        let first = makeTempURL(self, "Applications"), second = makeTempURL(self, "System")
        for (folder, items) in [(first, ["Safari.app", "Notes.txt"]), (second, ["Safari.app", "Notes.app"])] {
            for item in items {
                try FileManager.default.createDirectory(at: folder.appendingPathComponent(item), withIntermediateDirectories: true)
            }
        }
        let apps = Command.installedApps(in: [first, second, first.appendingPathComponent("missing")])
        XCTAssertEqual(apps.keys.sorted(), ["Notes", "Safari"])
        XCTAssertEqual(apps["Safari"]?.deletingLastPathComponent().lastPathComponent, "Applications")
        let open = Command.all(in: folder([:]), apps: ["Notes", "Safari"]).first { $0.name == "open" }
        XCTAssertEqual(open?.choices, [.init(value: "Notes", meaning: "Notes"), .init(value: "Safari", meaning: "Safari"), Command.noApp])
        XCTAssertEqual(Command.all(in: folder([:]), apps: (1...300).map(String.init)).first { $0.name == "open" }?.choices.count, 255,
                       "Jev's most")
    }

    @MainActor
    func testOpenOpensTheApp() async {
        var opened: [URL] = []
        let safari = URL(fileURLWithPath: "/Applications/Safari.app")
        for (choice, result) in [("Safari", "Opened Safari"), ("Teleporter", "No app by that name"), ("none", "No app by that name")] {
            let mode = makeMode(CommandDecision(command: "open", choice: choice, confidence: 0.9))
            mode.apps = { ["Safari": safari] }
            mode.openApp = { opened.append($0) }
            let run = await mode.handle("打开 \(choice)", apiKey: "k")
            XCTAssertEqual(run.result, result)
        }
        XCTAssertEqual(opened, [safari])
    }

    // MARK: Create

    func testTheWriterIsToldTheCommandsButNotCreate() {
        let commands = Command.all(in: folder(["brightness.py": brightness]))
        let prompt = CommandWriter.prompt(commands)
        XCTAssertTrue(prompt.contains("- brightness: Set the screen brightness. (choices: +10 = a bit brighter, 50 = half)"))
        XCTAssertTrue(prompt.contains("- repeat: Run the last command again\n"))
        XCTAssertFalse(prompt.contains("- create:"))
        XCTAssertTrue(prompt.contains("- open: Open an app\n"), "not the apps: the model would name one as the command")
        XCTAssertFalse(prompt.contains("{commands}"))
        XCTAssertTrue(prompt.contains("EXISTING: <its name>"), "the instructions ship with the app")
    }

    func testReadsTheWritersAnswer() {
        XCTAssertEqual(CommandWriter.parse("EXISTING: volume\n"), .existing("volume"))
        XCTAssertEqual(CommandWriter.parse("NAME: battery\n```python\n\"\"\"Battery.\"\"\"\nprint(1)\n```"),
                       .new(name: "battery", script: "\"\"\"Battery.\"\"\"\nprint(1)\n"))
        XCTAssertNil(CommandWriter.parse("Sure! Here's a script: print(1)"))
        XCTAssertTrue(CommandWriter.validName("window-left"))
        for bad in ["Window", "../x", "a b", "-x", "x-", ""] { XCTAssertFalse(CommandWriter.validName(bad), bad) }
    }

    private let battery = "\"\"\"Say the battery level.\"\"\"\nprint('Battery 80%')\n"

    @MainActor
    func testCreateWritesTheCommandForNextTime() async throws {
        let mode = makeMode(CommandDecision(command: "create", confidence: 0.95))
        var asked: [String] = []
        mode.writeCommand = { [battery] said, commands, key in
            asked.append("\(said) | \(commands.map(\.name).joined(separator: ",")) | \(key)")
            return .new(name: "battery", script: battery)
        }
        let run = await mode.handle("create command tell me the battery", apiKey: "k")
        XCTAssertEqual(asked, ["create command tell me the battery | return,repeat,create,open,brightness | k"])
        XCTAssertTrue(run.ok)
        XCTAssertEqual(run.result, "Created battery")
        XCTAssertEqual(try String(contentsOf: mode.folder.appendingPathComponent("battery.py"), encoding: .utf8), battery)
        XCTAssertTrue(mode.commands.contains { $0.name == "battery" && $0.summary == "Say the battery level." })
        XCTAssertEqual(ran, [], "written, not run")
        XCTAssertFalse(run.canRunAgain, "↻ and repeat don't write it again")
        mode.makeDecider = { _, _ in FakeDecider(decision: CommandDecision(command: "repeat", confidence: 0.9)) }
        let repeated = await mode.handle("again", apiKey: "k")
        XCTAssertEqual(repeated.result, "Nothing to repeat")
    }

    @MainActor
    func testCreateTakesAFreeNameAndRefusesWhatItCantRead() async throws {
        let mode = makeMode(CommandDecision(command: "create", confidence: 0.95))
        var reply = CommandWriter.Reply.new(name: "brightness", script: battery)
        mode.writeCommand = { _, _, _ in reply }
        let first = await mode.handle("create command battery", apiKey: "k")
        XCTAssertEqual(first.result, "Created brightness-2")
        for (bad, why) in [(CommandWriter.Reply.new(name: "../evil", script: battery), "Couldn't write it: “../evil” can't be a command's name"),
                           (.new(name: "nodoc", script: "print(1)\n"), "Couldn't write it: its description is missing"),
                           (.existing("teleport"), "Couldn't write it: it named teleport, which isn't a command")] {
            reply = bad
            let run = await mode.handle("create command something", apiKey: "k")
            XCTAssertFalse(run.ok)
            XCTAssertEqual(run.result, why)
        }
        reply = .existing("brightness")
        let existing = await mode.handle("create command brighter", apiKey: "k")
        XCTAssertTrue(existing.ok)
        XCTAssertEqual(existing.result, "brightness already does that")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: mode.folder.path)), ["brightness.py", "brightness-2.py"])
    }

    /// The real uv: a script Python can't parse isn't saved.
    @MainActor
    func testCreateRefusesAScriptPythonCantParse() async throws {
        guard CommandMode.uvPaths.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("uv isn't installed")
        }
        let problem = await CommandMode.syntaxProblem("\"\"\"Broken.\"\"\"\nif True print(1)\n")
        XCTAssertTrue(problem?.contains("SyntaxError") ?? false, problem ?? "nil")
        let fine = await CommandMode.syntaxProblem(battery)
        XCTAssertNil(fine)
        let mode = makeMode(CommandDecision(command: "create", confidence: 0.95))
        mode.writeCommand = { _, _, _ in .new(name: "broken", script: "\"\"\"Broken.\"\"\"\nif True print(1)\n") }
        let run = await mode.handle("create command broken", apiKey: "k")
        XCTAssertFalse(run.ok)
        XCTAssertTrue(run.result.hasPrefix("Couldn't write it: SyntaxError"), run.result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mode.folder.appendingPathComponent("broken.py").path))
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

    /// The real Jev (and a chat model), through `CommandMode.handle` with the example commands (scripts faked, so
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
        mode.openApp = { _ in }
        for model in ["jev", "deepseek/deepseek-v4.1-flash"] {
        for (said, expected) in [("make the screen a bit brighter", "brightness +10"), ("把亮度调到一半", "brightness 50"),
                                 ("声音小一点", "volume -10"), ("mute", "volume mute"), ("send it", "return"),
                                 ("打开 Safari", "open Safari"), ("open the pod bay doors", "none")] {
            // The chat decider (not the default) often leaves out which app: bench/results/commands.
            if model != "jev" && said == "打开 Safari" { continue }
            let started = Date()
            let run = await mode.handle(said, apiKey: key, model: model)
            print("[live] \(model): \(said) → \(run.label) in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
            XCTAssertEqual(run.label, expected, "\(model): \(said)")
        }
        }
    }

    /// The real Jev and the real writer, through `CommandMode.handle`: "create command …" writes a
    /// script into an empty folder, and the app can read it (not run). Opt-in like the one above (~$0.001).
    @MainActor
    func testLiveCreateWritesACommand() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LIVE_OPENROUTER"] == "1", let key = env["OPENROUTER_API_KEY"] else {
            throw XCTSkip("set LIVE_OPENROUTER=1 and OPENROUTER_API_KEY to run")
        }
        let mode = CommandMode(folder: makeTempURL(self, "Commands"), history: HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self)))
        CommandMode.installExamples(into: mode.folder)
        let started = Date()
        let run = await mode.handle("create command, um, tell me the battery percentage", apiKey: key)
        print("[live] create: \(run.result) in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        XCTAssertEqual(run.command, "create")
        XCTAssertTrue(run.ok, run.result)
        XCTAssertEqual(mode.commands.count, Command.builtIn.count + 3, "brightness, volume and the new one")
        let existing = await mode.handle("新建命令 静音", apiKey: key)
        XCTAssertEqual(existing.result, "volume already does that")
    }

    // MARK: Examples

    func testExamplesAreCopiedTheFirstTimeOnly() throws {
        let folder = makeTempURL(self, "Commands")
        CommandMode.installExamples(into: folder)
        XCTAssertEqual(Command.all(in: folder).map(\.name), ["return", "repeat", "create", "open", "brightness", "volume"])
        XCTAssertEqual(Command.all(in: folder).first { $0.name == "volume" }?.choices.last?.value, "unmute")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("volume.py"))
        CommandMode.installExamples(into: folder)
        XCTAssertEqual(Command.all(in: folder).map(\.name), ["return", "repeat", "create", "open", "brightness"], "a deleted one stays deleted")
    }
}
