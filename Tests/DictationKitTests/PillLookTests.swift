import XCTest
@testable import DictationKit

/// The warm-up and ready looks, frame by frame (the mockup they follow: a sweep over dots, then a
/// green flash, bounce and ripple).
final class PillLookTests: XCTestCase {
    func testWaitingIsDotsWithASweepMovingRight() {
        let early = PillLook.waiting(elapsed: 0.3, reduceMotion: false)
        let later = PillLook.waiting(elapsed: 0.6, reduceMotion: false)
        XCTAssertEqual(early.levels, Array(repeating: 0, count: PillLook.barCount), "flat dots")
        XCTAssertEqual(early.confirmEmphasis, 0.3)
        let brightest = { (look: PillLook) in look.barAlphas.indices.max { look.barAlphas[$0] < look.barAlphas[$1] }! }
        XCTAssertGreaterThan(brightest(later), brightest(early))
        XCTAssertTrue(early.barAlphas.allSatisfy { $0 >= 0.24 && $0 <= 0.8 })
        let again = PillLook.waiting(elapsed: 0.3 + PillLook.sweepPeriod, reduceMotion: false)
        for (a, b) in zip(again.barAlphas, early.barAlphas) { XCTAssertEqual(a, b, accuracy: 1e-9, "repeats") }
    }

    func testReduceMotionHoldsStill() {
        let a = PillLook.waiting(elapsed: 0.1, reduceMotion: true), b = PillLook.waiting(elapsed: 0.7, reduceMotion: true)
        XCTAssertEqual(a, b)
        XCTAssertEqual(PillLook.ready(since: 0.13, reduceMotion: true).scale, 1, "no bounce")
        XCTAssertGreaterThan(PillLook.ready(since: 0.13, reduceMotion: true).glow, 0, "the flash still shows")
    }

    func testReadyFlashesBouncesRipplesThenSettles() throws {
        let start = PillLook.ready(since: 0, reduceMotion: false)
        XCTAssertEqual(start.glow, 1)
        XCTAssertEqual(start.captionAlpha, 0, "the mic's name fades in")
        let mid = PillLook.ready(since: 0.13, reduceMotion: false)
        XCTAssertGreaterThan(mid.scale, 1.04)
        let levels = try XCTUnwrap(PillLook.ready(since: 0.1, reduceMotion: false).levels)
        XCTAssertGreaterThan(levels[6], levels[0], "ripple starts at the center")
        let after = PillLook.ready(since: PillLook.rippleDuration, reduceMotion: false)
        XCTAssertNil(after.levels, "bars follow the mic after the ripple")
        XCTAssertEqual(after.confirmEmphasis, 1)
        XCTAssertEqual(after.scale, 1)
        XCTAssertFalse(PillLook.settled(since: 0.6))
        XCTAssertTrue(PillLook.settled(since: PillLook.glowDuration))
        XCTAssertEqual(PillLook.ready(since: PillLook.glowDuration, reduceMotion: false), .plain)
    }
}
