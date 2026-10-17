import XCTest
@testable import DictationKit

/// What the pill animates when several things happen at once, without a window.
final class PillStateTests: XCTestCase {
    func testWarmUpEndsInAGreenFlashThenPlain() {
        var state = PillState.listening(warmingUp: true, at: 0)
        XCTAssertEqual(state.look(at: 0.5, reduceMotion: false), .waiting(elapsed: 0.5, reduceMotion: false))
        state.micLive(at: 1)
        XCTAssertFalse(state.isWarmingUp)
        XCTAssertEqual(state.look(at: 1.125, reduceMotion: false), .ready(since: 0.125, reduceMotion: false))
        XCTAssertEqual(state.look(at: 2, reduceMotion: false), .plain)
        XCTAssertFalse(state.isAnimating, "the finished flash is dropped")
    }

    func testRedShowsOverTheWarmUpDots() {
        var state = PillState.listening(warmingUp: true, at: 0)
        state.micSilent(at: 3)
        let look = state.look(at: 3 + PillLook.silentFadeIn, reduceMotion: false)
        XCTAssertEqual(look.aura, .red)
        XCTAssertEqual(look.glow, 1)
        XCTAssertEqual(look.levels, Array(repeating: 0, count: PillLook.barCount), "still the dots")
    }

    func testRedStartsOnceAndStaysUntilLive() {
        var state = PillState.listening(warmingUp: false, at: 0)
        state.micSilent(at: 3)
        state.micSilent(at: 5)  // reported again: the fade doesn't restart
        XCTAssertEqual(state.look(at: 3 + PillLook.silentFadeIn, reduceMotion: false).glow, 1)
        XCTAssertTrue(state.isAnimating)
        state.micLive(at: 9)
        XCTAssertEqual(state.look(at: 9, reduceMotion: false), .plain, "a mic that wasn't warming up doesn't flash")
        XCTAssertFalse(state.isAnimating)
    }

    func testASwitchFlashesYellowOverRedAndEndsTheWait() {
        var state = PillState.listening(warmingUp: true, at: 0)
        state.micSilent(at: 3)
        state.micSwitched(at: 4)
        XCTAssertFalse(state.isWarmingUp)
        XCTAssertFalse(state.isShowingNoAudio)
        XCTAssertEqual(state.look(at: 4.125, reduceMotion: false).aura, .yellow)
        XCTAssertEqual(state.look(at: 5, reduceMotion: false), .plain)
    }

    func testNarrowingReplacesEverything() {
        let state = PillState.narrowing(at: 10)
        var copy = state
        XCTAssertEqual(copy.look(at: 10.25, reduceMotion: false), .narrowing(since: 0.25))
        XCTAssertFalse(state.isNarrowed(at: 10.3))
        XCTAssertTrue(state.isNarrowed(at: 10.5))
    }
}

/// Where the pill's parts go, from its width and content.
final class PillLayoutTests: XCTestCase {
    func testListeningPutsButtonsAtTheEndsAndTheNameUnderTheBars() {
        let layout = PillLayout(width: 200, content: .listening(caption: true))
        XCTAssertEqual(layout.cancel.minX, PillLayout.pad)
        XCTAssertEqual(layout.confirm.maxX, 200 - PillLayout.pad)
        XCTAssertEqual(layout.waveform.minX, PillLayout.sideInset)
        XCTAssertEqual(layout.waveform.midX, 100, "centered")
        XCTAssertLessThanOrEqual(layout.caption.maxY, layout.waveform.minY)
        XCTAssertEqual(PillLayout(width: 200, content: .listening(caption: false)).waveform.midY, PillLayout.height / 2,
                       "without a name the bars are centered")
    }

    func testWidths() {
        XCTAssertEqual(PillLayout.listeningWidth(caption: 0), PillLayout.listeningWidth)
        XCTAssertEqual(PillLayout.listeningWidth(caption: 120), 120 + 6 + 2 * PillLayout.sideInset)
        XCTAssertEqual(PillLayout.listeningWidth(caption: 1000), PillLayout.maxListeningWidth)
        XCTAssertEqual(PillLayout.messageWidth(text: 1000), PillLayout.maxMessageWidth)
    }

    func testInterpolationRunsFromOneLayoutToTheOther() {
        let wide = PillLayout(width: 220, content: .listening(caption: true))
        let narrow = PillLayout(width: PillLayout.processingWidth, content: .processing)
        XCTAssertEqual(wide.interpolated(to: narrow, 0), wide)
        XCTAssertEqual(wide.interpolated(to: narrow, 1), narrow)
        let half = wide.interpolated(to: narrow, 0.5)
        XCTAssertEqual(half.width, (220 + PillLayout.processingWidth) / 2)
        XCTAssertEqual(half.waveform.midX, half.width / 2, accuracy: 0.001, "the bars stay centered")
    }
}
