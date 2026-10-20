import AppKit
import SwiftUI
import XCTest
@testable import DictationKit

final class HistoryUITests: XCTestCase {
    private func makeStore() -> HistoryStore {
        let store = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        store.add(text: "Hello from the history page.", duration: 2)
        store.add(text: "还有一个问题，中英文混用 works too.", duration: 3)
        return store
    }

    func testRowsListedAndCopyWritesTranscript() {
        let pasteboard = makePasteboard(self)
        HistoryRow.pasteboard = pasteboard
        addTeardownBlock { HistoryRow.pasteboard = .general }

        let store = makeStore()
        let hosted = HostedView(HistoryView(store: store), size: NSSize(width: 760, height: 560))
        addTeardownBlock { hosted.close() }

        let copyButtons = hosted.elements(id: "history.copy")
        XCTAssertEqual(copyButtons.count, 2, "one copy button per entry")
        XCTAssertTrue(copyButtons.first.map(hosted.click) ?? false)
        let copied = pasteboard.string(forType: .string)
        XCTAssertTrue(store.entries.map(\.text).contains(copied ?? ""), "copied: \(copied ?? "nil")")
    }

    func testEmptyStateWhenNoHistory() {
        let store = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        let hosted = HostedView(HistoryView(store: store), size: NSSize(width: 760, height: 400))
        addTeardownBlock { hosted.close() }
        XCTAssertTrue(hosted.elements(id: "history.copy").isEmpty)
        XCTAssertEqual(hosted.element(id: "history.empty").flatMap { $0.label ?? $0.value }?.hasPrefix("No dictations yet"), true)
    }

    func testEmptyStateSaysWhereToTurnHistoryBackOn() {
        let store = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        store.retention = .off
        let hosted = HostedView(HistoryView(store: store), size: NSSize(width: 760, height: 400))
        addTeardownBlock { hosted.close() }
        XCTAssertEqual(hosted.element(id: "history.empty").flatMap { $0.label ?? $0.value }?.contains("Settings"), true)
    }

    func testNewDictationAppearsLive() {
        let store = makeStore()
        let hosted = HostedView(HistoryView(store: store), size: NSSize(width: 760, height: 560))
        addTeardownBlock { hosted.close() }
        store.add(text: "Just dictated.", duration: 1)
        hosted.settle()
        XCTAssertEqual(hosted.elements(id: "history.copy").count, 3)
    }
}

final class CorrectionsUITests: XCTestCase {
    func testPencilMakesACorrectionAndOpensIt() {
        let store = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        store.add(text: "Can you install Cloud Code?", duration: 2)
        var opened: UUID?
        let hosted = HostedView(HistoryView(store: store, onCorrect: { opened = $0 }), size: NSSize(width: 760, height: 400))
        addTeardownBlock { hosted.close() }
        let pencil = hosted.element(id: "history.correct")
        XCTAssertEqual(pencil?.label, "Correct this dictation")
        XCTAssertTrue(pencil.map(hosted.click) ?? false)
        XCTAssertEqual(opened, store.entries[0].id)
        XCTAssertEqual(store.corrections.first?.correction, "Can you install Cloud Code?", "starts as what the app wrote")
        XCTAssertEqual(hosted.element(id: "history.correct")?.label, "Open correction")

        hosted.click(hosted.element(id: "history.correct")!)
        XCTAssertEqual(store.corrections.count, 1, "opening it again doesn't make another")
    }

    func testCardsShowBothSidesAndTypingSaves() throws {
        let store = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        store.add(text: "Can you install Cloud Code?", duration: 2, raw: "can you install cloud code", setup: "cloud-flash", prompt: "v3")
        store.add(text: "Not corrected.", duration: 1)
        let id = store.entries[1].id
        store.setCorrection("Can you install Claude Code?", for: id)
        let hosted = HostedView(CorrectionsView(store: store, editing: id), size: NSSize(width: 760, height: 480))
        addTeardownBlock { hosted.close() }

        XCTAssertEqual(hosted.elements(id: "corrections.card").count, 1, "only corrected dictations")
        XCTAssertTrue(hosted.allText.contains("Cloud Flash · prompt v3"), hosted.allText)
        XCTAssertTrue(hosted.allText.contains("Before polish"))
        let editor = try XCTUnwrap(hosted.element(id: "corrections.wanted"))
        hosted.click(editor)
        let field = try XCTUnwrap(hosted.window.firstResponder as? NSTextView, "the editor has the cursor")
        field.moveToEndOfDocument(nil)
        field.insertText(" Thanks.", replacementRange: field.selectedRange())
        hosted.settle()
        XCTAssertEqual(store.corrections.first?.correction, "Can you install Claude Code? Thanks.")

        hosted.click(try XCTUnwrap(hosted.element(id: "corrections.delete")))
        hosted.window.makeFirstResponder(nil)
        hosted.settle()
        XCTAssertTrue(store.corrections.isEmpty)
        XCTAssertNotNil(hosted.element(id: "corrections.empty"))
    }

    func testChangedWordsAreFound() {
        func changed(_ old: String, _ new: String) -> [String] { WordDiff.changed(from: old, to: new).map { String(old[$0]) } }
        XCTAssertEqual(changed("Can you install Cloud Code?", "Can you install Claude Code?"), ["Cloud"])
        XCTAssertEqual(changed("No, I. So I want the app.", "I want the app."), ["No,", "I.", "So"])
        XCTAssertEqual(changed("那你让我看干什么？", "那你想让我看什么？"), ["干"])
        XCTAssertEqual(changed("Same text.", "Same text."), [])
    }

    func testPencilPrefillsACloudPolishOfWhatYouSaid() {
        let store = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        store.add(text: "Can you install Cloud Code?", duration: 2, raw: "can you install cloud code", setup: "cloud-flash", prompt: "v3")
        let log = EventLog()
        let polish = FakePolish(delay: 0.5, output: "Can you install Claude Code?", log: log)
        let suggester = CorrectionSuggester { polish }
        let hosted = HostedView(HistoryView(store: store, suggester: suggester), size: NSSize(width: 760, height: 400))
        addTeardownBlock { hosted.close() }
        hosted.click(hosted.element(id: "history.correct")!)
        XCTAssertEqual(store.entries[0].correction, "Can you install Cloud Code?", "the app's text until the model answers")
        XCTAssertEqual(suggester.pending, [store.entries[0].id])
        waitUntil { suggester.pending.isEmpty }
        XCTAssertEqual(store.entries[0].correction, "Can you install Claude Code?")
        XCTAssertEqual(store.entries[0].text, "Can you install Cloud Code?", "left side is still what the app wrote")

        hosted.click(hosted.element(id: "history.correct")!)
        spinRunLoop(0.1)
        XCTAssertEqual(log.events.filter { $0 == "polish" }.count, 1, "opening an existing correction doesn't ask again")
    }

    func testSuggestionUsesTheChosenSetupsPrompt() throws {
        let model = try XCTUnwrap(CorrectionSuggester.backend(apiKey: "k", setup: .cloudBig) as? OpenRouterPolish)
        XCTAssertEqual(model.model, "openai/gpt-6.1-sol-pro")
        XCTAssertEqual(model.instructions, DictationSetup.cloudBig.promptText)
        XCTAssertEqual(model.wrap, DictationSetup.cloudBig.wrap)
        XCTAssertNil(CorrectionSuggester.backend(apiKey: "", setup: .cloudFlash), "no key, no suggestion")
    }

    func testSuggestionDoesNotOverwriteWhatYouTyped() {
        let store = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        store.add(text: "Cloud Code", duration: 1)
        let suggester = CorrectionSuggester { FakePolish(delay: 0.2, output: "Claude Code") }
        store.setCorrection("Cloud Code", for: store.entries[0].id)
        suggester.suggest(for: store.entries[0], in: store)
        store.setCorrection("Claude Code, the CLI", for: store.entries[0].id)
        waitUntil { suggester.pending.isEmpty }
        XCTAssertEqual(store.entries[0].correction, "Claude Code, the CLI")
    }

    func testSuggestionFailureKeepsTheAppsTextAndSaysWhy() {
        let store = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        store.add(text: "Cloud Code", duration: 1)
        let suggester = CorrectionSuggester { FakePolish(error: .failed("No credits.")) }
        store.setCorrection("Cloud Code", for: store.entries[0].id)
        suggester.suggest(for: store.entries[0], in: store)
        waitUntil { suggester.pending.isEmpty }
        XCTAssertEqual(store.entries[0].correction, "Cloud Code")
        XCTAssertEqual(suggester.failed[store.entries[0].id], "No credits.")

        let noKey = CorrectionSuggester { nil }
        noKey.suggest(for: store.entries[0], in: store)
        XCTAssertTrue(noKey.pending.isEmpty, "no API key: nothing asked")
    }

    func testClearAllSaysCorrectionsGoToo() {
        XCTAssertEqual(HistoryView.clearTitle(corrections: 0), "Delete all dictation history?")
        XCTAssertEqual(HistoryView.clearTitle(corrections: 1), "Delete all dictation history, including 1 correction?")
        XCTAssertEqual(HistoryView.clearTitle(corrections: 3), "Delete all dictation history, including 3 corrections?")
    }
}

final class InsightsUITests: XCTestCase {
    func testCardsShowFormattedTotals() {
        let insights = Insights(defaults: makeDefaults(self))
        // 19,400 words over 3h31m.
        insights.record(text: Array(repeating: "w", count: 19_400).joined(separator: " "), duration: 3 * 3600 + 31 * 60)
        let hosted = HostedView(InsightsView(insights: insights), size: NSSize(width: 600, height: 260))
        addTeardownBlock { hosted.close() }

        func text(_ caption: String) -> String {
            guard let card = hosted.element(id: "insights." + caption) else { return "<missing>" }
            return "\(card.label ?? "") \(card.value ?? "")"
        }
        XCTAssertTrue(text("Words dictated").contains("19.4K"), text("Words dictated"))
        XCTAssertTrue(text("Total dictation time").contains("3") && text("Total dictation time").contains("31"),
                      text("Total dictation time"))
        XCTAssertTrue(text("Average dictation speed").contains("\(insights.wordsPerMinute)"),
                      text("Average dictation speed"))
        XCTAssertTrue(text("Time saved").contains("hr"), text("Time saved"))
    }
}
