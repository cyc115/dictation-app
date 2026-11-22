import AVFoundation
import XCTest
@testable import DictationKit

/// What bench/suites/history.py asks the harness to run (bench/history_fixture/job.json is one, pinned by
/// test_history.py). Paths are absolute or relative to the job file.
struct HistoryBenchJob: Decodable {
    struct Dictation: Decodable {
        let id: UUID
        /// The vocabulary without what only this dictation taught it (the held-out arm).
        let heldOut: [VocabularyEntry]
        let recording: String?
    }
    struct PolishTrial: Decodable { let round: Int; let id: UUID; let arm: String }
    struct SpeechTrial: Decodable { let id: UUID; let arm: String }

    let history: String
    let vocabulary: String
    let learnedPrompts: String?
    let setups: String?
    let setup: String
    var maxCost: Double
    var parts: [Int]
    let dictations: [Dictation]
    /// Part 1, in the order to run (arms interleaved per dictation).
    let polish: [PolishTrial]
    /// Part 2, in the order to run (arms interleaved per clip).
    let speech: [SpeechTrial]
}

/// The history bench's harness: runs a job through the app's own code (replacement, the polish request,
/// `LocalEngine`, the edit watcher's trackers, `CandidateTally`) and writes one JSON row per line as it
/// goes, so a run stopped at the cost cap or by a crash keeps what it did. Never prints text: rows go
/// to the output file only, progress lines carry counts.
@MainActor
final class HistoryBench {
    enum Arm: String {
        case off
        /// The terms told to polish, no replacement before or after (part 1).
        case termsOnly = "terms-only"
        case again
        case heldOut = "held-out"
    }

    let job: HistoryBenchJob
    let folder: URL
    let test: XCTestCase
    /// The bench's OpenRouter key (part 1); nil skips part 1.
    var key: String?
    /// What the cloud polish is called through (a stub in the fixture test).
    var session: URLSession = .shared
    /// The on-device speech model (part 2); nil or not downloaded skips part 2.
    var speechModel: LocalSpeechModel?
    var verbose = false
    let meter = UsageMeter()
    private(set) var stopped = false
    private let out: FileHandle

    init(job: HistoryBenchJob, folder: URL, out: URL, test: XCTestCase) throws {
        self.job = job
        self.folder = folder
        self.test = test
        FileManager.default.createFile(atPath: out.path, contents: nil)
        self.out = try FileHandle(forWritingTo: out)
    }

    static func load(_ jobURL: URL) throws -> HistoryBenchJob {
        try JSONFile.decoder.decode(HistoryBenchJob.self, from: Data(contentsOf: jobURL))
    }

    func url(_ path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
    }

    private func write(_ row: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        out.write(data + Data("\n".utf8))
    }

    private func progress(_ line: String) {
        if verbose { print("[history] " + line) }
    }

    // MARK: The run

    func run() async throws {
        defer { try? out.close() }
        let history = try JSONFile.decoder.decode([HistoryEntry].self, from: Data(contentsOf: url(job.history)))
        let store = VocabularyStore(fileURL: url(job.vocabulary))  // reads; writes nothing unless changed
        let again = Vocabulary(store.entries)
        let byID = Dictionary(history.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let (setup, fellBack) = resolveSetup()
        write(["part": 0, "kind": "setup", "setup": setup.id, "prompt": setup.prompt, "polish": setup.polish, "fellBack": fellBack,
               "speech": DictationSetup.onDevice.speech])

        var fixes: [UUID: HistoryEntry] = [:]
        var heldOut: [UUID: Vocabulary] = [:]
        for d in job.dictations {
            guard let entry = byID[d.id], let target = entry.correction, entry.intake?.of == target else {
                write(["part": 0, "kind": "dictation", "id": d.id.uuidString, "error": "not a fixed dictation in this history.json"])
                continue
            }
            fixes[d.id] = entry
            heldOut[d.id] = Vocabulary(d.heldOut)
            write(["part": 0, "kind": "dictation", "id": d.id.uuidString, "input": entry.input, "hadRaw": entry.raw != nil,
                   "text": entry.text, "target": target,
                   "changes": (entry.intake?.changes ?? []).map { ["old": $0.old, "new": $0.new, "verdict": $0.verdict?.rawValue ?? NSNull()] as [String: Any] }])
        }

        let parts = Set(job.parts)
        if parts.contains(3) { reach(history, again) }
        if parts.contains(4) { timeReplacement(history, again) }
        if parts.contains(5) { learning(history) }
        if parts.contains(6) { replay(fixes) }
        if parts.contains(1) { await polishing(fixes, again: again, heldOut: heldOut, setup: setup) }
        if parts.contains(2) { await speech(again: again, heldOut: heldOut) }
        write(["part": -1, "kind": "done", "cost": meter.total().cost, "calls": meter.count, "stopped": stopped])
    }

    /// The setup part 1 polishes with: the job's (built-in or in setups.json) with its active learned
    /// prompt, as `AppSettings` applies it; Cloud Flash's when that one polishes on this Mac.
    func resolveSetup() -> (DictationSetup, Bool) {
        var all = DictationSetup.builtIns
        if let path = job.setups { all += DictationSetup.loadCustom(from: url(path)).setups }
        let named = all.first { $0.id == DictationSetup.currentID(job.setup) } ?? .cloudFlash
        let fellBack = named.polishesOnDevice
        let chosen = fellBack ? DictationSetup.cloudFlash : named
        guard let path = job.learnedPrompts else { return (chosen, fellBack) }
        return (LearnedPromptStore(fileURL: url(path)).apply(to: chosen), fellBack)
    }

    // MARK: Part 1: mishearings fixed

    /// What polish is told (its terms block) and what's replaced around it, per arm.
    private func vocabularies(_ arm: Arm, again: Vocabulary, heldOut: Vocabulary?) -> (told: Vocabulary, replaced: Vocabulary) {
        switch arm {
        case .off: return (.none, .none)
        case .termsOnly: return (again, .none)
        case .again: return (again, again)
        case .heldOut: return (heldOut ?? again, heldOut ?? again)
        }
    }

    /// Each trial through `DictationController.refine` (replace, polish, replace: a dictation's path)
    /// with the setup's cloud polish backend, metered; stops sending once the answers' cost reaches the cap.
    private func polishing(_ fixes: [UUID: HistoryEntry], again: Vocabulary, heldOut: [UUID: Vocabulary], setup: DictationSetup) async {
        guard let key, !key.isEmpty else {
            return write(["part": 1, "kind": "skipped", "reason": "no key: bench/suite.py history passes the bench's own as HISTORY_BENCH_KEY"])
        }
        for (n, trial) in job.polish.enumerated() {
            if meter.total().cost >= job.maxCost {
                stopped = true
                write(["part": 1, "kind": "stopped", "cost": meter.total().cost, "ran": n, "of": job.polish.count])
                progress("part 1: stopped at the cost cap after \(n) of \(job.polish.count) calls")
                return
            }
            guard let entry = fixes[trial.id], let arm = Arm(rawValue: trial.arm) else { continue }
            let (told, replaced) = vocabularies(arm, again: again, heldOut: heldOut[trial.id])
            let backend = setup.polishBackend(apiKey: key, vocabulary: told, onDevice: { _, _ in NoOnDevicePolish() }, session: session)
                .metered(by: meter)
            let mark = meter.count
            let refined = await DictationController.refine(entry.input, terms: replaced, polisher: PolishService(backend: backend))
            write(["part": 1, "round": trial.round, "id": trial.id.uuidString, "arm": arm.rawValue, "output": refined.text,
                   "seconds": refined.seconds, "error": refined.error ?? NSNull(), "by": refined.by?.model ?? NSNull(),
                   "cost": meter.total(from: mark).cost, "toldTerms": told.entries.count])
            if (n + 1) % 10 == 0 || n + 1 == job.polish.count {
                progress("part 1: \(n + 1)/\(job.polish.count) calls, $\(String(format: "%.4f", meter.total().cost))")
            }
        }
    }

    /// Part 1 asks only the cloud: a setup with no key would polish on this Mac instead, which isn't what's measured.
    private struct NoOnDevicePolish: PolishBackend {
        func polish(_ text: String) async throws -> String { throw PolishError.unavailable("the history bench polishes in the cloud only") }
    }

    // MARK: Part 2: speech with terms

    private func speech(again: Vocabulary, heldOut: [UUID: Vocabulary]) async {
        guard let model = speechModel, model.isDownloaded else {
            return write(["part": 2, "kind": "skipped", "reason": "the on-device speech model isn't downloaded (Settings › Speech model); nothing was downloaded"])
        }
        guard !job.speech.isEmpty else {
            return write(["part": 2, "kind": "skipped", "reason": "no kept recording matches a fixed dictation"])
        }
        do { try await model.prepare().value } catch {
            return write(["part": 2, "kind": "skipped", "reason": "the on-device speech model didn't load: \(error.localizedDescription)"])
        }
        let recordings = Dictionary(job.dictations.compactMap { d in d.recording.map { (d.id, $0) } }, uniquingKeysWith: { first, _ in first })
        for (n, trial) in job.speech.enumerated() {
            guard let path = recordings[trial.id], let arm = Arm(rawValue: trial.arm) else { continue }
            let terms = arm == .off ? Vocabulary.none : arm == .heldOut ? heldOut[trial.id] ?? again : again
            let engine = LocalEngine(model: model)
            // What a dictation gives it with "Hint the on-device speech model" on.
            engine.context = DictationController.speechHint(terms, setup: .onDevice, enabled: true)
            var row: [String: Any] = ["part": 2, "id": trial.id.uuidString, "arm": arm.rawValue, "contextWords": engine.context.words.count]
            guard engine.beginRecording(), LatencyRunner.read(url(path), into: engine.record) else {
                write(row.merging(["error": "the recording couldn't be read", "transcript": "", "replaced": "", "seconds": 0]) { $1 })
                continue
            }
            let started = ProcessInfo.processInfo.systemUptime
            let (text, error) = await withCheckedContinuation { (done: CheckedContinuation<(String?, String?), Never>) in
                engine.stop(completion: { done.resume(returning: ($0, nil)) }, failure: { done.resume(returning: (nil, $0)) })
            }
            row["seconds"] = ProcessInfo.processInfo.systemUptime - started
            row["transcript"] = text ?? ""
            row["replaced"] = terms.apply(text ?? "").text
            row["error"] = error ?? NSNull()
            write(row)
            progress("part 2: \(n + 1)/\(job.speech.count) transcriptions")
        }
    }

    // MARK: Part 3: reach and wrong hits

    /// Replacement alone, with the vocabulary as it is, on every dictation: what it would change (hits
    /// counted on what replacement sees first, the raw transcript, else the pasted text), and each
    /// entry's variants flagged as case-only or as an ordinary word (`CandidateTally`'s guard).
    private func reach(_ history: [HistoryEntry], _ again: Vocabulary) {
        var withRaw = 0
        for entry in history {
            let raw = entry.raw.map { again.apply($0) }
            if entry.raw != nil { withRaw += 1 }
            let text = again.apply(entry.text)
            let rawChanged = raw.map { $0.text != entry.raw } ?? false, textChanged = text.text != entry.text
            guard rawChanged || textChanged else { continue }
            let uses = (raw ?? text).uses
            write(["part": 3, "kind": "hit", "id": entry.id.uuidString, "rawChanged": rawChanged, "textChanged": textChanged,
                   "text": entry.text, "replacedText": text.text, "target": entry.fixTarget ?? NSNull(),
                   "uses": Dictionary(uniqueKeysWithValues: uses.map { ($0.key.uuidString, $0.value) })])
        }
        write(["part": 3, "kind": "summary", "entries": history.count, "withRaw": withRaw])
        let pairs = again.entries.flatMap { e in e.heardAs.map { (heard: $0, term: e.term) } }
        var ordinary = CandidateTally.ordinary(pairs, in: history).makeIterator()
        for e in again.entries {
            let variants: [[String: Any]] = e.heardAs.map { v in
                ["text": v, "caseOnly": v != e.term && v.lowercased() == e.term.lowercased(), "ordinary": ordinary.next() ?? false]
            }
            write(["part": 3, "kind": "entry", "entry": e.id.uuidString, "term": e.term, "source": e.source.rawValue, "variants": variants])
        }
    }

    // MARK: Part 4: replacement's wait

    /// Replacement before and after polish (on the raw transcript, then the pasted text), per dictation;
    /// the fastest of 3 so a stray scheduling hiccup doesn't count.
    private func timeReplacement(_ history: [HistoryEntry], _ again: Vocabulary) {
        var seconds: [Double] = []
        for entry in history {
            guard let raw = entry.raw else { continue }
            var best = UInt64.max
            for _ in 0..<3 {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = again.apply(raw)
                _ = again.apply(entry.text)
                best = min(best, DispatchTime.now().uptimeNanoseconds - start)
            }
            seconds.append(Double(best) / 1e9)
        }
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        write(["part": 4, "kind": "replacement", "seconds": seconds, "build": build])
    }

    // MARK: Part 5: what learns

    /// Candidates by the rules alone (every verdict taken off, so none decides) and by the judge (the
    /// verdicts as they are; an unjudged change waits, as the app does with the judge on).
    private func learning(_ history: [HistoryEntry]) {
        let unjudged = history.map { entry -> HistoryEntry in
            var entry = entry
            if var intake = entry.intake {
                intake.changes = intake.changes.map { WordChange(old: $0.old, new: $0.new) }
                intake.tries = nil
                entry.intake = intake
            }
            return entry
        }
        for (method, found) in [("rules", CandidateTally.support(in: unjudged, judging: false)),
                                ("judge", CandidateTally.support(in: history, judging: true))] {
            write(["part": 5, "method": method, "candidates": found.map { c -> [String: Any] in
                ["term": c.term, "seen": c.seen, "misheard": c.misheard,
                 "heard": c.heard.map { ["text": $0.text, "dictations": $0.dictations.count, "ordinary": $0.ordinary] as [String: Any] }]
            }])
        }
    }

    // MARK: Part 6: edit replay

    /// Each fix replayed through the real `EditWatcher` with a fake Mac, once with readback (the box is
    /// read: `SpanTracker`) and once without (keys only: `TypedEdit`). Synthesized keys: per change, last
    /// first, arrows to its end, backspaces over it, the new text; the box is read after each change.
    private func replay(_ fixes: [UUID: HistoryEntry]) {
        let services = makeServices(test)
        services.settings.learnFromEdits = true
        let watcher = services.editWatcher
        for d in job.dictations {
            guard let entry = fixes[d.id], let target = entry.correction else { continue }
            let edits = Self.edits(from: entry.text, to: target)
            let needsInputMethod = edits.contains { $0.text.contains { !$0.isASCII } }
            // Text put in before the paste or after it: by design never the span's (past a space at its end), so a miss here isn't the tracker's.
            let pastTheEdge = edits.contains { $0.range.isEmpty && ($0.range.lowerBound == 0 || $0.range.lowerBound == entry.text.count) }
            for readback in [true, false] {
                let desk = FakeEditDesk()
                desk.attach(watcher)
                desk.answers = readback
                let edited = Self.replay(entry.text, edits: edits, watcher: watcher, desk: desk, history: services.history)
                let wanted = target.trimmingCharacters(in: .whitespacesAndNewlines)
                write(["part": 6, "id": d.id.uuidString, "mode": readback ? "readback" : "keystrokes", "captured": edited != nil,
                       "exact": edited == wanted, "edited": edited ?? NSNull(), "target": target, "needsInputMethod": needsInputMethod,
                       "pastTheEdge": pastTheEdge, "changes": edits.count])
            }
        }
    }

    /// Pastes `pasted` into an empty box, types the edits, presses Return; what the watcher captured.
    static func replay(_ pasted: String, edits: [(range: Range<Int>, text: [Character])], watcher: EditWatcher, desk: FakeEditDesk,
                       history: HistoryStore) -> String? {
        guard let id = history.add(text: pasted, duration: 1) else { return nil }
        var box = Array(pasted), cursor = box.count
        desk.show(pasted)
        watcher.arm(spot: FakeDesk.slack, pasted: pasted, text: pasted, entry: id)
        desk.clock.advance(EditWatcher.probeDelay)
        for edit in edits.reversed() {
            let end = edit.range.upperBound
            var keys = [EditKey](repeating: cursor > end ? .left : .right, count: abs(cursor - end))
            keys += [EditKey](repeating: .backspace, count: edit.range.count)
            keys += edit.text.map { .text(String($0)) }
            box.replaceSubrange(edit.range, with: edit.text)
            cursor = edit.range.lowerBound + edit.text.count
            desk.press(keys)
            desk.show(String(box), cursor: String(box[..<cursor]).utf16.count)
            desk.clock.advance(EditWatcher.pause)
        }
        desk.press([.returnKey])
        return history.entries.first { $0.id == id }?.capture?.edited
    }

    /// Where `new` differs from `old`, character by character: each run of characters removed (a range in
    /// `old`) and what's typed in its place, in order. Replaying every run rebuilds `new` exactly.
    static func edits(from old: String, to new: String) -> [(range: Range<Int>, text: [Character])] {
        let a = Array(old), b = Array(new)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        var out: [(range: Range<Int>, text: [Character])] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            let start = i
            var text: [Character] = []
            while i < a.count, removed.contains(i) { i += 1 }
            while j < b.count, inserted.contains(j) { text.append(b[j]); j += 1 }
            if i == start, text.isEmpty { i += 1; j += 1 } else { out.append((start..<i, text)) }
        }
        return out
    }
}

/// The history bench's harness (bench/suite.py history). In every ./test.sh it runs the fixture's job
/// (bench/history_fixture/job.json) with a stubbed network and a fake speech model, so it can't rot; for
/// real only when bench/suite.py history runs it (HISTORY_BENCH_JOB, HISTORY_BENCH_OUT, HISTORY_BENCH_KEY).
@MainActor
final class HistoryBenchTests: XCTestCase {
    private let fixture = benchFolder.appendingPathComponent("history_fixture")

    private func rows(_ url: URL) throws -> [[String: Any]] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    /// Answers each polish request with its transcript as it was sent, at $0.001 a call.
    private func stubPolish() -> URLSession {
        let session = StubURLProtocol.session()
        StubURLProtocol.respond = { request in
            let body = StubURLProtocol.body(request) ?? [:]
            let user = ((body["messages"] as? [[String: Any]])?.last?["content"] as? String) ?? ""
            let text = user.replacingOccurrences(of: "<transcript>\n", with: "").replacingOccurrences(of: "\n</transcript>", with: "")
            let reply: [String: Any] = ["choices": [["message": ["role": "assistant", "content": text]]],
                                        "usage": ["prompt_tokens": 100, "completion_tokens": 20, "cost": 0.001]]
            return .success((200, String(decoding: try! JSONSerialization.data(withJSONObject: reply), as: UTF8.self)))
        }
        return session
    }

    private func fakeSpeech(downloaded: Bool = true, text: String = "can you send me the nodes from today's meeting") -> (LocalSpeechModel, FakeSpeechRuntime) {
        let runtime = FakeSpeechRuntime()
        runtime.text = text
        if downloaded { runtime.directory = URL(fileURLWithPath: "/tmp/fake-model") }
        let model = LocalSpeechModel(repo: "test/qwen", runtime: runtime)
        model.onBattery = { false }
        return (model, runtime)
    }

    private func bench(_ job: HistoryBenchJob, out: URL) throws -> HistoryBench {
        let bench = try HistoryBench(job: job, folder: fixture, out: out, test: self)
        bench.key = "sk-test"
        bench.session = stubPolish()
        return bench
    }

    private func id(_ n: Int) -> String { "DDDDDDDD-0000-4000-8000-00000000000\(n)" }

    // MARK: The contract with the bench

    /// The bench splits words and trims their edges as WordDiff and FixIntake do (the same fixture both sides read).
    func testWordsAndEdgesAreTheBenchs() throws {
        struct Words: Decodable { let text: String; let words: [String] }
        struct Edge: Decodable { let word: String; let trimmed: String }
        struct File: Decodable { let words: [Words]; let edges: [Edge] }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: fixture.appendingPathComponent("words.json")))
        for c in file.words { XCTAssertEqual(WordDiff.words(c.text).map { String(c.text[$0]) }, c.words) }
        for c in file.edges { XCTAssertEqual(c.word.trimmingCharacters(in: FixIntake.edges), c.trimmed) }
    }

    /// The fixture's word changes are what FixIntake makes of its fixes, so its scoring means what the app's would.
    func testTheFixturesChangesAreFixIntakes() throws {
        let history = try JSONFile.decoder.decode([HistoryEntry].self, from: Data(contentsOf: fixture.appendingPathComponent("history.json")))
        for entry in history {
            guard let intake = entry.intake, let target = entry.fixTarget, intake.of == target else { continue }
            XCTAssertEqual(FixIntake.changes(from: entry.text, to: target).map { [$0.old, $0.new] }, intake.changes.map { [$0.old, $0.new] },
                           entry.id.uuidString)
        }
    }

    func testCharacterEditsRebuildTheFix() {
        for (old, new) in [("I use cloud code.", "I use Claude Code."), ("我们用克劳的写代码", "我们用 Claude 写代码"), ("abc", ""), ("", "abc")] {
            var box = Array(old)
            for edit in HistoryBench.edits(from: old, to: new).reversed() { box.replaceSubrange(edit.range, with: edit.text) }
            XCTAssertEqual(String(box), new)
        }
    }

    // MARK: The harness on the fixture

    func testRunsTheFixtureJob() async throws {
        let job = try HistoryBench.load(fixture.appendingPathComponent("job.json"))
        let out = makeTempURL(self, "rows.jsonl")
        let bench = try bench(job, out: out)
        let (model, runtime) = fakeSpeech()
        bench.speechModel = model
        try await bench.run()
        let rows = try rows(out)
        func part(_ n: Int) -> [[String: Any]] { rows.filter { $0["part"] as? Int == n } }

        let setup = try XCTUnwrap(part(0).first { $0["kind"] as? String == "setup" })
        XCTAssertEqual(setup["setup"] as? String, "cloud-flash")
        XCTAssertEqual(setup["prompt"] as? String, "v7")
        XCTAssertEqual(part(0).filter { $0["kind"] as? String == "dictation" && $0["error"] == nil }.count, 5)

        // Part 1: the real request per arm; the stub echoes the transcript, so only replacement fixes a word.
        let polish = part(1)
        XCTAssertEqual(polish.count, job.polish.count)
        func output(_ arm: String, _ n: Int) -> String {
            polish.first { $0["arm"] as? String == arm && $0["id"] as? String == id(n) && $0["round"] as? Int == 1 }?["output"] as? String ?? ""
        }
        XCTAssertTrue(output("off", 1).contains("nodes"))
        XCTAssertTrue(output("terms-only", 1).contains("nodes"), "terms told to polish, nothing replaced")
        XCTAssertTrue(output("again", 1).contains("notes"))
        XCTAssertTrue(output("held-out", 1).contains("nodes"), "the entry only this dictation taught is held out")
        XCTAssertTrue(output("again", 4).contains("Hammerspoon"))
        XCTAssertFalse(output("held-out", 4).contains("Hammerspoon"))
        XCTAssertTrue(output("again", 2).contains("Claude"))
        XCTAssertFalse(output("held-out", 2).contains("Claude"), "its variant came from this dictation alone")
        XCTAssertTrue(output("again", 9).contains("Neovim"))
        XCTAssertFalse(output("held-out", 9).contains("Neovim"), "a learned entry whose candidate says nothing: History names its source")
        let systems = StubURLProtocol.sent.compactMap { (StubURLProtocol.body($0)?["messages"] as? [[String: Any]])?.first?["content"] as? String }
        XCTAssertEqual(systems.count, job.polish.count)
        XCTAssertEqual(systems.filter { $0.contains(Vocabulary.promptHeader) }.count, job.polish.filter { $0.arm != "off" }.count,
                       "the terms block in every arm but off")
        XCTAssertEqual(StubURLProtocol.sent.first?.value(forHTTPHeaderField: "X-Title"), "DictationApp", "names its app")
        XCTAssertEqual(polish.compactMap { $0["cost"] as? Double }.reduce(0, +), 0.001 * Double(job.polish.count), accuracy: 1e-9)

        // Part 2: the speech hint as a dictation builds it.
        XCTAssertEqual(part(2).count, job.speech.count)
        XCTAssertEqual(runtime.contexts.count, job.speech.count)
        XCTAssertEqual(runtime.contexts.filter { $0.contains("notes") }.count, 1, "again only: held out drops it, off has none")
        XCTAssertEqual(runtime.contexts.filter(\.isEmpty).count, 1)
        let againSpeech = try XCTUnwrap(part(2).first { $0["arm"] as? String == "again" })
        XCTAssertEqual(againSpeech["replaced"] as? String, "can you send me the notes from today's meeting")

        // Part 3: reach, and the flags.
        let hits = part(3).filter { $0["kind"] as? String == "hit" }
        XCTAssertEqual(Set(hits.compactMap { $0["id"] as? String }).count, hits.count)
        XCTAssertTrue(hits.contains { $0["id"] as? String == "EEEEEEEE-0000-4000-8000-000000000003" }, "an unfixed dictation with an ordinary word")
        let entries = part(3).filter { $0["kind"] as? String == "entry" }
        XCTAssertEqual(entries.count, 6, "enabled entries")
        func flags(_ term: String) -> [String: Any] { (entries.first { $0["term"] as? String == term }?["variants"] as? [[String: Any]])?.first ?? [:] }
        XCTAssertEqual(flags("notes")["ordinary"] as? Bool, true)
        XCTAssertEqual(flags("reMarkable")["caseOnly"] as? Bool, true)
        XCTAssertEqual(flags("Hammerspoon")["ordinary"] as? Bool, false)

        // Part 4: a time per dictation with a raw transcript.
        XCTAssertEqual((part(4).first?["seconds"] as? [Double])?.count, 9)

        // Part 5: the rules count a change of mind; the judge doesn't.
        func terms(_ method: String) -> Set<String> {
            Set(((part(5).first { $0["method"] as? String == method }?["candidates"] as? [[String: Any]]) ?? []).compactMap { $0["term"] as? String })
        }
        XCTAssertTrue(terms("rules").contains("this morning"))
        XCTAssertFalse(terms("judge").contains("this morning"))
        XCTAssertTrue(terms("judge").contains("Claude"))

        // Part 6: every fix rebuilt by both trackers; Chinese flagged as needing an input method.
        let replays = part(6)
        XCTAssertEqual(replays.count, 10)
        XCTAssertEqual(replays.filter { $0["exact"] as? Bool == true }.count, 10)
        XCTAssertEqual(Set(replays.filter { $0["needsInputMethod"] as? Bool == true }.compactMap { $0["id"] as? String }), [id(2)])

        let done = try XCTUnwrap(rows.last)
        XCTAssertEqual(done["kind"] as? String, "done")
        XCTAssertEqual(done["stopped"] as? Bool, false)
    }

    /// Once the answers' cost reaches the cap, nothing more is sent; the rows so far are kept.
    func testStopsSendingAtTheCostCap() async throws {
        var job = try HistoryBench.load(fixture.appendingPathComponent("job.json"))
        job.maxCost = 0.0025
        job.parts = [1]
        let out = makeTempURL(self, "rows.jsonl")
        try await bench(job, out: out).run()
        let rows = try rows(out)
        XCTAssertEqual(StubURLProtocol.sent.count, 3)
        XCTAssertEqual(rows.filter { $0["part"] as? Int == 1 && $0["arm"] != nil }.count, 3)
        XCTAssertEqual(rows.filter { $0["kind"] as? String == "stopped" }.count, 1)
        XCTAssertEqual(rows.last?["stopped"] as? Bool, true)
    }

    /// No key: part 1 sends nothing (and never falls back to polishing on this Mac).
    func testWithoutAKeyPart1IsSkipped() async throws {
        var job = try HistoryBench.load(fixture.appendingPathComponent("job.json"))
        job.parts = [1]
        let out = makeTempURL(self, "rows.jsonl")
        let bench = try bench(job, out: out)
        bench.key = nil
        try await bench.run()
        XCTAssertTrue(StubURLProtocol.sent.isEmpty)
        XCTAssertEqual(try rows(out).filter { $0["kind"] as? String == "skipped" }.count, 1)
    }

    /// A model that isn't downloaded is never downloaded: part 2 says it's skipped.
    func testSkipsSpeechWhenTheModelIsntDownloaded() async throws {
        var job = try HistoryBench.load(fixture.appendingPathComponent("job.json"))
        job.parts = [2]
        let out = makeTempURL(self, "rows.jsonl")
        let bench = try bench(job, out: out)
        let (model, runtime) = fakeSpeech(downloaded: false)
        bench.speechModel = model
        try await bench.run()
        XCTAssertEqual(try rows(out).first { $0["part"] as? Int == 2 }?["kind"] as? String, "skipped")
        XCTAssertTrue(runtime.log.isEmpty, "no download, no load")
    }

    // MARK: For real

    /// bench/suite.py history run: the job it wrote, on a snapshot of your History, with the bench's key.
    func testRunsTheJobItIsGiven() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let jobPath = env["HISTORY_BENCH_JOB"], let outPath = env["HISTORY_BENCH_OUT"] else {
            throw XCTSkip("bench/suite.py history run runs it (HISTORY_BENCH_JOB, HISTORY_BENCH_OUT)")
        }
        let jobURL = URL(fileURLWithPath: jobPath)
        let job = try HistoryBench.load(jobURL)
        let bench = try HistoryBench(job: job, folder: jobURL.deletingLastPathComponent(), out: URL(fileURLWithPath: outPath), test: self)
        XCTAssertNotEqual(bench.url(job.history).standardizedFileURL, HistoryStore.defaultFileURL.standardizedFileURL, "a snapshot, never the live file")
        bench.key = env["HISTORY_BENCH_KEY"]
        bench.speechModel = LocalSpeechModel(repo: DictationSetup.onDevice.localModelID!)
        bench.verbose = true
        try await bench.run()
    }
}

/// The app's seams the history bench runs through, each the code a dictation uses.
final class HistoryBenchSeamTests: XCTestCase {
    private let terms = Vocabulary([VocabularyEntry(term: "Claude", heardAs: ["cloud"], added: Date())])

    /// Replaced before polish (so a failed polish still has the terms) and again after it.
    func testRefineReplacesAroundPolish() async {
        let polished = await DictationController.refine("ask cloud", terms: terms, polisher: PolishService(backend: FakePolish(output: "Ask cloud.")))
        XCTAssertEqual(polished.text, "Ask Claude.")
        XCTAssertEqual(polished.uses.values.reduce(0, +), 2, "once before, once after")
        XCTAssertNil(polished.error)
        let failed = await DictationController.refine("ask cloud", terms: terms,
                                                      polisher: PolishService(backend: FakePolish(error: .failed("down"))))
        XCTAssertEqual(failed.text, "ask Claude")
        XCTAssertEqual(failed.error, "down")
        let told = await DictationController.refine("ask cloud", terms: .none, polisher: PolishService(backend: FakePolish(output: "Ask cloud.")))
        XCTAssertEqual(told.text, "Ask cloud.", "no terms: nothing replaced (the bench's terms-only arm)")
    }

    func testSpeechHintIsYourTermsOnlyWhenOnAndOnDevice() {
        XCTAssertEqual(DictationController.speechHint(terms, setup: .onDevice, enabled: true), SpeechContext(words: ["Claude"]))
        XCTAssertEqual(DictationController.speechHint(terms, setup: .onDevice, enabled: false), .none)
        XCTAssertEqual(DictationController.speechHint(terms, setup: .cloudFlash, enabled: true), .none, "cloud speech takes no prompt")
        XCTAssertEqual(DictationController.speechHint(.none, setup: .onDevice, enabled: true), .none)
    }

    /// The cloud polish backend is called through the session it's given.
    func testPolishBackendTakesASession() async throws {
        let session = StubURLProtocol.session()
        StubURLProtocol.respond = { _ in .success((200, #"{"choices":[{"message":{"content":"Hi."}}]}"#)) }
        let backend = DictationSetup.cloudFlash.polishBackend(apiKey: "k", vocabulary: terms, onDevice: { _, _ in FakePolish() }, session: session)
        let answer = try await backend.polish("hi")
        XCTAssertEqual(answer, "Hi.")
        XCTAssertEqual(StubURLProtocol.sent.count, 1)
    }

    /// A heard standing in 3 dictations you didn't fix is ordinary, unless it stands there as the term itself.
    func testOrdinaryIsTheCandidateGuard() {
        let entries = ["the cloud", "a cloud", "cloud nine", "my remarkable", "Remarkable!", "remarkable"].map {
            HistoryEntry(date: Date(), text: $0, duration: 1)
        }
        XCTAssertEqual(CandidateTally.ordinary([(heard: "cloud", term: "Claude"), (heard: "remarkable", term: "reMarkable"),
                                                (heard: "nodes", term: "notes")], in: entries), [true, true, false])
        XCTAssertEqual(CandidateTally.ordinary([(heard: "cloud", term: "Claude")], in: Array(entries.prefix(2))), [false])
    }
}
