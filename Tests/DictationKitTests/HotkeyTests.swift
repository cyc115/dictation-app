import CoreGraphics
import XCTest
@testable import DictationKit

final class HotkeyTests: XCTestCase {
    private var events: [String] = []

    private func makeManager(_ key: Hotkey = .fn, _ mode: ActivationMode = .hold,
                             mouse: MouseButton = .off) -> HotkeyManager {
        HotkeyManager(hotkey: key, mode: mode, mouseButton: mouse,
                      onPress: { [unowned self] in events.append("press") },
                      onRelease: { [unowned self] in events.append("release") },
                      onCancel: { [unowned self] in events.append("cancel") },
                      onTap: { [unowned self] in events.append("tap") })
    }

    private func down(_ m: HotkeyManager, _ key: Hotkey) { m.handleFlags(keyCode: key.keyCode, rawFlags: key.flagMask) }
    private func up(_ m: HotkeyManager, _ key: Hotkey) { m.handleFlags(keyCode: key.keyCode, rawFlags: 0) }

    func testHoldPressAndRelease() {
        let m = makeManager()
        down(m, .fn); up(m, .fn)
        XCTAssertEqual(events, ["press", "release"])
    }

    func testRepeatedFlagEventsWhileHeldFireOnce() {
        let m = makeManager()
        down(m, .fn); down(m, .fn); up(m, .fn); up(m, .fn)
        XCTAssertEqual(events, ["press", "release"])
    }

    func testOtherKeyWhileHeldCancelsInsteadOfPasting() {
        let m = makeManager(.rightCommand)
        down(m, .rightCommand); m.otherKeyPressed(); m.otherKeyPressed(); up(m, .rightCommand)
        XCTAssertEqual(events, ["press", "cancel"])
    }

    func testOtherKeyWhenNotHeldIsIgnored() {
        let m = makeManager()
        m.otherKeyPressed()
        XCTAssertEqual(events, [])
    }

    func testIgnoresOtherModifierKeys() {
        let m = makeManager(.rightOption)
        down(m, .rightCommand); up(m, .rightCommand)
        // Left option: same .option flag but a different key code and no right-side device bit.
        m.handleFlags(keyCode: 58, rawFlags: NSEventModifierOption | 0x20)
        XCTAssertEqual(events, [])
    }

    func testRightModifierDetectedByDeviceBit() {
        let m = makeManager(.rightOption)
        // Right option down while left option is also held: device bit 0x40 is set.
        m.handleFlags(keyCode: 61, rawFlags: NSEventModifierOption | 0x20 | 0x40)
        m.handleFlags(keyCode: 61, rawFlags: NSEventModifierOption | 0x20)
        XCTAssertEqual(events, ["press", "release"])
    }

    func testToggleModeTapsOnRelease() {
        let m = makeManager(.rightShift, .toggle)
        down(m, .rightShift)
        XCTAssertEqual(events, [], "toggle mode acts on release, not press")
        up(m, .rightShift)
        down(m, .rightShift); up(m, .rightShift)
        XCTAssertEqual(events, ["tap", "tap"])
    }

    func testToggleModeComboIsNotATap() {
        let m = makeManager(.rightCommand, .toggle)
        down(m, .rightCommand); m.otherKeyPressed(); up(m, .rightCommand)
        XCTAssertEqual(events, [])
    }

    func testChangingHotkeyResetsHeldState() {
        let m = makeManager(.fn)
        down(m, .fn)
        m.hotkey = .rightShift
        up(m, .fn)
        down(m, .rightShift); up(m, .rightShift)
        XCTAssertEqual(events, ["press", "press", "release"])
    }

    // MARK: Mouse

    /// Returns whether the event was passed through (true) or swallowed (false).
    /// The event is kept alive across the call: the tap returns it unretained.
    private func passes(_ m: HotkeyManager, _ type: CGEventType, button: Int64) -> Bool {
        let event = mouseEvent(type, button: button)
        return withExtendedLifetime(event) { m.handleMouse(type: type, event: event) != nil }
    }

    private func mouseEvent(_ type: CGEventType, button: Int64) -> CGEvent {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .center)!
        event.setIntegerValueField(.mouseEventButtonNumber, value: button)
        return event
    }

    func testAssignedMouseButtonIsSwallowedAndToggles() {
        let m = makeManager(mouse: .button4)
        XCTAssertFalse(passes(m, .otherMouseDown, button: 3))
        XCTAssertFalse(passes(m, .otherMouseUp, button: 3))
        spinRunLoop()
        XCTAssertEqual(events, ["tap"], "down toggles once; up is swallowed silently")
    }

    func testOtherMouseButtonsPassThrough() {
        let m = makeManager(mouse: .button4)
        XCTAssertTrue(passes(m, .otherMouseDown, button: 4))
        XCTAssertTrue(passes(m, .otherMouseDown, button: 2))
        spinRunLoop()
        XCTAssertEqual(events, [])
    }

    func testMouseOffPassesEverythingThrough() {
        let m = makeManager(mouse: .off)
        XCTAssertTrue(passes(m, .otherMouseDown, button: 3))
        spinRunLoop()
        XCTAssertEqual(events, [])
    }

    // MARK: Esc

    private func escapePasses(_ m: HotkeyManager) -> Bool {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)!
        return withExtendedLifetime(event) { m.handleMouse(type: .keyDown, event: event) != nil }
    }

    func testEscapeCancelsAndIsSwallowedWhileRecording() {
        let m = makeManager(.rightShift, .toggle)
        m.isRecording = { true }
        m.onEscape = { [unowned self] in events.append("escape") }
        XCTAssertFalse(escapePasses(m))
        spinRunLoop()
        XCTAssertEqual(events, ["escape"])
    }

    func testEscapePassesThroughWhenNotRecording() {
        let m = makeManager()
        m.isRecording = { false }
        m.onEscape = { [unowned self] in events.append("escape") }
        XCTAssertTrue(escapePasses(m))
        spinRunLoop()
        XCTAssertEqual(events, [])
    }

    func testOtherKeysPassThroughWhileRecording() {
        let m = makeManager()
        m.isRecording = { true }
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 0x00, keyDown: true)!  // "a"
        XCTAssertTrue(withExtendedLifetime(event) { m.handleMouse(type: .keyDown, event: event) != nil })
    }

    func testEscapeWhileHoldingHotkeyDoesNotPasteOnRelease() {
        let m = makeManager(.fn, .hold)
        m.isRecording = { true }
        m.onEscape = { [unowned self] in events.append("escape") }
        down(m, .fn)
        _ = escapePasses(m)
        up(m, .fn)
        spinRunLoop()
        XCTAssertEqual(events, ["press", "escape"])
    }

    // MARK: Paused in an excluded app

    func testPausedHotkeyDoesNotStartDictation() {
        let m = makeManager(.rightShift, .toggle)
        m.isPaused = { true }
        down(m, .rightShift); up(m, .rightShift)
        XCTAssertEqual(events, [])
    }

    func testReleaseStillCountsAfterSwitchingIntoAnExcludedApp() {
        var paused = false
        let m = makeManager(.fn, .hold)
        m.isPaused = { paused }
        down(m, .fn)
        paused = true
        up(m, .fn)
        paused = false
        down(m, .fn); up(m, .fn)
        XCTAssertEqual(events, ["press", "release", "press", "release"], "the key isn't left stuck down")
    }

    func testPausedMouseButtonAndEscPassThrough() {
        let m = makeManager(mouse: .button4)
        m.isPaused = { true }
        m.isRecording = { true }
        m.onEscape = { [unowned self] in events.append("escape") }
        XCTAssertTrue(passes(m, .otherMouseDown, button: 3), "the game gets its own button")
        XCTAssertTrue(passes(m, .otherMouseUp, button: 3))
        XCTAssertTrue(escapePasses(m))
        spinRunLoop()
        XCTAssertEqual(events, [])
    }

    func testMouseButtonNumbers() {
        XCTAssertNil(MouseButton.off.buttonNumber)
        XCTAssertEqual(MouseButton.middle.buttonNumber, 2)
        XCTAssertEqual(MouseButton.button4.buttonNumber, 3)
        XCTAssertEqual(MouseButton.button5.buttonNumber, 4)
    }
}

private let NSEventModifierOption: UInt = 1 << 19
