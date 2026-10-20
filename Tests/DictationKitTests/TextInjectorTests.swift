import AppKit
import XCTest
@testable import DictationKit

final class TextInjectorTests: XCTestCase {
    func testPastesTextThenRestoresOriginalClipboardWithAllTypes() {
        let pasteboard = makePasteboard(self)
        let custom = NSPasteboard.PasteboardType("com.example.custom")
        let item = NSPasteboardItem()
        item.setString("original", forType: .string)
        item.setData(Data([1, 2, 3]), forType: custom)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        let injector = TextInjector()
        injector.pasteboard = pasteboard
        injector.restoreDelay = 0.05
        injector.canPaste = { true }
        injector.charBeforeCursor = { nil }
        var seenAtPaste: String?
        injector.paste = { seenAtPaste = pasteboard.string(forType: .string) }

        injector.inject("dictated text")
        XCTAssertEqual(seenAtPaste, "dictated text")
        spinRunLoop(0.2)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        XCTAssertEqual(pasteboard.data(forType: custom), Data([1, 2, 3]))
    }

    func testPastesASpaceFirstAfterOtherText() {
        let pasteboard = makePasteboard(self)
        let injector = TextInjector()
        injector.pasteboard = pasteboard
        injector.restoreDelay = 0.01
        injector.canPaste = { true }
        var pasted: [String] = []
        injector.paste = { pasted.append(pasteboard.string(forType: .string) ?? "") }
        for before: Character? in ["d", " ", nil] {
            injector.charBeforeCursor = { before }
            injector.inject("next")
        }
        XCTAssertEqual(pasted, [" next", "next", "next"])
    }

    func testSpaceRule() {
        let cases: [(Character?, String, Bool)] = [
            ("d", "next", true), (".", "Next", true), ("1", "2", true), ("\"", "next", true),
            (nil, "next", false),  // empty field, or the app doesn't say (terminals, some web fields)
            (" ", "next", false), ("\n", "next", false), ("\t", "next", false),
            ("d", " next", false), ("(", "next", false), ("[", "next", false),
            ("d", ", and", false), ("d", ".", false), ("d", "?", false), ("d", ")", false),
            // Chinese: a space between Chinese and English, none between Chinese and Chinese.
            ("个", "text field", true), ("I", "觉得", true), ("们", "觉得", false),
            ("す", "日本", false), ("，", "next", false), ("。", "我", false), ("d", "，", false),
            ("」", "我", false), ("😀", "next", true),
            ("d", "", false),
        ]
        for (before, text, expected) in cases {
            XCTAssertEqual(TextInjector.needsSpace(after: before, before: text), expected,
                           "\(String(describing: before)) + \(text)")
        }
    }

    func testDoesNothingWithoutAccessibility() {
        let pasteboard = makePasteboard(self)
        pasteboard.clearContents()
        pasteboard.setString("untouched", forType: .string)
        let injector = TextInjector()
        injector.pasteboard = pasteboard
        injector.canPaste = { false }
        var pasted = false
        injector.paste = { pasted = true }
        injector.inject("x")
        XCTAssertFalse(pasted)
        XCTAssertEqual(pasteboard.string(forType: .string), "untouched")
    }

    func testPressReturnNeedsAccessibility() {
        let injector = TextInjector()
        var presses = 0
        injector.postReturn = { presses += 1 }
        injector.canPaste = { false }
        injector.pressReturn()
        injector.canPaste = { true }
        injector.pressReturn()
        XCTAssertEqual(presses, 1)
    }
}
