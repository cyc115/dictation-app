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

    func testSwitchFlashIsTheReadyFlashInYellow() {
        var yellow = PillLook.ready(since: 0.1, reduceMotion: false, aura: .yellow)
        XCTAssertEqual(yellow.aura, .yellow)
        yellow.aura = .green
        XCTAssertEqual(yellow, PillLook.ready(since: 0.1, reduceMotion: false), "same animation, other color")
    }

    func testNoAudioGlowFadesInThenStays() {
        XCTAssertEqual(PillLook.silentGlow(since: 0), 0)
        XCTAssertLessThan(PillLook.silentGlow(since: 0.3), 0.2, "gradual")
        XCTAssertEqual(PillLook.silentGlow(since: PillLook.silentFadeIn), 1)
        XCTAssertEqual(PillLook.silentGlow(since: 60), 1)
    }

    func testNarrowingFadesTheControlsThenNarrows() {
        let start = PillLook.narrowing(since: 0)
        XCTAssertEqual(start.narrowing, 0)
        XCTAssertEqual(start.controlsAlpha, 1)
        let early = PillLook.narrowing(since: 0.1)
        XCTAssertLessThan(early.controlsAlpha, 0.5, "✕/✓ mostly gone…")
        XCTAssertLessThan(early.narrowing, 0.1, "…before the pill has narrowed much")
        let mid = PillLook.narrowing(since: 0.23)
        XCTAssertEqual(mid.narrowing, 0.5, accuracy: 0.01)
        XCTAssertEqual(mid.controlsAlpha, 0)
        XCTAssertEqual(PillLook.narrowing(since: PillLook.narrowDuration).narrowing, 1)
        XCTAssertFalse(PillLook.narrowed(since: 0.3))
        XCTAssertTrue(PillLook.narrowed(since: PillLook.narrowDuration))
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

    func testTheEdgeBlendsFromRestIntoTheAura() {
        var look = PillLook.plain
        look.glow = 0
        look.aura = .green
        XCTAssertEqual(look.edge(command: false).width, 0.5)
        XCTAssertEqual(look.edge(command: false).color, PillLook.RGBA(255, 255, 255, alpha: 0.14), "white at 14%")
        XCTAssertEqual(look.edge(command: true).width, 1.2)
        XCTAssertEqual(look.edge(command: true).color, PillLook.RGBA(127, 160, 255, alpha: 0.8), "command mode's blue")
        look.glow = 1
        XCTAssertEqual(look.edge(command: false).width, 1.6)
        XCTAssertEqual(look.edge(command: false).color, PillLook.color(.green, alpha: 0.9))
        XCTAssertEqual(look.edge(command: true).color, PillLook.color(.green, alpha: 0.9), "the aura wins over the rest")
        look.glow = 0.5
        look.aura = .red
        let half = look.edge(command: false).color
        XCTAssertEqual(half.red, 1, accuracy: 0.0001)
        XCTAssertEqual(half.green, (255 + (59 - 255) * 0.5) / 255, accuracy: 0.0001)
        XCTAssertEqual(half.alpha, 0.52, accuracy: 0.0001)
    }
}
