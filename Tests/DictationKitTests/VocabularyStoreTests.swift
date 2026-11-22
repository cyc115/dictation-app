import XCTest
@testable import DictationKit

/// `VocabularyStore`: vocabulary.json, read back, and changes made by another process (the command line).
final class VocabularyStoreTests: XCTestCase {
    private func makeStore(_ url: URL? = nil) -> VocabularyStore {
        let store = VocabularyStore(fileURL: url ?? makeTempURL(self, "vocabulary.json"))
        store.now = { fixedDate(2026, 11, 22, 9, 0) }
        return store
    }

    func testAddSavesAndReadsBack() throws {
        let url = makeTempURL(self, "vocabulary.json")
        let store = makeStore(url)
        XCTAssertTrue(store.entries.isEmpty, "no file yet")
        let added = try XCTUnwrap(store.add(term: " GeForce Now ", heardAs: ["G Four Snow", " ", "g force now"]))
        XCTAssertEqual(added.term, "GeForce Now")
        XCTAssertEqual(added.heardAs, ["G Four Snow", "g force now"])
        XCTAssertEqual(added.source, .manual)
        XCTAssertEqual(added.added, fixedDate(2026, 11, 22, 9, 0))
        XCTAssertEqual(VocabularyStore(fileURL: url).entries, [added], "remembered")
        XCTAssertNil(store.add(term: "  "), "a blank term isn't added")
    }

    func testAddingAnExistingTermMergesItsVariants() throws {
        let store = makeStore()
        store.add(term: "Claude", heardAs: ["cloud"])
        store.add(term: "claude", heardAs: ["Cloud", "Coloule"])
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].term, "Claude", "the first spelling stays")
        XCTAssertEqual(store.entries[0].heardAs, ["cloud", "Coloule"])
    }

    func testEditToggleAndRemove() throws {
        let store = makeStore()
        var entry = try XCTUnwrap(store.add(term: "Codex"))
        store.add(term: "Haiku", heardAs: ["high cool"])
        entry.heardAs = ["code x"]
        store.update(entry)
        store.setEnabled(false, for: entry.id)
        XCTAssertEqual(store.entries.first?.heardAs, ["code x"])
        XCTAssertEqual(store.entries.first?.enabled, false)
        XCTAssertEqual(store.vocabulary(enabled: true).entries.map(\.term), ["Haiku"], "only enabled ones apply")
        XCTAssertTrue(store.vocabulary(enabled: false).isEmpty, "Use vocabulary off")
        XCTAssertTrue(store.remove(term: "haiku"))
        XCTAssertFalse(store.remove(term: "Haiku"))
        store.remove(id: entry.id)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testRecordUsesAddsUp() throws {
        let store = makeStore()
        let claude = try XCTUnwrap(store.add(term: "Claude", heardAs: ["cloud"]))
        store.recordUses([claude.id: 2])
        store.recordUses([claude.id: 1, UUID(): 5])
        XCTAssertEqual(store.entries.first?.uses, 3)
        store.recordUses([:])
    }

    /// `DictationApp vocabulary add` writes the file from another process; the app sees it at the
    /// next dictation (or when the page is shown), and a save of its own doesn't undo it.
    func testAChangeFromAnotherProcessIsPickedUpAndKept() throws {
        let url = makeTempURL(self, "vocabulary.json")
        let app = makeStore(url)
        let claude = try XCTUnwrap(app.add(term: "Claude", heardAs: ["cloud"]))
        let commandLine = makeStore(url)
        commandLine.add(term: "Haiku", heardAs: ["high cool"])
        XCTAssertEqual(app.entries.count, 1, "not until it looks")
        app.reloadIfChanged()
        XCTAssertEqual(app.entries.map(\.term), ["Claude", "Haiku"])

        commandLine.remove(term: "Haiku")
        app.recordUses([claude.id: 1])  // saving after a paste re-reads first
        XCTAssertEqual(VocabularyStore(fileURL: url).entries.map(\.term), ["Claude"])
        XCTAssertEqual(VocabularyStore(fileURL: url).entries.first?.uses, 1)
    }

    func testReloadWithoutAChangeDoesNotPublish() throws {
        let store = makeStore()
        store.add(term: "Claude")
        var changes = 0
        let sink = store.objectWillChange.sink { _ in changes += 1 }
        defer { sink.cancel() }
        store.reloadIfChanged()
        XCTAssertEqual(changes, 0, "its own save isn't a change")
    }

    func testHeardAsTextIsSplitOnCommas() {
        XCTAssertEqual(VocabularyEntry.variants(from: " G Four Snow, g force now ，  , gforce"), ["G Four Snow", "g force now", "gforce"])
        XCTAssertEqual(VocabularyEntry.variants(from: ""), [])
    }

    func testAHandEditedFileWithOnlyTermsLoads() throws {
        let url = makeTempURL(self, "vocabulary.json")
        try #"{"entries": [{"term": "reMarkable"}, {"term": "Claude", "heardAs": ["cloud"], "enabled": false}]}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let store = VocabularyStore(fileURL: url)
        XCTAssertEqual(store.entries.map(\.term), ["reMarkable", "Claude"])
        XCTAssertEqual(store.entries.map(\.enabled), [true, false])
    }
}
