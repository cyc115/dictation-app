import XCTest
@testable import DictationKit

final class TimeBreakdownTests: XCTestCase {
    private func entry(_ duration: TimeInterval, _ transcribe: Double?, _ polish: Double? = nil, text: String = "t") -> HistoryEntry {
        HistoryEntry(date: Date(), text: text, duration: duration, transcribeSeconds: transcribe, polishSeconds: polish)
    }

    func testMediansOfEachPartIgnoringTapsAndUntimedDictations() throws {
        let entries = [entry(10, 1, 0.2), entry(20, 2, 0.4), entry(300, 30, 9), entry(14, 1.5, nil), entry(12, 1.2, 0.3),
                       entry(0.4, 9, 9), entry(50, nil)]
        let b = try XCTUnwrap(TimeBreakdown(entries))
        XCTAssertEqual(b.count, 5, "a 0.4 s tap and an untimed dictation don't count")
        XCTAssertEqual(b.speaking, 14, "a 5-minute dictation doesn't drag it up")
        XCTAssertEqual(b.transcribing, 1.5)
        XCTAssertEqual(b.polishing, 0.35, "median of the four polished ones")
        XCTAssertEqual(b.total, 15.85, accuracy: 1e-9)
    }

    func testNeedsAFewDictationsAndNoPolishWhenNoneWasPolished() {
        XCTAssertNil(TimeBreakdown(Array(repeating: entry(10, 1), count: 4)))
        XCTAssertNil(TimeBreakdown(Array(repeating: entry(10, 1), count: 5))?.polishing)
    }

    func testOnlyTheMostRecentCount() throws {
        let recent = Array(repeating: entry(10, 1), count: 100)
        let old = Array(repeating: entry(99, 9), count: 50)
        XCTAssertEqual(try XCTUnwrap(TimeBreakdown(recent + old)).speaking, 10, "History is newest first")
    }

    func testNumbers() {
        XCTAssertEqual(TimeBreakdownView.number(15.84), "15.8")
        XCTAssertEqual(TimeBreakdownView.number(0.31), "0.3")
        XCTAssertEqual(TimeBreakdownView.number(65), "1:05")
    }
}
