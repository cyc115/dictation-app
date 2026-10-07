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
