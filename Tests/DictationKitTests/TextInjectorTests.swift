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
        var seenAtPaste: String?
        injector.paste = { seenAtPaste = pasteboard.string(forType: .string) }

        injector.inject("dictated text")
        XCTAssertEqual(seenAtPaste, "dictated text")
        spinRunLoop(0.2)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        XCTAssertEqual(pasteboard.data(forType: custom), Data([1, 2, 3]))
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
