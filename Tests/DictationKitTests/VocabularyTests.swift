import XCTest
@testable import DictationKit

/// `Vocabulary`: replacement, the polish block, the speech hint and the fingerprint.
final class VocabularyTests: XCTestCase {
    private func entry(_ term: String, _ heard: [String] = [], enabled: Bool = true, uses: Int = 0,
                       added: Date = fixedDate(2026, 11, 1, 9, 0), source: VocabularyEntry.Source = .manual) -> VocabularyEntry {
        VocabularyEntry(term: term, heardAs: heard, enabled: enabled, source: source, added: added, uses: uses)
    }

    private func apply(_ text: String, _ entries: [VocabularyEntry]) -> String { Vocabulary(entries).apply(text).text }

    func testVariantsAreReplacedCaseInsensitivelyAtWordBoundaries() {
        let v = [entry("GeForce Now", ["G Four Snow", "g force now"])]
        XCTAssertEqual(apply("I play on g four snow tonight", v), "I play on GeForce Now tonight")
        XCTAssertEqual(apply("G Force Now, then bed.", v), "GeForce Now, then bed.")
        XCTAssertEqual(apply("big four snowstorm", v), "big four snowstorm", "not inside other words")
    }

    func testLatinVariantsMatchNextToChinese() {
        let v = [entry("Claude", ["Cloud"])]
        XCTAssertEqual(apply("一个用Cloud做一下", v), "一个用Claude做一下")
        XCTAssertEqual(apply("cloudy", v), "cloudy")
    }

    func testChineseVariantsMatchLiterally() {
        let v = [entry("HRV", ["而差v"]), entry("Haiku", ["Hi库"])]
        XCTAssertEqual(apply("我的而差v一般用Hi库来看", v), "我的HRV一般用Haiku来看")
    }

    func testLongestVariantFirst() {
        let v = [entry("Claude", ["cloud"]), entry("Claude Code", ["cloud code"])]
        XCTAssertEqual(apply("install cloud code and ask cloud", v), "install Claude Code and ask Claude")
    }

    /// A shorter term inside a longer variant doesn't stop it: "Claude" is a term, "claude code" still
    /// becomes "Claude Code".
    func testAShorterTermInsideAVariantDoesNotBlockIt() {
        let v = [entry("Claude", ["cloud"]), entry("Claude Code", ["claude code"]), entry("Mike"), entry("Mike Chen", ["mike chan"])]
        XCTAssertEqual(apply("open claude code, ask mike chan now", v), "open Claude Code, ask Mike Chen now")
        XCTAssertEqual(apply("open Claude Code", v), "open Claude Code")
        let once = apply("open claude code and cloud", v)
        XCTAssertEqual(once, "open Claude Code and Claude")
        XCTAssertEqual(apply(once, v), once)
    }

    /// A variant across part of a term that stands is left alone.
    func testAVariantAcrossPartOfATermIsLeftAlone() {
        XCTAssertEqual(apply("GeForce Now please", [entry("GeForce Now"), entry("Now please", ["now please"])]), "GeForce Now please")
    }

    func testATermIsUsedTrimmed() {
        XCTAssertEqual(apply("ask cloud", [entry("Claude ", ["cloud"])]), "ask Claude")
    }

    /// Variant "Claude", term "Claude Code": where "Claude Code" already stands it's left alone.
    func testAVariantInsideItsOwnTermIsNotReplacedAgain() {
        let v = [entry("Claude Code", ["Claude"])]
        XCTAssertEqual(apply("Claude Code is open", v), "Claude Code is open")
        XCTAssertEqual(apply("ask Claude", v), "ask Claude Code")
        // The variant at the term's end, not only its start.
        let tail = [entry("GeForce Now", ["Now"])]
        XCTAssertEqual(apply("GeForce Now works", tail), "GeForce Now works")
    }

    func testACaseOnlyVariantFixesTheCase() {
        let v = [entry("reMarkable", ["remarkable"])]
        XCTAssertEqual(apply("my Remarkable tablet", v), "my reMarkable tablet")
        let (text, uses) = Vocabulary(v).apply("my reMarkable tablet")
        XCTAssertEqual(text, "my reMarkable tablet")
        XCTAssertEqual(uses, [:], "already right: not a use")
    }

    /// One entry's term is another's variant: where that term stands, it stays.
    func testATermThatIsAnotherEntrysVariantStays() {
        let v = [entry("X-ray", ["Xray"]), entry("Xray", ["ex ray"])]
        XCTAssertEqual(apply("ex ray", v), "Xray")
        XCTAssertEqual(apply("Xray", v), "Xray")
    }

    func testIdempotent() {
        let v = [entry("Claude", ["cloud", "Coloule"]), entry("Claude Code", ["cloud code", "Claude"]),
                 entry("GeForce Now", ["G Four Snow", "Now"]), entry("reMarkable", ["remarkable"]),
                 entry("HRV", ["而差v"]), entry("X-ray", ["Xray"]), entry("Xray", ["ex ray"])]
        for text in ["install cloud code, ask Coloule, then Claude", "G Four Snow now and GeForce Now",
                     "a Remarkable 而差v reading", "ex ray of an Xray", "Claude Code Claude cloud"] {
            let once = apply(text, v)
            XCTAssertEqual(apply(once, v), once, text)
        }
    }

    func testCountsUsesPerEntry() {
        let claude = entry("Claude", ["cloud"]), haiku = entry("Haiku", ["high cool"])
        let (text, uses) = Vocabulary([claude, haiku]).apply("cloud and cloud with high cool")
        XCTAssertEqual(text, "Claude and Claude with Haiku")
        XCTAssertEqual(uses, [claude.id: 2, haiku.id: 1])
    }

    func testDisabledEntriesAndEmptyVocabularyChangeNothing() {
        XCTAssertEqual(apply("ask cloud", [entry("Claude", ["cloud"], enabled: false)]), "ask cloud")
        XCTAssertEqual(Vocabulary.none.apply("ask cloud").text, "ask cloud")
        XCTAssertTrue(Vocabulary([entry("Claude", ["cloud"], enabled: false)]).isEmpty)
    }

    // MARK: Polish block

    func testPromptBlockMostUsedThenNewest() {
        let v = Vocabulary([entry("reMarkable", added: fixedDate(2026, 11, 2, 9, 0)),
                            entry("GeForce Now", ["G Four Snow", "g force now"], uses: 9),
                            entry("Codex", added: fixedDate(2026, 11, 3, 9, 0)),
                            entry("Off", enabled: false)])
        XCTAssertEqual(v.promptBlock, """
            Vocabulary (write these exactly; the recognizer may mishear them):
            GeForce Now (heard as: G Four Snow, g force now)
            Codex
            reMarkable
            """)
    }

    func testPromptBlockIsCappedAndEmptyWithoutTerms() {
        let many = (0..<150).map { entry("Term\($0)", uses: $0) }
        let lines = Vocabulary(many).promptBlock.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 1 + Vocabulary.maxPromptTerms)
        XCTAssertEqual(lines[1], "Term149")
        XCTAssertEqual(Vocabulary.none.promptBlock, "")
    }

    /// The one helper every backend built from a setup uses: no terms, the prompt as it was.
    func testInstructionsAppendTheBlockOnlyWithTerms() {
        XCTAssertEqual(Vocabulary.none.instructions("PROMPT"), "PROMPT")
        let v = Vocabulary([entry("Codex")])
        XCTAssertEqual(v.instructions("PROMPT"), "PROMPT\n\n" + v.promptBlock)
        XCTAssertEqual(DictationSetup.cloudFlash.instructions(v), v.instructions(DictationSetup.cloudFlash.promptText))
    }

    // MARK: Speech hint and fingerprint

    func testSpeechWordsAreTheTermsMostUsedFirstAtMost50() {
        let many = (0..<80).map { entry("Term\($0)", uses: $0) }
        let words = Vocabulary(many).speechWords
        XCTAssertEqual(words.count, 50)
        XCTAssertEqual(words.first, "Term79")
    }

    func testFingerprintFollowsTermsAndVariantsOnly() {
        var a = entry("Claude", ["cloud"])
        let before = Vocabulary([a]).fingerprint
        XCTAssertNotNil(before)
        a.uses = 12
        XCTAssertEqual(Vocabulary([a]).fingerprint, before, "a replacement firing doesn't make a measurement stale")
        a.heardAs.append("Coloule")
        XCTAssertNotEqual(Vocabulary([a]).fingerprint, before)
        XCTAssertNil(Vocabulary.none.fingerprint, "no terms: today's measurements still count")
        XCTAssertNil(Vocabulary([entry("Claude", enabled: false)]).fingerprint)
    }

    /// The store's fingerprint (what the tile looks up) and a snapshot's (what a tune records) agree.
    func testTheStoreAndASnapshotFingerprintAlike() throws {
        let url = makeTempURL(self, "vocabulary.json")
        try #"{"entries": [{"term": "Claude ", "heardAs": ["cloud"]}]}"#.write(to: url, atomically: true, encoding: .utf8)
        let store = VocabularyStore(fileURL: url)
        XCTAssertNotNil(store.fingerprint(enabled: true))
        XCTAssertEqual(store.fingerprint(enabled: true), store.vocabulary(enabled: true).fingerprint)
    }
}
