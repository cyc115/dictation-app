import AppKit
import XCTest
@testable import DictationKit

/// Keystroke mode: the pasted text followed in memory from your keys.
final class TypedEditTests: XCTestCase {
    /// Applies `keys` to a paste of `pasted`; nil if it gave up.
    private func typed(_ pasted: String, _ keys: [EditKey]) -> String? {
        var edit = TypedEdit(pasted: pasted)
        for key in keys { guard edit.apply(key) else { return nil } }
        return edit.span
    }

    private func type(_ text: String) -> [EditKey] { text.map { .text(String($0)) } }
    private func times(_ n: Int, _ key: EditKey) -> [EditKey] { Array(repeating: key, count: n) }

    func testBackspaceAndRetypeTheLastWord() {
        XCTAssertEqual(typed(" I use cloud", times(5, .backspace) + type("Claude")), " I use Claude")
    }

    func testArrowsMoveTheCursorAndDeleteRemovesAhead() {
        XCTAssertEqual(typed(" a cloud b", times(2, .left) + times(5, .left) + times(5, .forwardDelete) + type("Claude")), " a Claude b")
        XCTAssertEqual(typed(" ab", [.left, .right, .text("c")]), " abc")
    }

    func testWordMovesAndOptionBackspace() {
        XCTAssertEqual(typed(" I use cloud code", [.wordLeft, .wordLeft, .deleteWordBack] + type("love ")), " I love cloud code",
                       "⌥⌫ takes the word and the space after it, as on a Mac")
        XCTAssertEqual(typed(" one two three", [.wordLeft, .wordLeft, .wordRight, .text("s")]), " one twos three")
    }

    func testShiftSelectionsAreReplaced() {
        XCTAssertEqual(typed(" cloud code", times(4, EditKey.left.shifted) + type("Code")), " cloud Code")
        XCTAssertEqual(typed(" I use cloud", [EditKey.wordLeft.shifted] + type("Claude")), " I use Claude")
        XCTAssertEqual(typed(" a cloud", [EditKey.wordLeft.shifted, .backspace] + type("b")), " a b")
        XCTAssertEqual(typed(" a cloud", [EditKey.wordLeft.shifted, .left, .text("x")]), " a xcloud", "← lands at the selection's start")
        XCTAssertEqual(typed(" a cloud", [.wordLeft, EditKey.right.shifted, EditKey.right.shifted, .right, .text("x")]), " a clxoud",
                       "→ lands at its end")
    }

    /// What's typed after the paste, starting with a space, isn't part of the edit; typed right onto
    /// its last word, it is.
    func testTextTypedAfterThePasteIsNotPartOfIt() {
        XCTAssertEqual(typed(" fix cloud", times(5, .backspace) + type("Claude and more")), " fix Claude",
                       "the last word retyped, then more")
        XCTAssertEqual(typed(" fix cloud", type(" and more")), " fix cloud")
        XCTAssertEqual(typed(" fix cloud", type("s and more")), " fix clouds")
        XCTAssertEqual(typed(" a cloud", type(" thanks") + times(7, .left) + times(5, .backspace) + type("Claude")), " a Claude",
                       "a fix made after typing on: the typed text stays apart")
    }

    func testEditsInChineseByCharacter() {
        XCTAssertEqual(typed("我用克劳的", [.backspace, .text("德")]), "我用克劳德")
    }

    /// Wherever it can't be sure what the box holds now, it gives up.
    func testGivesUpWhereItCantFollow() {
        XCTAssertNil(typed(" a", [.other]), "any other shortcut")
        XCTAssertNil(typed(" a", [.returnKey]), "Return ends the watch; it isn't an edit")
        XCTAssertNil(typed("ab", times(3, .backspace)), "into text before the paste")
        XCTAssertNil(typed("ab", times(3, .left)))
        XCTAssertNil(typed("ab", [.right]), "into text after it")
        XCTAssertNil(typed("ab", [.forwardDelete]))
        XCTAssertNil(typed("one two", [.wordLeft, .wordLeft]), "a word that may go on before the paste")
        XCTAssertNil(typed(" one two", [.wordLeft, .wordRight]), "to the end of what's known")
        XCTAssertNil(typed(" 我用克劳的", [.wordLeft]), "Chinese words are split by a dictionary")
        XCTAssertNil(typed("one", [.deleteWordBack]))
    }

    /// Keys from the event tap: what's followed, and every shortcut.
    func testKeysFromTheEventTap() {
        let none: CGEventFlags = []
        XCTAssertEqual(EditKey(code: 0, flags: none, characters: "a"), .text("a"))
        XCTAssertEqual(EditKey(code: 0, flags: .maskShift, characters: "A"), .text("A"))
        XCTAssertEqual(EditKey(code: 0, flags: .maskAlternate, characters: "å"), .text("å"))
        XCTAssertEqual(EditKey(code: 14, flags: .maskAlternate, characters: ""), .other, "a dead key (⌥E)")
        XCTAssertEqual(EditKey(code: 0, flags: .maskCommand, characters: "a"), .other, "⌘A")
        XCTAssertEqual(EditKey(code: 6, flags: .maskControl, characters: "\u{1A}"), .other, "⌃Z")
        XCTAssertEqual(EditKey(code: 0x33, flags: none, characters: "\u{7F}"), .backspace)
        XCTAssertEqual(EditKey(code: 0x33, flags: .maskAlternate, characters: "\u{7F}"), .deleteWordBack)
        XCTAssertEqual(EditKey(code: 0x33, flags: .maskCommand, characters: "\u{7F}"), .other, "⌘⌫")
        XCTAssertEqual(EditKey(code: 0x75, flags: none, characters: "\u{F728}"), .forwardDelete)
        let arrow: CGEventFlags = [.maskSecondaryFn, .maskNumericPad]  // every arrow press has these
        XCTAssertEqual(EditKey(code: 0x7B, flags: arrow, characters: "\u{F702}"), .left)
        XCTAssertEqual(EditKey(code: 0x7C, flags: arrow.union(.maskShift), characters: "\u{F703}"), EditKey.right.shifted)
        XCTAssertEqual(EditKey(code: 0x7B, flags: arrow.union([.maskAlternate, .maskShift]), characters: "\u{F702}"), EditKey.wordLeft.shifted)
        XCTAssertEqual(EditKey(code: 0x7B, flags: arrow.union(.maskCommand), characters: "\u{F702}"), .other, "⌘←")
        XCTAssertEqual(EditKey(code: 0x7E, flags: arrow, characters: "\u{F700}"), .other, "↑")
        XCTAssertEqual(EditKey(code: 0x30, flags: none, characters: "\t"), .other, "Tab")
        XCTAssertEqual(EditKey(code: 0x35, flags: none, characters: "\u{1B}"), .other, "Esc")
        XCTAssertEqual(EditKey(code: 0x24, flags: none, characters: "\r"), .returnKey)
        XCTAssertEqual(EditKey(code: 0x24, flags: .maskShift, characters: "\r"), .returnKey, "⇧↩ ends it too")
        XCTAssertEqual(EditKey(code: 0x4C, flags: none, characters: "\u{3}"), .returnKey)
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 0x7B, keyDown: true)!  // made, never posted
        event.flags = [.maskAlternate, .maskSecondaryFn]
        XCTAssertEqual(EditKey(event: event), .wordLeft)
    }
}

/// Readback mode: where the pasted text is in the box, read after read.
final class SpanTrackerTests: XCTestCase {
    private func tracker(_ value: String, pasted: String) -> SpanTracker? {
        SpanTracker(value: value, cursor: value.utf16.count, pasted: pasted)
    }

    func testTheProbeFindsThePasteWhereTheCursorIs() {
        XCTAssertEqual(SpanTracker(value: "Hi there, I use cloud", cursor: 21, pasted: " I use cloud")?.span, " I use cloud")
        XCTAssertEqual(SpanTracker(value: "Hi I use cloud. Bye", cursor: 15, pasted: " I use cloud.")?.span, " I use cloud.")
        XCTAssertNil(SpanTracker(value: "Hi there", cursor: 8, pasted: " I use cloud"), "the paste isn't there (not taken yet, or changed)")
        XCTAssertNil(SpanTracker(value: "Hi I use cloud", cursor: 3, pasted: " I use cloud"), "not where the cursor says")
        XCTAssertNil(SpanTracker(value: "Hi I use cloud", cursor: nil, pasted: " I use cloud"), "the app doesn't say where the cursor is")
        XCTAssertNil(SpanTracker(value: "😀 cloud", cursor: 99, pasted: " cloud"))
    }

    func testAnEditInsideIsTheSpans() {
        var t = tracker("Hi I use cloud code.", pasted: " I use cloud code.")!
        XCTAssertTrue(t.update("Hi I use Claude code."))
        XCTAssertTrue(t.update("Hi I use Claude Code."))
        XCTAssertEqual(t.span, " I use Claude Code.")
    }

    func testEditsBeforeAndAfterMoveItButArentPartOfIt() {
        var t = SpanTracker(value: "Hi cloud. Bye", cursor: 9, pasted: " cloud.")!
        XCTAssertTrue(t.update("Hello cloud. Bye"), "before")
        XCTAssertTrue(t.update("Hello cloud. Bye now"), "after")
        XCTAssertTrue(t.update("Hello Claude. Bye now"))
        XCTAssertEqual(t.span, " Claude.")
    }

    func testTextTypedAtTheEndStartingWithASpaceIsntPartOfIt() {
        var t = tracker("Hi cloud", pasted: " cloud")!
        XCTAssertTrue(t.update("Hi Claude"))
        XCTAssertTrue(t.update("Hi Claude and more"))
        XCTAssertEqual(t.span, " Claude")
        XCTAssertTrue(t.update("Hi Claudes and more"), "typed onto its last word")
        XCTAssertEqual(t.span, " Claudes")
    }

    func testAChangeAcrossItsEdgeKeepsTheLastState() {
        var t = tracker("Hi cloud", pasted: " cloud")!
        XCTAssertTrue(t.update("Hi Claude"))
        XCTAssertFalse(t.update(""), "the box was cleared (sent)")
        XCTAssertEqual(t.span, " Claude")
        var u = tracker("Hi cloud", pasted: " cloud")!
        XCTAssertFalse(u.update("Hello"), "a selection from before it into it")
        XCTAssertEqual(u.span, " cloud")
    }

    func testOffsetsAreUTF16() {
        var t = tracker("😀 我用克劳的", pasted: " 我用克劳的")!
        XCTAssertTrue(t.update("😀😀 我用克劳的"))
        XCTAssertTrue(t.update("😀😀 我用克劳德"))
        XCTAssertEqual(t.span, " 我用克劳德")
    }
}
