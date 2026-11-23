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
    /// `prompt`: "learned" (the setup's active learned prompt) or "base" (its built-in one); nil is learned.
    struct PolishTrial: Decodable { let round: Int; let id: UUID; let arm: String; let prompt: String? }
    struct SpeechTrial: Decodable { let id: UUID; let arm: String }

    let history: String
    let vocabulary: String
    var learnedPrompts: String?
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
        let (base, fellBack) = resolveSetup()
        let learned = learnedSetup(base)
        write(["part": 0, "kind": "setup", "setup": base.id, "prompt": (learned ?? base).prompt, "basePrompt": base.prompt,
               "learnedPrompt": learned?.prompt ?? NSNull(), "polish": base.polish, "fellBack": fellBack,
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
        if parts.contains(1) { await polishing(fixes, again: again, heldOut: heldOut, prompts: promptSetups(base: base, learned: learned)) }
        if parts.contains(2) { await speech(again: again, heldOut: heldOut) }
        write(["part": -1, "kind": "done", "cost": meter.total().cost, "calls": meter.count, "stopped": stopped])
    }

    /// The setup part 1 polishes with, as read (built-in or in setups.json), before any learned prompt:
    /// its own prompt (`promptText` with no `learnedText`), what it polishes with before a tune. Cloud
    /// Flash's when that one polishes on this Mac.
    func resolveSetup() -> (DictationSetup, Bool) {
        var all = DictationSetup.builtIns
        if let path = job.setups { all += DictationSetup.loadCustom(from: url(path)).setups }
        let named = all.first { $0.id == DictationSetup.currentID(job.setup) } ?? .cloudFlash
        let fellBack = named.polishesOnDevice
        return (fellBack ? DictationSetup.cloudFlash : named, fellBack)
    }

    /// Part 1's prompts by name: base, learned (nil when none is active), and each built-in version the
    /// job names ("v4"): the setup with that version as its `prompt` and no learned text, as a setup
    /// with `"prompt": "v4"` reads it (`promptText` → `PolishPrompt.text(for:)`).
    func promptSetups(base: DictationSetup, learned: DictationSetup?) -> [String: DictationSetup?] {
        var found: [String: DictationSetup?] = ["base": base, "learned": learned]
        for name in Set(job.polish.compactMap(\.prompt)) where found[name] == nil && PolishPrompt.versions[name] != nil {
            var version = base
            version.prompt = name
            version.learnedText = nil
            found[name] = version
        }
        return found
    }

    /// That setup with its active learned prompt applied, as `AppSettings` applies it (`LearnedPromptStore.apply(to:)`);
    /// nil when it has none.
    func learnedSetup(_ base: DictationSetup) -> DictationSetup? {
        guard let path = job.learnedPrompts else { return nil }
        let applied = LearnedPromptStore(fileURL: url(path)).apply(to: base)
        return applied.usesLearnedPrompt ? applied : nil
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
    private func polishing(_ fixes: [UUID: HistoryEntry], again: Vocabulary, heldOut: [UUID: Vocabulary],
                           prompts: [String: DictationSetup?]) async {
        guard let key, !key.isEmpty else {
            return write(["part": 1, "kind": "skipped", "reason": "no key: bench/suite.py history passes the bench's own as HISTORY_BENCH_KEY"])
        }
        var noPrompt = Set<String>()
        for (n, trial) in job.polish.enumerated() {
            if meter.total().cost >= job.maxCost {
                stopped = true
                write(["part": 1, "kind": "stopped", "cost": meter.total().cost, "ran": n, "of": job.polish.count])
                progress("part 1: stopped at the cost cap after \(n) of \(job.polish.count) calls")
                return
            }
            guard let entry = fixes[trial.id], let arm = Arm(rawValue: trial.arm) else { continue }
            let prompt = trial.prompt ?? "learned"
            guard let found = prompts[prompt], let setup = found else {
                if noPrompt.insert(prompt).inserted {
                    write(["part": 1, "kind": "skipped", "prompt": prompt, "reason": "the setup has no \(prompt) prompt: its trials weren't run"])
                }
                continue
            }
            let (told, replaced) = vocabularies(arm, again: again, heldOut: heldOut[trial.id])
            let backend = setup.polishBackend(apiKey: key, vocabulary: told, onDevice: { _, _ in NoOnDevicePolish() }, session: session)
                .metered(by: meter)
            let mark = meter.count
            let refined = await DictationController.refine(entry.input, terms: replaced, polisher: PolishService(backend: backend))
            write(["part": 1, "round": trial.round, "id": trial.id.uuidString, "prompt": prompt, "promptVersion": setup.prompt,
                   "arm": arm.rawValue, "output": refined.text,
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
            row["seconds"] = ProcessInfo.processInfo.systemUptime - started  // both passes, when the context was echoed
            row["echoed"] = engine.lastEchoed
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
