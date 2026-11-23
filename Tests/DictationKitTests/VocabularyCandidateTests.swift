import XCTest
@testable import DictationKit

/// Candidates: terms you fixed, counted by dictation (`CandidateTally`), and how the store learns
/// them (`VocabularyStore.updateCandidates`, Add now, dismiss).
final class VocabularyCandidateTests: XCTestCase {
    private var minute = 0

    /// A dictation, corrected or not, newest last in the order made; its intake worked out as the idle pass would.
    private func dictation(_ text: String, _ correction: String? = nil) -> HistoryEntry {
        minute += 1
        return entryWithIntake(text, correction: correction, date: fixedDate(2026, 11, 22, 9, minute))
    }

    /// History newest first, as `HistoryStore` keeps it.
    private func support(_ entries: [HistoryEntry]) -> [VocabularyCandidate] {
        CandidateTally.support(in: entries.reversed())
    }

    private func makeStore() -> VocabularyStore {
        let store = makeVocabulary(self)
        store.now = { fixedDate(2026, 11, 22, 12, 0) }
        return store
    }

    /// Claude fixed in 3 dictations, misheard 3 ways (new dictations each time it's asked for).
    private var claudeThreeTimes: [HistoryEntry] {
        [dictation("I use cloud.", "I use Claude."), dictation("ask Coloule now", "ask Claude now"), dictation("Klod said no", "Claude said no")]
    }

    // MARK: Tally

    func testATermIsCountedAcrossTheWaysItWasMisheard() throws {
        let found = support([dictation("I use cloud.", "I use Claude."), dictation("ask Coloule now", "ask claude now")])
        XCTAssertEqual(found.count, 1, "one per term, any case")
        let claude = try XCTUnwrap(found.first)
        XCTAssertEqual(claude.term, "claude", "the newest spelling")
        XCTAssertEqual(claude.heard.map(\.text), ["Coloule", "cloud"])
        XCTAssertEqual(claude.seen, 2)
    }

    func testOneDictationCountsOnce() {
        let found = support([dictation("cloud and cloud", "Claude and Claude"), dictation("Cloud again", "Claude again")])
        XCTAssertEqual(found.first?.seen, 2)
        XCTAssertEqual(found.first?.heard.map(\.text), ["Cloud"], "one variant in any case, as written last")
        XCTAssertEqual(found.first?.heard.map(\.dictations.count), [2])
    }

    func testLongChangesAndInsertionsDontCount() {
        XCTAssertEqual(support([dictation("so alpha beta gamma delta epsilon then", "so it was a long one then")]).count, 0, "more than 4 words")
        XCTAssertEqual(support([dictation("I want it", "I really want it")]).count, 0)
        XCTAssertEqual(support([dictation("g four snow now ok", "GeForce Now ok")]).map(\.term), ["GeForce Now"], "4 words is fine")
    }

    /// "cloud" also stands in 3 dictations you didn't correct: it's an ordinary word there, so
    /// cloud → Claude doesn't count and "cloud" would never be replaced everywhere.
    func testAnOrdinaryWordDoesNotCount() {
        let fix = dictation("I use cloud.", "I use Claude.")
        let plain = [dictation("the cloud is up"), dictation("Cloud storage"), dictation("cloud nine")]
        XCTAssertEqual(support([fix] + plain.prefix(2)).first?.seen, 1, "in 2 uncorrected dictations: still counts")
        XCTAssertEqual(support([fix] + plain).count, 0, "in 3: ordinary")
        XCTAssertEqual(support([fix, dictation("clouds and cloudy"), dictation("cloudy"), dictation("clouds")]).first?.seen, 1,
                       "matched as replacement would: whole words only")
    }

    /// A case fix ("remarkable" → "reMarkable"): where the term already stands as written, the
    /// heard isn't standing as an ordinary word.
    func testWhereTheTermStandsTheHeardIsNotOrdinary() {
        let fix = dictation("my remarkable tablet", "my reMarkable tablet")
        let plain = [dictation("the reMarkable is charged"), dictation("reMarkable sync"), dictation("a reMarkable 2")]
        XCTAssertEqual(support([fix] + plain).first?.heard.first?.ordinary, false)
    }

    /// A change judged misheard counts even when its heard is ordinary; the variant is
    /// still never added.
    func testAMisheardVerdictCountsAnOrdinaryWord() throws {
        var fix = dictation("I use cloud.", "I use Claude.")
        fix.intake?.changes[0].verdict = .misheard
        let found = support([fix, dictation("the cloud"), dictation("cloud nine"), dictation("Cloud storage")])
        let heard = try XCTUnwrap(found.first?.heard.first)
        XCTAssertTrue(heard.ordinary)
        XCTAssertTrue(heard.misheard)
        var style = dictation("Cloud said no", "Claude said no")
        style.intake?.changes[0].verdict = .style
        XCTAssertEqual(support([style]).count, 0, "judged anything else: doesn't count")
    }

    /// A capitalized sentence start ("the" → "The") is caught by the ordinary-word guard; a name
    /// fixed by case ("claude" → "Claude", "iphone" → "iPhone") is a term.
    func testCaseFixes() {
        let plain = [dictation("the cat sat"), dictation("on the mat"), dictation("all the time")]
        XCTAssertEqual(support([dictation("the end", "The end"), dictation("the cat", "The cat"), dictation("the dog", "The dog")] + plain).count, 0)
        XCTAssertEqual(support([dictation("ask claude", "ask Claude"), dictation("my iphone", "my iPhone")]).map(\.term), ["iPhone", "Claude"])
    }

    func testOnlyCurrentIntakeCounts() {
        var removed = dictation("I use cloud.", "I use Claude.")
        removed.correction = nil  // the correction was deleted; the pass hasn't cleared intake yet
        var edited = dictation("Cloud said no", "Claude said no")
        edited.correction = "Claude said yes"
        XCTAssertEqual(support([removed, edited, dictation("ask Coloule now", "ask Claude now")]).first?.seen, 1)
    }

    func testChineseTerms() {
        let found = support([dictation("我在用克劳德写代码", "我在用Claude写代码"), dictation("我的而差v一般", "我的HRV一般")])
        XCTAssertEqual(Set(found.map(\.term)), ["Claude", "HRV"])
        XCTAssertEqual(found.first { $0.term == "Claude" }?.heard.map(\.text), ["克劳德"])
    }

    // MARK: Store

    func testThreeDictationsLearnATerm() throws {
        let store = makeStore()
        store.updateCandidates(support(Array(claudeThreeTimes.prefix(2))), learnAfter: 3)
        XCTAssertTrue(store.entries.isEmpty, "2 of 3")
        XCTAssertEqual(store.candidates.first?.seen, 2)
        store.updateCandidates(support(claudeThreeTimes), learnAfter: 3)
        let entry = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(entry.term, "Claude")
        XCTAssertEqual(Set(entry.heardAs), ["cloud", "Coloule", "Klod"])
        XCTAssertEqual(entry.source, .learned)
        XCTAssertEqual(entry.added, fixedDate(2026, 11, 22, 12, 0))
        XCTAssertEqual(store.candidates.first?.added, true)
        XCTAssertEqual(VocabularyStore(fileURL: store.fileURL).candidates, store.candidates, "saved in vocabulary.json")
    }

    func testWithUseVocabularyOffNothingIsAdded() {
        let store = makeStore()
        store.updateCandidates(support(claudeThreeTimes), learnAfter: nil)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(store.candidates.first?.seen, 3, "still collected")
    }

    func testAnOrdinaryVariantIsNeverAdded() throws {
        var fixes = claudeThreeTimes
        fixes[0].intake?.changes[0].verdict = .misheard
        let store = makeStore()
        store.updateCandidates(support(fixes + [dictation("the cloud"), dictation("cloud nine"), dictation("a cloud")]), learnAfter: 3)
        XCTAssertEqual(store.entries.first?.heardAs.sorted(), ["Coloule", "Klod"], "the term is learned; “cloud” isn't a variant")
    }

    func testADismissedTermNeverComesBack() {
        let store = makeStore()
        store.updateCandidates(support(Array(claudeThreeTimes.prefix(1))), learnAfter: 3)
        store.dismiss("claude")
        store.updateCandidates(support(claudeThreeTimes), learnAfter: 3)
        XCTAssertTrue(store.entries.isEmpty)
        store.updateCandidates([], learnAfter: 3)
        XCTAssertEqual(store.candidates.map(\.dismissed), [true], "remembered with nothing left to count")
        store.updateCandidates(support(claudeThreeTimes), learnAfter: 3)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testAnExistingTermGainsTheVariants() throws {
        let store = makeStore()
        store.add(term: "claude", heardAs: ["Claud"])
        store.updateCandidates(support(claudeThreeTimes), learnAfter: 3)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].term, "claude", "yours, as you wrote it")
        XCTAssertEqual(store.entries[0].source, .manual)
        XCTAssertEqual(store.entries[0].heardAs.first, "Claud")
        XCTAssertEqual(Set(store.entries[0].heardAs), ["Claud", "cloud", "Coloule", "Klod"])
    }

    /// What was handed over once isn't handed over again: a learned term you delete, or a variant
    /// you take off, stays gone. A new way of mishearing it is still added.
    func testWhatYouRemoveStaysRemoved() throws {
        let store = makeStore()
        store.updateCandidates(support(claudeThreeTimes), learnAfter: 3)
        var entry = try XCTUnwrap(store.entries.first)
        entry.heardAs.removeAll { $0 == "Coloule" }
        store.update(entry)
        let claud = dictation("call Claud", "call Claude")
        store.updateCandidates(support(claudeThreeTimes + [claud]), learnAfter: 3)
        XCTAssertEqual(Set(store.entries.first?.heardAs ?? []), ["cloud", "Klod"],
                       "once a term is in, a new variant seen once isn't enough (it could be a change of mind)")
        store.updateCandidates(support(claudeThreeTimes + [claud, dictation("Claud again", "Claude again")]), learnAfter: 3)
        XCTAssertEqual(Set(store.entries.first?.heardAs ?? []), ["cloud", "Klod", "Claud"], "seen twice, it is")
        store.remove(term: "Claude")
        let klaude = [dictation("try Klaude", "try Claude"), dictation("Klaude no", "Claude no")]
        store.updateCandidates(support(claudeThreeTimes + klaude), learnAfter: 3)
        XCTAssertTrue(store.entries.isEmpty, "deleted stays deleted")
    }

    func testAddNowLearnsAtOnce() throws {
        let store = makeStore()
        store.updateCandidates(support([dictation("I use cloud.", "I use Claude.")]), learnAfter: 3)
        store.learn("claude")
        XCTAssertEqual(store.entries.map(\.term), ["Claude"])
        XCTAssertEqual(store.entries.first?.heardAs, ["cloud"])
        XCTAssertEqual(store.entries.first?.source, .learned)
    }

    /// A heard with a comma in it (it takes a *misheard* verdict to count) is one variant, not two
    /// ("well" would be replaced everywhere).
    func testAHeardWithACommaStaysOneVariant() {
        // The tally no longer makes such a heard (punctuation inside); this guards hand-built and older candidates.
        let store = makeStore()
        let id = UUID()
        store.updateCandidates([VocabularyCandidate(term: "Claude", heard: [.init(text: "well, cloud", dictations: [id], misheard: true)])], learnAfter: 1)
        XCTAssertEqual(store.entries.first?.heardAs, ["well, cloud"])
    }

    /// A misheard verdict doesn't waive the shape: more than 4 words a side, or sentence punctuation
    /// inside (a period, a Chinese comma), is never a candidate; 4 words with none still is.
    func testAMisheardVerdictStillNeedsTheShape() {
        func misheard(_ text: String, _ correction: String) -> HistoryEntry {
            var entry = dictation(text, correction)
            entry.intake!.changes = entry.intake!.changes.map { WordChange(old: $0.old, new: $0.new, verdict: .misheard) }
            return entry
        }
        let five = misheard("so alpha beta gamma delta epsilon then", "so Alphabet then")
        XCTAssertEqual(five.intake?.changes.map(\.old), ["alpha beta gamma delta epsilon"])
        XCTAssertEqual(support([five]).count, 0, "5 words heard")
        let period = misheard("ask cloud. Then go", "ask Claude go")
        XCTAssertEqual(period.intake?.changes.map(\.old), ["cloud. Then"])
        XCTAssertEqual(support([period]).count, 0, "a period inside")
        let chinese = misheard("我说 克劳，德 走", "我说 Claude 走")
        XCTAssertEqual(chinese.intake?.changes.count, 1)
        XCTAssertTrue(chinese.intake!.changes[0].old.contains("，"), chinese.intake!.changes[0].old)
        XCTAssertLessThanOrEqual(FixIntake.wordCount(chinese.intake!.changes[0].old), CandidateTally.maxWords, "only the comma rules it out")
        XCTAssertEqual(support([chinese]).count, 0, "a Chinese comma inside")
        XCTAssertEqual(support([misheard("ok g four snow now then", "ok GeForce Now then")]).map(\.term), ["GeForce Now"], "4 words, no punctuation")
        XCTAssertEqual(support([misheard("ok g four snow now then", "ok GeForce Now then")]).first?.heard.first?.misheard, true)
    }

    /// Chinese sentence punctuation counts as punctuation inside, as English does.
    func testChineseSentencePunctuationIsPunctuationInside() {
        for mark in ["，", "。", "！", "？", "；"] {
            XCTAssertTrue(FixIntake.hasPunctuationInside("克劳德" + mark + "然后"), mark)
        }
        XCTAssertFalse(FixIntake.hasPunctuationInside("克劳德 code"))
    }

    /// Punctuation inside either side means formatting or rewording, not a term.
    func testFormattingFixesDontCount() {
        XCTAssertEqual(support([dictation("save the file two more", "save the file. Two more")]).count, 0)
        XCTAssertEqual(support([dictation("dark mode, for example on", "dark mode on")]).count, 0)
        XCTAssertEqual(support([dictation("我说 OK，然后 走", "我说 OK 走")]).count, 0)
        XCTAssertEqual(support([dictation("then things so first we", "then things.\n\nFirst we")]).count, 0)
        XCTAssertEqual(support([dictation("use no JS and see plus plus", "use Node.js and C++")]).map(\.term), ["Node.js", "C++"],
                       "a mark with no space after it is part of the term")
    }

    /// Deleting a correction lowers its term's count: candidates are counted again from History each time.
    func testDeletingACorrectionLowersTheCount() {
        var fixes = claudeThreeTimes
        let store = makeStore()
        store.updateCandidates(support(Array(fixes.prefix(2))), learnAfter: 3)
        XCTAssertEqual(store.candidates.first?.seen, 2)
        fixes[0].correction = nil
        fixes[0].intake = nil
        store.updateCandidates(support(Array(fixes.prefix(2))), learnAfter: 3)
        XCTAssertEqual(store.candidates.first?.seen, 1)
        store.updateCandidates([], learnAfter: 3)
        XCTAssertTrue(store.candidates.isEmpty, "nothing left to count, nothing to remember")
    }

    func testANoChangePassWritesNothing() throws {
        let store = makeStore(), fixes = Array(claudeThreeTimes.prefix(2))
        store.updateCandidates(support(fixes), learnAfter: 3)
        let written = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.modificationDate] as? Date
        var published = 0
        let watching = store.objectWillChange.sink { _ in published += 1 }
        defer { watching.cancel() }
        spinRunLoop(0.02)
        store.updateCandidates(support(fixes), learnAfter: 3)
        XCTAssertEqual(published, 0)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.modificationDate] as? Date, written)
    }

    func testLearnAfterIsASettingWithNoRow() throws {
        let settings = makeSettings(self)
        XCTAssertEqual(settings.vocabularyLearnAfter, 3)
        let entry = try XCTUnwrap(settings.entries.first { $0.name == "vocabularyLearnAfter" }, "on the settings command line")
        XCTAssertTrue(entry.set(" 5 "))
        XCTAssertFalse(entry.set("five"))
        XCTAssertEqual(settings.vocabularyLearnAfter, 5)
        let store = makeStore()
        store.updateCandidates(support([dictation("I use cloud.", "I use Claude.")]), learnAfter: 0)
        XCTAssertEqual(store.entries.map(\.term), ["Claude"], "below 1 counts as 1")
    }

    // MARK: vocabulary.json

    /// A verdict a newer build wrote reads as none here, rather than History failing to load.
    func testAnUnknownVerdictStillLoads() throws {
        let url = makeTempURL(self)
        try Data(#"[{"id":"7F1D7C55-0000-4000-8000-000000000001","date":"2026-10-07T07:00:00Z","text":"cloud","duration":1,"correction":"Claude","intake":{"of":"Claude","changes":[{"old":"cloud","new":"Claude","verdict":"somethingNew"}]}}]"#.utf8).write(to: url)
        let entry = try XCTUnwrap(HistoryStore(fileURL: url, defaults: makeDefaults(self)).entries.first)
        XCTAssertEqual(entry.intake?.changes, [WordChange(old: "cloud", new: "Claude")])
    }

    /// The idle pass keeps each entry's `corrected` at its candidate's dictations, Add now too; a
    /// term with no correction in History has 0.
    func testEntriesKeepHowOftenTheyWereCorrected() {
        let store = makeStore()
        store.add(term: "Typed")
        let three = claudeThreeTimes
        store.updateCandidates(support(three), learnAfter: 3)
        XCTAssertEqual(store.entries.first { $0.term == "Claude" }?.corrected, 3)
        XCTAssertEqual(store.entries.first { $0.term == "Typed" }?.corrected, 0)
        store.updateCandidates(support(Array(three.prefix(1))), learnAfter: 3)
        XCTAssertEqual(store.entries.first { $0.term == "Claude" }?.corrected, 1, "follows History")
        store.updateCandidates(support([dictation("ask code x", "ask Codex")]), learnAfter: 3)
        XCTAssertEqual(store.entries.first { $0.term == "Claude" }?.corrected, 0, "no longer in History")
        store.learn("codex")
        XCTAssertEqual(store.entries.first { $0.term == "Codex" }?.corrected, 1, "Add now")
        store.updateCandidates(support([dictation("ask code x", "ask Codex"), dictation("use jim and eye", "use Gemini")]), learnAfter: 3)
        store.add(term: "Gemini")
        XCTAssertEqual(store.entries.first { $0.term == "Gemini" }?.corrected, 1, "typed in with a candidate: counted at once")
        var edited = store.entries.first { $0.term == "Gemini" }!
        edited.uses = 99
        edited.corrected = 99
        store.update(edited)
        XCTAssertEqual(store.entries.first { $0.term == "Gemini" }?.uses, 0, "the editor's copy doesn't set counts")
        XCTAssertEqual(store.entries.first { $0.term == "Gemini" }?.corrected, 1)
    }

    func testAPhaseOneFileStillLoads() throws {
        let url = makeTempURL(self, "vocabulary.json")
        try #"{"entries": [{"term": "Claude", "heardAs": ["cloud"]}]}"#.write(to: url, atomically: true, encoding: .utf8)
        let store = VocabularyStore(fileURL: url)
        XCTAssertNil(store.problem)
        XCTAssertEqual(store.entries.map(\.term), ["Claude"])
        XCTAssertTrue(store.candidates.isEmpty)
        try #"{"entries": [], "candidates": [{"term": "Claude", "heard": [{"text": "cloud"}]}]}"#.write(to: url, atomically: true, encoding: .utf8)
        store.reloadIfChanged()
        XCTAssertEqual(store.candidates.first?.heard.first?.dictations, [], "hand-edited: only what's needed")
        XCTAssertEqual(store.candidates.first?.dismissed, false)
    }

    /// The pass never moves an unreadable vocabulary.json aside: only something you do does.
    func testAnUnreadableFileIsLeftAlone() throws {
        let url = makeTempURL(self, "vocabulary.json")
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        let store = VocabularyStore(fileURL: url)
        store.updateCandidates(support(claudeThreeTimes), learnAfter: 3)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "not json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.asideURL.path))
    }
}
