import AppKit
import SwiftUI
import XCTest
@testable import DictationKit

/// The Vocabulary tab and Settings › Vocabulary, driven through their accessibility identifiers.
final class VocabularyUITests: XCTestCase {
    private func tab(_ store: VocabularyStore, search: String = "") -> HostedView<VocabularyView> {
        host(VocabularyView(store: store, search: search), size: NSSize(width: 760, height: 700))
    }

    /// Clicks a text field and types into it, as a user would.
    private func type(_ text: String, into id: String, in hosted: HostedView<VocabularyView>) throws {
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: id), id)))
        let field = try XCTUnwrap(hosted.window.firstResponder as? NSTextView, "\(id) has the cursor")
        field.selectAll(nil)
        field.insertText(text, replacementRange: field.selectedRange())
        hosted.settle()
    }

    func testAddingATerm() throws {
        let store = makeVocabulary(self)
        let hosted = tab(store)
        XCTAssertNotNil(hosted.element(id: "vocabulary.empty"))
        try type("GeForce Now", into: "vocabulary.add.term", in: hosted)
        try type("G Four Snow, g force now", into: "vocabulary.add.heard", in: hosted)
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "vocabulary.add"))))
        XCTAssertEqual(store.entries.map(\.term), ["GeForce Now"])
        XCTAssertEqual(store.entries.first?.heardAs, ["G Four Snow", "g force now"])
        XCTAssertNotNil(hosted.element(id: "vocabulary.row.GeForce Now"))
        XCTAssertNotNil(hosted.element(id: "vocabulary.chip.G Four Snow"))
        XCTAssertEqual(hosted.element(id: "vocabulary.details.GeForce Now")?.text.contains("You added · not used yet"), true)
        XCTAssertNil(hosted.element(id: "vocabulary.empty"))
    }

    func testTurningOffAndDeletingATerm() throws {
        let store = makeVocabulary(self)
        store.add(term: "Claude", heardAs: ["cloud"])
        store.add(term: "Codex")
        let hosted = tab(store)
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "vocabulary.switch.Claude"))))
        XCTAssertEqual(store.entries.first?.enabled, false)
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "vocabulary.delete.Claude"))))
        XCTAssertNotNil(hosted.element(id: "vocabulary.confirmDelete.Claude"), "asks first")
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "vocabulary.cancelDelete.Claude"))))
        XCTAssertEqual(store.entries.count, 2, "cancel keeps it")
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "vocabulary.delete.Claude"))))
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "vocabulary.confirmDelete.Claude"))))
        XCTAssertEqual(store.entries.map(\.term), ["Codex"])
        XCTAssertNil(hosted.element(id: "vocabulary.row.Claude"))
    }

    func testClickingAVariantEditsTheTerm() throws {
        let store = makeVocabulary(self)
        store.add(term: "Claude", heardAs: ["cloud"])
        let hosted = tab(store)
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "vocabulary.chip.cloud"))))
        XCTAssertNotNil(hosted.element(id: "vocabulary.edit.term"))
        try type("cloud, Coloule", into: "vocabulary.edit.heard", in: hosted)
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "vocabulary.edit.save"))))
        XCTAssertEqual(store.entries.first?.heardAs, ["cloud", "Coloule"])
        XCTAssertNil(hosted.element(id: "vocabulary.edit.term"), "back to the row")
        XCTAssertNotNil(hosted.element(id: "vocabulary.chip.Coloule"))

        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "vocabulary.term.Claude"))))
        try type("Claude Code", into: "vocabulary.edit.term", in: hosted)
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "vocabulary.edit.cancel"))))
        XCTAssertEqual(store.entries.first?.term, "Claude", "cancel keeps it")
    }

    func testSearchFindsTermsAndVariants() {
        let store = makeVocabulary(self)
        store.add(term: "Claude", heardAs: ["cloud"])
        store.add(term: "Haiku", heardAs: ["high cool"])
        let byVariant = tab(store, search: "COOL")
        XCTAssertNotNil(byVariant.element(id: "vocabulary.row.Haiku"))
        XCTAssertNil(byVariant.element(id: "vocabulary.row.Claude"))
        let none = tab(store, search: "zzz")
        XCTAssertTrue(none.element(id: "vocabulary.empty")?.text.contains("None matches") ?? false)
    }

    /// A term added from the command line shows when the tab is shown.
    func testTheTabReReadsTheFile() {
        let store = makeVocabulary(self)
        VocabularyStore(fileURL: store.fileURL).add(term: "Codex")
        let hosted = tab(store)
        XCTAssertNotNil(hosted.element(id: "vocabulary.row.Codex"))
    }

    /// Candidates as the idle pass leaves them: Claude seen in 2 dictations, HRV and GeForce Now in one.
    private func storeWithCandidates() -> VocabularyStore {
        let store = makeVocabulary(self)
        let d = (0..<4).map { _ in UUID() }
        store.updateCandidates([
            VocabularyCandidate(term: "HRV", heard: [.init(text: "而差v", dictations: [d[0]])]),
            VocabularyCandidate(term: "Claude", heard: [.init(text: "Coloule", dictations: [d[1]]),
                                                        .init(text: "cloud", dictations: [d[2]], ordinary: true)]),
            VocabularyCandidate(term: "GeForce Now", heard: [.init(text: "G Four Snow", dictations: [d[3]])]),
        ], learnAfter: 3)
        return store
    }

    func testSeenInYourEditsListsTermsSeenTwiceAndTheRestBehindShowAll() throws {
        let store = storeWithCandidates()
        let hosted = tab(store)
        XCTAssertNotNil(hosted.element(id: "vocabulary.candidate.Claude"))
        XCTAssertEqual(hosted.element(id: "vocabulary.candidate.seen.Claude")?.text.contains("2 of 3"), true)
        XCTAssertNotNil(hosted.element(id: "vocabulary.candidate.heard.cloud"))
        XCTAssertNil(hosted.element(id: "vocabulary.candidate.HRV"), "seen once: behind Show all")
        let showAll = try XCTUnwrap(hosted.element(id: "vocabulary.candidates.showAll"))
        XCTAssertTrue(showAll.text.contains("Show all (3)"))
        XCTAssertTrue(hosted.click(showAll))
        XCTAssertNotNil(hosted.element(id: "vocabulary.candidate.HRV"))
        XCTAssertEqual(hosted.element(id: "vocabulary.candidate.seen.HRV")?.text.contains("1 of 3"), true)
        XCTAssertTrue(hosted.allText.contains("A term fixed in 3 dictations is added on its own"))
        XCTAssertTrue(host(VocabularyView(store: store, learning: false), size: NSSize(width: 760, height: 700))
            .allText.contains("Use vocabulary is off, so none is added on its own"))
    }

    func testAddNowAndDismiss() throws {
        let store = storeWithCandidates()
        let hosted = tab(store)
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "vocabulary.addNow.Claude"))))
        XCTAssertEqual(store.entries.map(\.term), ["Claude"])
        XCTAssertEqual(store.entries.first?.heardAs, ["Coloule"], "not the ordinary word")
        XCTAssertNil(hosted.element(id: "vocabulary.candidate.Claude"), "now in Your terms")
        XCTAssertNotNil(hosted.element(id: "vocabulary.row.Claude"))

        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "vocabulary.candidates.showAll"))))
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "vocabulary.dismiss.HRV"))))
        XCTAssertEqual(store.candidates.first { $0.term == "HRV" }?.dismissed, true)
        XCTAssertNil(hosted.element(id: "vocabulary.candidate.HRV"))
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "vocabulary.dismiss.GeForce Now"))))
        XCTAssertNil(hosted.element(id: "vocabulary.candidates.showAll"), "none left: the group is gone")
        XCTAssertFalse(hosted.allText.contains("Seen in your edits"))
    }

    func testSettingsSectionTurnsItOffAndSendsYouToTheTab() throws {
        let services = makeServices(self)
        var shown = 0
        let hosted = host(SettingsView(services: services, onShowVocabulary: { shown += 1 }), size: NSSize(width: 640, height: 3400))
        XCTAssertNotNil(hosted.element(id: "setting.Use vocabulary"))
        XCTAssertEqual(hosted.element(id: "setting.Hint the on-device speech model")?.isEnabled, true)
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "setting.Vocabulary"))))
        XCTAssertEqual(shown, 1)
        XCTAssertTrue(hosted.click(try XCTUnwrap(hosted.element(id: "setting.Use vocabulary"))))
        XCTAssertFalse(services.settings.vocabularyEnabled)
        XCTAssertFalse(services.settings.vocabularySpeechHint, "off by default (it once wrote the terms instead of the dictation)")
    }
}
