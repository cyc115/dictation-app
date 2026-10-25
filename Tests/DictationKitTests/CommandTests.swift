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

    /// A script not named like a built-in, for command mode's script path.
    private let window = """
        \"\"\"Tile the front window.

        Choices:
            left: the left half
            right: the right half
        \"\"\"
        print("Tiled")
        """

    private let builtIns = Command.builtIn.map(\.name).joined(separator: ",")

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
        let dir = folder(["window.py": window, "battery.py": "\"\"\"Say the battery level.\"\"\"", "volume.py": "\"\"\"Mine.\"\"\"",
                          "return.py": "\"\"\"Mine.\"\"\"", "notes.txt": "\"\"\"Not a script.\"\"\"", "broken.py": "no docstring"])
        let names = Command.builtIn.map(\.name)
        XCTAssertEqual(names, ["return", "repeat", "create", "fix", "open", "brightness", "volume", "lock-screen", "media-control",
                               "open-website", "switch-app", "ask-muse"])
        XCTAssertEqual(Command.all(in: dir, apps: [], running: []).map(\.name), names + ["battery", "window"], "one named like a built-in is skipped")
        XCTAssertEqual(Command.all(in: dir.appendingPathComponent("missing"), apps: [], running: []).map(\.name), names)
    }

    func testSwitchAppsChoicesAreTheAppsOpenNow() {
        let commands = Command.all(in: folder([:]), apps: ["Safari"], running: ["Ghostty", "WeChat"])
        XCTAssertEqual(commands.first { $0.name == "switch-app" }?.choices,
                       [.init(value: "Ghostty", meaning: "Ghostty"), .init(value: "WeChat", meaning: "WeChat"), Command.noApp])
        XCTAssertEqual(commands.first { $0.name == "open" }?.choices.map(\.value), ["Safari", "none"])
        let running = SwitchApp.running()
        XCTAssertFalse(running.isEmpty, "this test runner's Mac has apps open")
        XCTAssertFalse(running.values.contains { $0.processIdentifier == ProcessInfo.processInfo.processIdentifier }, "not this app")
    }

    // MARK: Jev

    func testJevIsAskedWhichCommandAndEachCommandsChoice() throws {
        let commands = [Command.pressReturn, Command.parse(brightness, script: URL(fileURLWithPath: "/tmp/brightness.py"))!]
        let request = JevDecider.request("把亮度调到一半", among: commands, apiKey: "k")
        XCTAssertEqual(request.url, JevDecider.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "~typesafe/jev-latest")
        XCTAssertEqual(body["state"] as? String, CommandDecision.heard + "\nThe user said: 把亮度调到一半",
                       "told it was heard, so it may be misheard")
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

    // MARK: Speech context

    /// What the speech model is told to listen for: the built-ins' words, your commands' names as
    /// spoken, and the open apps, each once.
    func testTheSpeechModelIsToldTheCommandsWords() {
        let mode = CommandMode(folder: folder(["tail-error-log.py": brightness]),
                               history: HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self)))
        mode.running = { ["Muse", "Ghostty"] }
        let words = mode.speechContext().words
        XCTAssertEqual(Array(words.prefix(2)), ["press Enter", "send"])
        XCTAssertTrue(words.contains("亮度"))
        XCTAssertEqual(Array(words.suffix(2)), ["tail error log", "Ghostty"], "Muse is already a built-in word")
        XCTAssertEqual(words.count, Set(words).count)
        XCTAssertTrue(mode.speechContext().prompt.hasSuffix("tail error log, Ghostty"))
        XCTAssertEqual(SpeechContext.none.prompt, "", "plain dictation: no context")
    }

    // MARK: Chat models

    func testAChatModelIsToldTheCommandsAndLimitedToThem() throws {
        let commands = [Command.pressReturn, Command.parse(brightness, script: URL(fileURLWithPath: "/tmp/brightness.py"))!]
        let request = ChatDecider.request("brighter", among: commands, model: "deepseek/deepseek-v4.1-flash", apiKey: "k")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "deepseek/deepseek-v4.1-flash")
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertTrue(messages[0]["content"]!.contains("- brightness: Set the screen brightness.. Choices: +10 = a bit brighter; 50 = half"))
        XCTAssertTrue(messages[0]["content"]!.contains(CommandDecision.heard))
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
        XCTAssertEqual(result(1, "", "Traceback\n  ...\nValueError: bad\n"),
                       CommandResult(ok: false, message: "ValueError: bad", details: "exit status 1\nstderr:\nTraceback\n  ...\nValueError: bad"))
        XCTAssertEqual(result(3), CommandResult(ok: false, message: "Exited with 3", details: "exit status 3"))
        XCTAssertEqual(result(15, "half done\n", timedOut: true),
                       CommandResult(ok: false, message: "Took longer than 10 s", details: "stopped after 10 s\nstdout:\nhalf done"))
    }

    /// The real runner, with uv: the choice reaches the script as one argument, never through a shell.
    func testRunsTheScriptWithUvAndPassesTheChoiceAsIs() async throws {
        guard CommandMode.uvPaths.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("uv isn't installed")
        }
        let dir = folder(["echo.py": "\"\"\"Echo.\"\"\"\nimport os, sys\nprint('got', sys.argv[1:], os.environ['COMMAND_SAID'])\n",
                          "fail.py": "\"\"\"Fail.\"\"\"\nimport sys\nsys.exit('no display')\n"])
        let echoed = await CommandMode.run(script: dir.appendingPathComponent("echo.py"), choice: "+10; touch /tmp/x", said: "打开 Swift 论坛")
        XCTAssertEqual(echoed, CommandResult(ok: true, message: "got ['+10; touch /tmp/x'] 打开 Swift 论坛"))
        let failed = await CommandMode.run(script: dir.appendingPathComponent("fail.py"), choice: nil)
        XCTAssertEqual(failed.message, "no display")
        XCTAssertEqual(failed.details, "exit status 1\nstderr:\nno display")
    }

    // MARK: Command mode

    private var ran: [String] = []
    private var heard: [String] = []
    private var returns = 0

    private func makeMode(_ decision: CommandDecision, log: EventLog = EventLog()) -> CommandMode {
        let mode = CommandMode(folder: folder(["window.py": window]), history: HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self)))
        mode.makeDecider = { _, _ in FakeDecider(decision: decision, log: log) }
        mode.runScript = { [unowned self] url, choice, said in
            ran.append(url.deletingPathExtension().lastPathComponent + " " + (choice ?? "-"))
            heard.append(said)
            return CommandResult(ok: true, message: "Tiled")
        }
        fakeSystem(mode, message: "Brightness 60%") { [unowned self] in ran.append($0) }
        mode.pressReturn = { [unowned self] in returns += 1 }
        mode.apps = { [:] }
        mode.openApp = { _ in XCTFail("opened an app") }
        return mode
    }

    @MainActor
    func testRunsThePickedScriptAndSavesIt() async {
        let log = EventLog()
        let mode = makeMode(CommandDecision(command: "window", choice: "left", confidence: 0.97), log: log)
        let run = await mode.handle("tile it left", apiKey: "k")
        XCTAssertEqual(log.events, ["decide: tile it left among \(builtIns),window"])
        XCTAssertEqual(ran, ["window left"])
        XCTAssertEqual(heard, ["tile it left"], "what you said goes along, for free text")
        XCTAssertEqual(run.command, "window")
        XCTAssertEqual(run.choice, "left")
        XCTAssertTrue(run.ok)
        XCTAssertEqual(run.result, "Tiled")
        XCTAssertEqual(mode.history.commands, [run])
    }

    @MainActor
    func testABuiltInRunsInTheAppNotAsAScript() async {
        let mode = makeMode(CommandDecision(command: "brightness", choice: "+10", confidence: 0.97))
        let run = await mode.handle("a bit brighter", apiKey: "k")
        XCTAssertEqual(ran, ["brightness +10"])
        XCTAssertEqual(run.result, "Brightness 60%")
        XCTAssertEqual(heard, [], "no script ran")
    }

    @MainActor
    func testAFailedCommandGoesInTheErrorLogWithEverythingItPrinted() async throws {
        let mode = makeMode(CommandDecision(command: "window", choice: "left", confidence: 0.97))
        _ = await mode.handle("tile it left", apiKey: "k")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mode.log.file.path), "nothing failed")
        mode.runScript = { _, _, _ in
            CommandResult(ok: false, message: "NameError: name 'x' is not defined",
                          details: "exit status 1\nstderr:\nTraceback (most recent call last):\n  File \"window.py\", line 9\nNameError: name 'x' is not defined")
        }
        _ = await mode.handle("tile it left", apiKey: "k")
        mode.makeDecider = { _, _ in FakeDecider(decision: CommandDecision(command: nil, confidence: 1)) }
        _ = await mode.handle("open the pod bay doors", apiKey: "k")
        XCTAssertEqual(mode.log.file, mode.folder.appendingPathComponent("errors.log"))
        let log = try String(contentsOf: mode.log.file, encoding: .utf8)
        XCTAssertTrue(log.contains("  window left  ✗ NameError: name 'x' is not defined\nsaid: tile it left\nexit status 1\nstderr:\nTraceback"), log)
        XCTAssertTrue(log.contains("File \"window.py\", line 9"), "the whole traceback, not just the pill's line")
        XCTAssertEqual(log.components(separatedBy: "── ").count, 2, "one entry: a command that didn't run isn't an error")
        XCTAssertFalse(mode.commands.isEmpty)
    }

    func testTheErrorLogKeepsItsNewerHalf() throws {
        let folder = makeTempURL(self, "Commands")
        let log = CommandLog(folder: folder)
        let run = CommandRun(said: "tile it", command: "window", choice: "left", result: "Broke")
        let big = String(repeating: "x", count: 1000)
        for n in 0..<700 { log.add(run, details: "\(n) \(big)") }
        let text = try String(contentsOf: log.file, encoding: .utf8)
        XCTAssertLessThanOrEqual(text.utf8.count, CommandLog.maxBytes)
        XCTAssertTrue(text.hasPrefix("── "), "trimmed at an entry")
        XCTAssertTrue(text.contains("699 x"), "the newest is kept")
        XCTAssertFalse(text.contains("\n1 x"), "the oldest is gone")
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
        let dir = folder(["window.py": window, "battery.py": "\"\"\"Say the battery level.\"\"\""])
        let off = try Command.setEnabled(false, script: dir.appendingPathComponent("battery.py"), folder: dir)
        XCTAssertEqual(off, Command.disabledFolder(dir).appendingPathComponent("battery.py"))
        let builtIns = Command.builtIn.map(\.name)
        XCTAssertEqual(Command.all(in: dir, apps: [], running: []).map(\.name), builtIns + ["window"])
        XCTAssertEqual(Command.disabled(in: dir).map(\.name), ["battery"])
        try Command.setEnabled(true, script: off, folder: dir)
        XCTAssertEqual(Command.all(in: dir, apps: [], running: []).map(\.name), builtIns + ["battery", "window"])
        XCTAssertEqual(Command.disabled(in: dir), [])
    }

    func testTurningOnBesideOneWithTheSameNameKeepsBoth() throws {
        let dir = folder(["battery.py": "\"\"\"Old.\"\"\""])
        let off = try Command.setEnabled(false, script: dir.appendingPathComponent("battery.py"), folder: dir)
        try "\"\"\"New.\"\"\"".write(to: dir.appendingPathComponent("battery.py"), atomically: true, encoding: .utf8)
        try Command.setEnabled(true, script: off, folder: dir)
        XCTAssertEqual(Command.all(in: dir, apps: [], running: []).map(\.name), Command.builtIn.map(\.name) + ["battery", "battery-2"])
        XCTAssertEqual(Command.freeURL(for: "create", in: dir).lastPathComponent, "create-2.py", "a built-in's name is taken")
    }

    @MainActor
    func testAScriptThatFailsStaysOn() async {
        let mode = makeMode(CommandDecision(command: "window", choice: "left", confidence: 0.97))
        mode.runScript = { _, _, _ in CommandResult(ok: false, message: "No window") }
        let run = await mode.handle("tile it left", apiKey: "k")
        XCTAssertFalse(run.ok)
        XCTAssertEqual(run.result, "No window")
        XCTAssertEqual(Command.disabled(in: mode.folder), [])
        XCTAssertTrue(mode.commands.contains { $0.name == "window" })
    }

    // MARK: Fix

    @MainActor
    func testFixStartsASessionToldWhatWentWrong() async throws {
        let mode = makeMode(CommandDecision(command: "fix", choice: "volume", confidence: 0.95))
        mode.source = URL(fileURLWithPath: "/src/dictation-app")
        mode.history.addCommand(CommandRun(said: "louder", command: "volume", choice: "+10", result: "Couldn't set the volume"))
        mode.history.addCommand(CommandRun(said: "quieter", command: "volume", choice: "-10", ok: true, result: "Volume 30%"))
        mode.log.add(CommandRun(said: "louder", command: "volume", choice: "+10", result: "Couldn't set the volume"), details: "AppleScript: no output device")
        mode.log.add(CommandRun(said: "go to yahoo finance", command: "open-website", choice: "other", result: "Which website?"), details: nil)
        var started: [(CommandFixer, Command, String)] = []
        mode.startFix = { started.append(($0, $1, $2)); return CommandResult(ok: true, message: "Fixing \($1.name) in the background") }
        let run = await mode.handle("fix the volume command, turning it up doesn't work", apiKey: "k")
        XCTAssertEqual(run.result, "Fixing volume in the background")
        let (fixer, command, prompt) = try XCTUnwrap(started.first)
        XCTAssertEqual(command.name, "volume")
        XCTAssertEqual(fixer.source?.path, "/src/dictation-app")
        XCTAssertEqual(fixer.folder, mode.folder)
        XCTAssertTrue(prompt.contains("\"fix the volume command, turning it up doesn't work\""), "what you said")
        XCTAssertTrue(prompt.contains("tail -n 120 \"\(mode.log.file.path)\""), "it reads the latest errors first")
        XCTAssertTrue(prompt.contains("volume +10  ✗ Couldn't set the volume\nsaid: louder\nAppleScript: no output device"), "volume's entry")
        XCTAssertFalse(prompt.contains("yahoo finance"), "not another command's")
        XCTAssertTrue(prompt.contains("“quieter” → volume -10 → ok: Volume 30%"), "its runs")
        XCTAssertTrue(prompt.contains("built into the app") && prompt.contains("./build.sh --keep-running"))
        XCTAssertFalse(prompt.contains("{"), "every blank filled in")
    }

    @MainActor
    func testFixWithoutANameFixesTheLastCommandThatFailedAndAScriptInPlace() async throws {
        let mode = makeMode(CommandDecision(command: "fix", choice: "none", confidence: 0.9))
        var started: [(Command, String)] = []
        mode.startFix = { started.append(($1, $2)); return CommandResult(ok: true, message: "Fixing") }
        let nothing = await mode.handle("fix it", apiKey: "k")
        XCTAssertEqual(nothing.result, "Which command? Say “fix” and its name")
        mode.history.addCommand(CommandRun(said: "tile it left", command: "window", choice: "left", result: "No window"))
        mode.history.addCommand(CommandRun(said: "louder", command: "volume", choice: "+10", ok: true, result: "Volume 40%"))
        _ = await mode.handle("that didn't work, fix it", apiKey: "k")
        let (command, prompt) = try XCTUnwrap(started.first)
        XCTAssertEqual(command.name, "window", "the last one that failed, not the last one")
        XCTAssertEqual(command.script?.lastPathComponent, "window.py")
        let script = try XCTUnwrap(command.script).path
        XCTAssertTrue(prompt.contains("the user's own script, not in git: \(script)") && prompt.contains(script + ".orig"))
        XCTAssertTrue(prompt.contains("uv run --quiet --script \"\(script)\""))
        XCTAssertTrue(prompt.contains("The latest entries for window:\n(none)"))
    }

    func testFixsChoicesAreTheOtherCommands() {
        let fix = Command.all(in: folder(["window.py": window]), apps: [], running: []).first { $0.name == "fix" }
        XCTAssertEqual(fix?.choices.first, .init(value: "return", meaning: Command.pressReturn.summary))
        XCTAssertEqual(fix?.choices.suffix(2).map(\.value), ["window", "none"])
        XCTAssertFalse(fix?.choices.contains { $0.value == "fix" } ?? true)
    }

    @MainActor
    func testFixingABuiltInNeedsTheSourceAndClaudeSaysWhereToWatch() async {
        let fixer = CommandFixer(folder: makeTempURL(self, "Commands"), source: nil)
        let result = await fixer.start(Command.volume, prompt: "fix it")
        XCTAssertEqual(result.message, "Fixing a built-in needs the app's source")
        XCTAssertEqual(CommandFixer.sessionID("Starting background service…\nbackgrounded · 87c66017 · fix-volume\n  claude agents  list"), "87c66017")
        XCTAssertNil(CommandFixer.sessionID("Workspace not trusted."))
        let arguments = fixer.arguments(Command.volume, prompt: "fix it")
        XCTAssertEqual(arguments.last, "fix it")
        XCTAssertTrue(arguments[arguments.firstIndex(of: "--add-dir")! + 2].hasPrefix("-"), "an option ends --add-dir's folders, or it takes the prompt for one")
    }

    func testTheErrorLogFindsOneCommandsEntries() {
        let log = CommandLog(folder: makeTempURL(self, "Commands"))
        XCTAssertEqual(log.entries(for: "open"), [], "no log yet")
        for (name, choice) in [("open-website", "other"), ("open", "Safari"), ("lock-screen", nil), ("open", "Zed")] as [(String, String?)] {
            log.add(CommandRun(said: "x", command: name, choice: choice, result: "Broke"), details: "why \(name)")
        }
        let open = log.entries(for: "open")
        XCTAssertEqual(open.count, 2, "not open-website's")
        XCTAssertTrue(open[1].contains("open Zed  ✗ Broke") && open[1].hasSuffix("why open"))
        XCTAssertEqual(log.entries(for: "lock-screen").count, 1)
        XCTAssertEqual(log.entries(for: "open", last: 1).count, 1)
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

    func testOpenIncludesTheAppsMacOSComesWith() {
        XCTAssertEqual(Command.installedApps()["Music"]?.path, "/System/Applications/Music.app")
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
        let commands = Command.all(in: folder(["window.py": window]), apps: ["Safari"], running: ["Ghostty"])
        let prompt = CommandWriter.prompt(commands)
        XCTAssertTrue(prompt.contains("- window: Tile the front window. (choices: left = the left half, right = the right half)"))
        XCTAssertTrue(prompt.contains("- brightness: Set the screen brightness (choices: +10 = a bit brighter, -10 = a bit dimmer, "))
        XCTAssertTrue(prompt.contains("- repeat: Run the last command again\n"))
        XCTAssertFalse(prompt.contains("- create:"))
        XCTAssertTrue(prompt.contains("- open: Open an app installed on this Mac (not a website)\n"), "not the apps: the model would name one as the command")
        XCTAssertTrue(prompt.contains("- switch-app: Switch to another app that's already open, by name\n"))
        XCTAssertFalse(prompt.contains("{commands}"))
        XCTAssertTrue(prompt.contains("EXISTING: <its name, as listed above>"), "the instructions ship with the app")
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
        mode.writeCommand = { [battery] said, commands, key, _ in
            asked.append("\(said) | \(commands.map(\.name).joined(separator: ",")) | \(key)")
            return .new(name: "battery", script: battery)
        }
        let run = await mode.handle("create command tell me the battery", apiKey: "k")
        XCTAssertEqual(asked, ["create command tell me the battery | \(builtIns),window | k"])
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
        mode.writeCommand = { _, _, _, _ in reply }
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
        var replies: [CommandWriter.Reply] = [.existing("none"), .new(name: "battery", script: battery)]
        mode.writeCommand = { _, _, _, _ in replies.removeFirst() }
        let retried = await mode.handle("create command battery", apiKey: "k")
        XCTAssertEqual(retried.result, "Created battery", "naming no command is a slip: asked once more")
        XCTAssertEqual(replies, [])
        mode.writeCommand = { _, _, _, _ in reply }
        reply = .existing("brightness")
        let existing = await mode.handle("create command brighter", apiKey: "k")
        XCTAssertTrue(existing.ok)
        XCTAssertEqual(existing.result, "brightness already does that")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: mode.folder.path)), ["window.py", "brightness-2.py", "battery.py", "errors.log"],
                       "the refusals are logged")
    }

    /// The real uv: a script Python can't parse isn't saved; the writer is shown Python's error and
    /// asked once more first.
    @MainActor
    func testCreateRefusesAScriptPythonCantParse() async throws {
        guard CommandMode.uvPaths.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("uv isn't installed")
        }
        let broken = "\"\"\"Broken.\"\"\"\nif True print(1)\n"
        let problem = await CommandMode.syntaxProblem(broken)
        XCTAssertTrue(problem?.components(separatedBy: "\n").first?.hasSuffix("File \"<unknown>\", line 2") ?? false, problem ?? "nil")
        XCTAssertTrue(problem?.contains("if True print(1)") ?? false, "the line, for the writer to fix")
        XCTAssertTrue(problem?.components(separatedBy: "\n").last?.hasPrefix("SyntaxError") ?? false, problem ?? "nil")
        let fine = await CommandMode.syntaxProblem(battery)
        XCTAssertNil(fine)
        let mode = makeMode(CommandDecision(command: "create", confidence: 0.95))
        var retries: [CommandWriter.Retry?] = []
        mode.writeCommand = { _, _, _, retry in retries.append(retry); return .new(name: "broken", script: broken) }
        let run = await mode.handle("create command broken", apiKey: "k")
        XCTAssertFalse(run.ok)
        XCTAssertTrue(run.result.hasPrefix("Couldn't write it: SyntaxError"), run.result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mode.folder.appendingPathComponent("broken.py").path))
        XCTAssertEqual(retries.count, 2, "asked once more before giving up")
        XCTAssertNil(retries[0])
        XCTAssertEqual(retries[1]?.reply, .new(name: "broken", script: broken))
        XCTAssertTrue(retries[1]?.problem.contains("if True print(1)") ?? false, retries[1]?.problem ?? "nil")
        let logged = mode.log.entries(for: "create").joined(separator: "\n")
        XCTAssertTrue(logged.contains("line 2") && logged.contains("NAME: broken"), "errors.log has the line and the script: \(logged)")

        // The writer's slip (2026-10-25): JavaScript built in an f-string, one brace left single. Shown
        // Python's error, it fixes it.
        let slip = "\"\"\"Start a call in Muse.\"\"\"\nwin = 0\njs = f\"if (!{win}) { throw new Error('No window'); }\"\n"
        let slipProblem = await CommandMode.syntaxProblem(slip)
        XCTAssertTrue(slipProblem?.contains("SyntaxError") ?? false, slipProblem ?? "nil")
        var replies: [CommandWriter.Reply] = [.new(name: "muse-call", script: slip), .new(name: "muse-call", script: battery)]
        mode.writeCommand = { _, _, _, _ in replies.removeFirst() }
        let fixed = await mode.handle("create command start a call with Muse", apiKey: "k")
        XCTAssertEqual(fixed.result, "Created muse-call")
        XCTAssertEqual(replies, [])
        XCTAssertEqual(try String(contentsOf: mode.folder.appendingPathComponent("muse-call.py"), encoding: .utf8), battery)
    }

    func testCreateAsksAgainShowingItsReplyAndWhy() {
        let retry = CommandWriter.Retry(reply: .new(name: "x", script: "\"\"\"X.\"\"\"\nprint(1)\n"), problem: "Python can't parse the script:\nSyntaxError: bad")
        let messages = CommandWriter.messages("create command x", among: [], fixing: retry)
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user", "assistant", "user"])
        XCTAssertEqual(messages[1]["content"], "create command x")
        XCTAssertEqual(CommandWriter.parse(messages[2]["content"]!), retry.reply, "its own reply, as it wrote it")
        XCTAssertEqual(messages[3]["content"], "That can't be used: Python can't parse the script:\nSyntaxError: bad\nReply again, in the same form, with it fixed.")
        XCTAssertEqual(CommandWriter.Reply.existing("volume").text, "EXISTING: volume")
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

    /// The real Jev (and a chat model), through `CommandMode.handle` with the built-in commands (faked, so
    /// nothing on this Mac changes). Opt-in: ./test.sh --live (LIVE_OPENROUTER=1 OPENROUTER_API_KEY=…, ~$0.0004).
    @MainActor
    func testLiveJevPicksTheBuiltInCommands() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LIVE_OPENROUTER"] == "1", let key = env["OPENROUTER_API_KEY"] else {
            throw XCTSkip("set LIVE_OPENROUTER=1 and OPENROUTER_API_KEY to run")
        }
        let mode = CommandMode(folder: makeTempURL(self, "Commands"), history: HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self)))
        fakeSystem(mode)
        mode.running = { ["Ghostty", "Safari", "WeChat"] }
        mode.pressReturn = {}
        mode.openApp = { _ in }
        for model in ["jev", "deepseek/deepseek-v4.1-flash"] {
        for (said, expected) in [("make the screen a bit brighter", "brightness +10"), ("把亮度调到一半", "brightness 50"),
                                 ("声音小一点", "volume -10"), ("mute", "volume mute"), ("send it", "return"),
                                 ("打开 Safari", "open Safari"), ("play music", "media-control play-pause"),
                                 ("next song", "media-control next"), ("lock my screen", "lock-screen"),
                                 ("go to hacker news", "open-website hacker-news"), ("switch to WeChat", "switch-app WeChat"),
                                 ("ask Muse to look up whether we can go for a movie tonight", "ask-muse"),
                                 ("open the pod bay doors", "none")] {
            // The chat decider (not the default) often leaves out which app: bench/results/commands.
            if model != "jev" && ["打开 Safari", "switch to WeChat"].contains(said) { continue }
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
        fakeSystem(mode)
        let started = Date()
        let run = await mode.handle("create command, um, tell me the battery percentage", apiKey: key)
        print("[live] create: \(run.result) in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        XCTAssertEqual(run.command, "create")
        XCTAssertTrue(run.ok, run.result)
        XCTAssertEqual(mode.commands.count, Command.builtIn.count + 1, "the new one")
        let existing = await mode.handle("新建命令 静音", apiKey: key)
        XCTAssertEqual(existing.result, "volume already does that")
        // Shown its script and Python's error, the writer fixes it.
        let slip = "\"\"\"Start a call in Muse.\"\"\"\nimport subprocess\napp = \"Muse\"\n"
            + "js = f\"function run() {{ const a = Application('{app}'); if (!a.running()) { throw new Error('not running'); } a.activate(); }}\"\n"
            + "subprocess.run([\"osascript\", \"-l\", \"JavaScript\", \"-e\", js])\nprint(\"Opened Muse\")\n"
        let slipProblem = await CommandMode.syntaxProblem(slip)
        let problem = try XCTUnwrap(slipProblem)
        let said = "create command open Muse"
        let fixed = try await CommandWriter(apiKey: key).write(said, among: mode.commands,
                                                               fixing: .init(reply: .new(name: "open-muse", script: slip), problem: "Python can't parse the script:\n" + problem))
        guard case .new(_, let script) = fixed else { return XCTFail("\(fixed)") }
        let fixedProblem = await CommandMode.syntaxProblem(script)
        XCTAssertNil(fixedProblem, script)
    }
}
