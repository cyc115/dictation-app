import XCTest
@testable import DictationKit

/// The on-device recognizer restarts its transcript after each pause: the last result of an
/// utterance carries metadata, then the next results contain only the new words.
/// (Sequence below is from a real recognizer run on a 24 s recording with three pauses.)
final class TranscriptAccumulatorTests: XCTestCase {
    func testKeepsEveryUtteranceAcrossPauses() {
        var t = TranscriptAccumulator()
        t.update("This is the first part", utteranceEnded: false)
        t.update("This is the first part of a long dictation about the new settings page", utteranceEnded: false)
        t.update("This is the first part of a long dictation about the new settings page", utteranceEnded: true)
        t.update("Here", utteranceEnded: false)
        t.update("Here is the second part after a short pause about the history window", utteranceEnded: false)
        t.update("Here is the second part after a short pause about the history window", utteranceEnded: true)
        t.update("And this is the third part after a longer pause about the app icon", utteranceEnded: true)
        t.update("Finally, the fourth part wraps everything", utteranceEnded: false)
        t.update("Finally, the fourth part wraps everything up", utteranceEnded: true)
        XCTAssertEqual(t.text, "This is the first part of a long dictation about the new settings page. "
            + "Here is the second part after a short pause about the history window. "
            + "And this is the third part after a longer pause about the app icon. "
            + "Finally, the fourth part wraps everything up")
    }

    func testInProgressUtteranceIncludedWhenStoppedEarly() {
        var t = TranscriptAccumulator()
        t.update("First sentence done", utteranceEnded: true)
        t.update("second one still go", utteranceEnded: false)
        XCTAssertEqual(t.text, "First sentence done second one still go", "no period before a lowercase continuation")
    }

    func testPartialRevisionsReplaceRatherThanAppend() {
        var t = TranscriptAccumulator()
        t.update("Their", utteranceEnded: false)
        t.update("There is", utteranceEnded: false)
        XCTAssertEqual(t.text, "There is")
    }

    func testDuplicateEndOfUtteranceIgnored() {
        var t = TranscriptAccumulator()
        t.update("Hello world", utteranceEnded: true)
        t.update("Hello world", utteranceEnded: true)
        XCTAssertEqual(t.text, "Hello world")
    }

    func testExistingPunctuationKept() {
        var t = TranscriptAccumulator()
        t.update("Is this working?", utteranceEnded: true)
        t.update("Yes, it is.", utteranceEnded: true)
        XCTAssertEqual(t.text, "Is this working? Yes, it is.")
    }

    func testChineseUtterancesJoinWithoutSpaces() {
        var t = TranscriptAccumulator()
        t.update("我今天很高兴", utteranceEnded: true)
        t.update("明天也是", utteranceEnded: true)
        XCTAssertEqual(t.text, "我今天很高兴。明天也是")
    }

    func testEmptyIsEmpty() {
        var t = TranscriptAccumulator()
        XCTAssertEqual(t.text, "")
        t.update("", utteranceEnded: true)
        XCTAssertEqual(t.text, "")
    }
}

final class StreamingOutputTests: XCTestCase {
    func testTypesEachUtteranceAsItFinishes() {
        var typed: [String] = []
        let out = StreamingOutput(canTypeNow: { true }, type: { typed.append($0) })
        out.utteranceFinished("First part")
        out.utteranceFinished(". Second part")
        XCTAssertEqual(typed, ["First part", ". Second part"])
        out.finish(fullText: "First part. Second part. Third still in progress")
        XCTAssertEqual(typed.last, ". Third still in progress", "only the untyped tail is added at the end")
        XCTAssertEqual(typed.joined(), "First part. Second part. Third still in progress")
    }

    func testHoldsTextWhileModifierHotkeyIsHeld() {
        var typed: [String] = []
        var safe = false
        let out = StreamingOutput(canTypeNow: { safe }, type: { typed.append($0) })
        out.utteranceFinished("Held back")
        XCTAssertEqual(typed, [])
        out.utteranceFinished(". Also held")
        safe = true
        out.flush()
        XCTAssertEqual(typed, ["Held back. Also held"])
    }

    func testFinishTypesHeldTextEvenIfNotYetSafe() {
        var typed: [String] = []
        let out = StreamingOutput(canTypeNow: { false }, type: { typed.append($0) })
        out.utteranceFinished("One")
        out.finish(fullText: "One. Two")
        XCTAssertEqual(typed, ["One. Two"])
    }

    func testFinishWithNothingNewTypesNothing() {
        var typed: [String] = []
        let out = StreamingOutput(canTypeNow: { true }, type: { typed.append($0) })
        out.utteranceFinished("All done")
        out.finish(fullText: "All done")
        XCTAssertEqual(typed, ["All done"])
    }

    func testAccumulatorChunksStreamToExactlyTheFinalText() {
        var acc = TranscriptAccumulator()
        var typed = ""
        let out = StreamingOutput(canTypeNow: { true }, type: { typed += $0 })
        for (text, ended) in [("Hello", false), ("Hello there", true), ("General", false),
                              ("General Kenobi", true), ("you are", false)] {
            if let chunk = acc.update(text, utteranceEnded: ended) { out.utteranceFinished(chunk) }
        }
        out.finish(fullText: acc.text)
        XCTAssertEqual(typed, acc.text)
        XCTAssertEqual(typed, "Hello there. General Kenobi you are")
    }
}

final class TextInjectorTypingTests: XCTestCase {
    func testTypeUsesKeystrokesNotClipboard() {
        let pasteboard = makePasteboard(self)
        pasteboard.clearContents()
        pasteboard.setString("clipboard untouched", forType: .string)
        let injector = TextInjector()
        injector.pasteboard = pasteboard
        injector.canPaste = { true }
        var typed: [String] = []
        injector.typeText = { typed.append($0) }
        injector.paste = { XCTFail("streaming must not paste") }
        injector.type("Hello, 世界 👋")
        XCTAssertEqual(typed, ["Hello, 世界 👋"])
        XCTAssertEqual(pasteboard.string(forType: .string), "clipboard untouched")
    }

    func testTypeNeedsAccessibility() {
        let injector = TextInjector()
        injector.canPaste = { false }
        injector.typeText = { _ in XCTFail("should not type without Accessibility") }
        injector.type("x")
    }
}
