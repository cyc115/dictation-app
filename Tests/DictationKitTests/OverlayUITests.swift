import AppKit
import SwiftUI
import XCTest
@testable import DictationKit

final class OverlayUITests: XCTestCase {
    func testListeningPillAtBottomCenterWithButtons() throws {
        let overlay = OverlayWindow()
        var confirmed = 0, cancelled = 0
        overlay.onConfirm = { confirmed += 1 }
        overlay.onCancel = { cancelled += 1 }
        addTeardownBlock { overlay.hide() }

        overlay.showListening()
        spinRunLoop(0.2)
        let panel = try XCTUnwrap(overlay.panel)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(overlay.mode, .listening)
        XCTAssertEqual(overlay.pillFrame.height, PillLayout.height)
        XCTAssertEqual(overlay.pillFrame.width, PillLayout.listeningWidth)
        let screen = try XCTUnwrap(panel.screen ?? NSScreen.main)
        XCTAssertEqual(overlay.pillFrame.midX, screen.visibleFrame.midX, accuracy: 1, "centered")
        XCTAssertLessThan(overlay.pillFrame.minY - screen.visibleFrame.minY, 60, "near the bottom")
        XCTAssertFalse(panel.canBecomeKey, "must not steal focus from the app being typed into")

        let buttons = (panel.contentView?.subviews.first?.subviews ?? []).filter { $0.accessibilityRole() == .button }
        let confirm = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier() == "overlay.checkmark" })
        let cancel = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier() == "overlay.xmark" })
        XCTAssertTrue(confirm.accessibilityPerformPress())
        XCTAssertTrue(cancel.accessibilityPerformPress())
        XCTAssertEqual(confirmed, 1)
        XCTAssertEqual(cancelled, 1)
    }

    func testWaveformFollowsLevelOnlyWhileListening() {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        overlay.showListening()
        XCTAssertEqual(overlay.waveform.levels.max(), 0)
        overlay.setLevel(0.9)
        let afterSpeech = overlay.waveform.levels
        XCTAssertGreaterThan(afterSpeech.last ?? 0, 0.5)
        overlay.showMessage("Error")
        overlay.setLevel(0.5)
        XCTAssertEqual(overlay.waveform.levels, afterSpeech, "ignored outside listening")
    }

    func testMessageModeWidensAndHidesButtons() throws {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        overlay.showMessage("On-device recognition unavailable — check Dictation languages", hideAfter: 10)
        XCTAssertNotNil(overlay.panel)
        XCTAssertEqual(overlay.mode, .message)
        XCTAssertGreaterThan(overlay.pillFrame.width, PillLayout.listeningWidth)
        XCTAssertLessThanOrEqual(overlay.pillFrame.width, 460)
        overlay.hideUnlessMessage()
        XCTAssertEqual(overlay.mode, .message, "messages survive hideUnlessMessage")
    }

    func testMicNameShownUnderWaveform() throws {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        overlay.showListening(micName: "MacBook Pro Microphone")
        XCTAssertFalse(overlay.micLabel.isHidden)
        XCTAssertTrue(overlay.micLabel.stringValue.hasSuffix("MacBook Pro Microphone"), overlay.micLabel.stringValue)
        XCTAssertLessThan(overlay.micLabel.frame.maxY, overlay.waveform.frame.minY + 1, "caption sits below the bars")
        XCTAssertEqual(overlay.pillFrame.height, PillLayout.height, "caption doesn't grow the pill")

        overlay.showListening(micName: nil)
        XCTAssertTrue(overlay.micLabel.isHidden)
        overlay.showListening(micName: "Studio Display Microphone")
        overlay.showMessage("Error", hideAfter: 10)
        XCTAssertTrue(overlay.micLabel.isHidden, "only shown while listening")
    }

    /// A Bluetooth mic: the pill says it's starting, with ✓ dimmed, until the first real audio.
    func testSlowMicShowsStartingUntilLive() throws {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        var clock: TimeInterval = 100
        overlay.now = { clock }
        overlay.reduceMotion = { false }
        overlay.showListening(micName: "Mike’s Pixel Buds Pro", warmingUp: true)
        XCTAssertTrue(overlay.isWarmingUp)
        XCTAssertEqual(overlay.micLabel.stringValue.hasSuffix("Starting Mike’s Pixel Buds Pro…"), true, overlay.micLabel.stringValue)
        XCTAssertEqual(overlay.micLabel.accessibilityLabel(), "Microphone starting: Mike’s Pixel Buds Pro")
        XCTAssertEqual(overlay.confirmButton.emphasis, 0.3, accuracy: 0.001)
        let width = overlay.pillFrame.width

        clock += 0.9
        overlay.micLive()
        XCTAssertFalse(overlay.isWarmingUp)
        XCTAssertTrue(overlay.micLabel.stringValue.hasSuffix("Mike’s Pixel Buds Pro"))
        XCTAssertFalse(overlay.micLabel.stringValue.contains("Starting"))
        XCTAssertEqual(overlay.pillFrame.width, width, "one width from start to live")
        clock += 0.1
        overlay.tick()
        XCTAssertLessThan(overlay.confirmButton.emphasis, 1, "✓ still brightening")
        XCTAssertEqual(overlay.panel?.hasShadow, false, "the green glow stands in for the shadow")

        clock += PillLook.glowDuration
        overlay.tick()
        XCTAssertEqual(overlay.confirmButton.emphasis, 1)
        XCTAssertEqual(overlay.micLabel.alphaValue, 1)
        XCTAssertEqual(overlay.panel?.hasShadow, true, "plain listening pill again")
        overlay.setLevel(0.9)
        XCTAssertGreaterThan(overlay.waveform.levels.last ?? 0, 0.5, "bars follow the mic")
    }

    /// Stop: the listening pill narrows into the processing one instead of jumping to it.
    func testStopNarrowsIntoTheProcessingPill() throws {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        var clock: TimeInterval = 0
        overlay.now = { clock }
        overlay.showListening(micName: "MacBook Pro Microphone")
        for level in [0.4, 0.8, 0.6] as [Float] { overlay.setLevel(level) }
        let wide = overlay.pillFrame
        overlay.showProcessing()
        XCTAssertEqual(overlay.mode, .processing)
        XCTAssertTrue(overlay.isNarrowing)

        clock = 0.23
        overlay.tick()
        let pill = try XCTUnwrap(overlay.panel?.contentView?.subviews.first)
        XCTAssertLessThan(pill.frame.width, wide.width)
        XCTAssertGreaterThan(pill.frame.width, PillLayout.processingWidth)
        XCTAssertEqual(pill.frame.midX, overlay.panel!.contentView!.bounds.midX, accuracy: 0.5, "narrows toward its center")
        XCTAssertEqual(overlay.confirmButton.alphaValue, 0, accuracy: 0.01)

        clock = PillLook.narrowDuration
        overlay.tick()
        XCTAssertFalse(overlay.isNarrowing)
        XCTAssertEqual(overlay.pillFrame.width, PillLayout.processingWidth)
        XCTAssertEqual(overlay.pillFrame.midX, wide.midX, accuracy: 1, "ends where it narrowed to")
        XCTAssertTrue(overlay.confirmButton.isHidden)
    }

    /// Cloud Flash's text (~0.5 s) can land while the pill is still narrowing (0.4 s), and polish
    /// then asks for the processing pill again: the narrowing carries on instead of jumping to its end.
    func testProcessingAgainDoesntCutTheNarrowingShort() {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        var clock: TimeInterval = 0
        overlay.now = { clock }
        overlay.showListening(micName: "MacBook Pro Microphone")
        overlay.showProcessing()
        clock = 0.2
        overlay.tick()
        overlay.showProcessing()
        XCTAssertTrue(overlay.isNarrowing)
    }

    /// The window keeps its size when the narrowing ends: resizing it then could show the pill a
    /// frame out of place, a flash.
    func testNarrowingEndsWithoutResizingTheWindow() throws {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        var clock: TimeInterval = 0
        overlay.now = { clock }
        overlay.showListening(micName: "MacBook Pro Microphone")
        let window = try XCTUnwrap(overlay.panel?.frame)
        let center = overlay.pillFrame.midX
        overlay.showProcessing()
        clock = 1
        overlay.tick()
        XCTAssertFalse(overlay.isNarrowing)
        XCTAssertEqual(overlay.panel?.frame, window)
        XCTAssertEqual(overlay.pillFrame.width, PillLayout.processingWidth)
        XCTAssertEqual(overlay.pillFrame.midX, center, accuracy: 0.5)
        overlay.showProcessing()  // polish next: still the same pill, same window
        XCTAssertEqual(overlay.panel?.frame, window)
    }

    func testProcessingFromHiddenAppearsAtOnce() {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        overlay.showProcessing()
        XCTAssertFalse(overlay.isNarrowing)
        XCTAssertEqual(overlay.pillFrame.width, PillLayout.processingWidth)
    }

    func testMessageDuringNarrowingWins() {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        overlay.showListening(micName: "MacBook Pro Microphone")
        overlay.showProcessing()
        overlay.showMessage("Couldn't reach the cloud model", hideAfter: 10)
        XCTAssertFalse(overlay.isNarrowing)
        XCTAssertEqual(overlay.mode, .message)
        XCTAssertFalse(overlay.label.isHidden)
    }

    func testFastMicSkipsTheWait() {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        overlay.showListening(micName: "MacBook Pro Microphone")
        XCTAssertFalse(overlay.isWarmingUp)
        overlay.micLive()  // every mic reports live; only a waiting pill reacts
        XCTAssertEqual(overlay.panel?.hasShadow, true)
        XCTAssertEqual(overlay.confirmButton.emphasis, 1)
    }

    /// Intelligent mic selection moved to a better mic: its name, a yellow flash, the wait over.
    func testSwitchedMicFlashesYellowWithItsName() throws {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        var clock: TimeInterval = 0
        overlay.now = { clock }
        overlay.showListening(micName: "Mike’s Pixel Buds Pro", warmingUp: true)
        overlay.micSilent()
        clock = 1.2
        overlay.micSwitched(to: "Logitech BRIO")
        XCTAssertFalse(overlay.isWarmingUp)
        XCTAssertFalse(overlay.isShowingNoAudio, "the switch ends the red glow")
        XCTAssertTrue(overlay.micLabel.stringValue.hasSuffix("Logitech BRIO"), overlay.micLabel.stringValue)
        let pill = try XCTUnwrap(overlay.panel?.contentView?.subviews.first)
        clock = 1.3
        overlay.tick()
        let yellow = try XCTUnwrap(pill.shadow?.shadowColor?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(yellow.redComponent, 0.9)
        XCTAssertGreaterThan(yellow.greenComponent, 0.7)
        XCTAssertLessThan(yellow.blueComponent, 0.1)
        clock = 1.2 + PillLook.glowDuration
        overlay.tick()
        XCTAssertNil(pill.shadow, "then the plain pill")
    }

    /// No audio 3 s in: a red glow fades in, and stays until audio arrives.
    func testNoAudioGlowsRedUntilLive() throws {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        var clock: TimeInterval = 0
        overlay.now = { clock }
        overlay.showListening(micName: "USB Mic")
        overlay.micSilent()
        let pill = try XCTUnwrap(overlay.panel?.contentView?.subviews.first)
        clock = 0.3
        overlay.tick()
        let early = try XCTUnwrap(pill.shadow?.shadowColor?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(early.redComponent, 0.9)
        XCTAssertLessThan(early.greenComponent, 0.3)
        clock = 10
        overlay.tick()
        let late = try XCTUnwrap(pill.shadow?.shadowColor)
        XCTAssertGreaterThan(late.alphaComponent, early.alphaComponent, "fades in")
        XCTAssertEqual(overlay.panel?.hasShadow, false)
        overlay.micLive()
        XCTAssertFalse(overlay.isShowingNoAudio)
        XCTAssertNil(pill.shadow)
        XCTAssertEqual(overlay.panel?.hasShadow, true)
    }

    func testOtherModesEndTheWait() {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        overlay.showListening(micName: "Mike’s Pixel Buds Pro", warmingUp: true)
        overlay.showMessage("The microphone sent only silence.", hideAfter: 10)
        XCTAssertFalse(overlay.isWarmingUp)
        XCTAssertEqual(overlay.confirmButton.emphasis, 1)
        overlay.showListening(micName: "Mike’s Pixel Buds Pro", warmingUp: true)
        overlay.hide()
        XCTAssertFalse(overlay.isWarmingUp)
    }

    func testFullMicNameFitsWithoutTruncation() throws {
        let overlay = OverlayWindow()
        addTeardownBlock { overlay.hide() }
        for name in ["MacBook Pro Microphone", "iPhone (53) Microphone", "HD Pro Webcam C920", "Steam Streaming Microphone"] {
            overlay.showListening(micName: name)
            let needed = overlay.micLabel.attributedStringValue.size().width
            XCTAssertTrue(overlay.micLabel.stringValue.hasSuffix(name), "full name shown: \(overlay.micLabel.stringValue)")
            XCTAssertGreaterThanOrEqual(overlay.micLabel.frame.width, needed, "\(name) is truncated")
            XCTAssertEqual(overlay.pillFrame.width, overlay.micLabel.frame.maxX + overlay.micLabel.frame.minX, accuracy: 1,
                           "caption is centered in the pill")
        }
        overlay.showListening(micName: "Mic")
        XCTAssertEqual(overlay.pillFrame.width, PillLayout.listeningWidth, "short names keep the compact pill")
        overlay.showListening(micName: String(repeating: "Very Long Device Name ", count: 6))
        XCTAssertEqual(overlay.pillFrame.width, PillLayout.maxListeningWidth, "absurd names are capped")
    }

    func testHideFadesOut() throws {
        let overlay = OverlayWindow()
        overlay.showListening()
        overlay.hide()
        XCTAssertEqual(overlay.mode, .hidden)
        spinRunLoop(0.4)
        XCTAssertFalse(try XCTUnwrap(overlay.panel).isVisible)
    }

    func testMessageAutoHides() {
        let overlay = OverlayWindow()
        overlay.showMessage("Polishing failed", hideAfter: 0.1)
        spinRunLoop(0.5)
        XCTAssertEqual(overlay.mode, .hidden)
    }
}
