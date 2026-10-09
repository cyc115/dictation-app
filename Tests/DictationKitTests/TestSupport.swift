import AppKit
import SwiftUI
import XCTest
@testable import DictationKit

/// A throwaway UserDefaults suite, removed when the test ends.
func makeDefaults(_ test: XCTestCase) -> UserDefaults {
    let name = "DictationAppTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    test.addTeardownBlock { defaults.removePersistentDomain(forName: name) }
    return defaults
}

/// A throwaway file location, removed when the test ends.
func makeTempURL(_ test: XCTestCase, _ name: String = "history.json") -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DictationAppTests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir.appendingPathComponent(name)
}

/// A private pasteboard so tests never touch the user's clipboard.
func makePasteboard(_ test: XCTestCase) -> NSPasteboard {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("DictationAppTests.\(UUID().uuidString)"))
    test.addTeardownBlock { pasteboard.releaseGlobally() }
    return pasteboard
}

/// Fixed local date, so rendered text is stable.
func fixedDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

/// Runs the main run loop briefly so SwiftUI / AppKit can lay out and animate.
func spinRunLoop(_ seconds: TimeInterval = 0.05) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

// MARK: - Hosting SwiftUI views for UI tests

/// Puts a SwiftUI view in a real (offscreen) window so it lays out and builds its
/// accessibility tree, which tests then query and drive like a user would.
final class HostedView<Content: View> {
    let window: NSWindow
    let hostingView: NSHostingView<Content>

    init(_ view: Content, size: NSSize, appearance: NSAppearance.Name = .aqua) {
        // SwiftUI only builds its accessibility tree once an assistive client asks for it;
        // this is the same switch VoiceOver/automation tools flip.
        NSApplication.shared.accessibilitySetValue(
            true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: size)
        window = OffscreenWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.orderFront(nil)
        settle()
    }

    func settle() {
        for _ in 0..<5 {
            hostingView.layoutSubtreeIfNeeded()
            hostingView.display()  // lists only build rows once drawn
            spinRunLoop(0.03)
        }
    }

    /// Clicks the center of an element with real mouse events, like a user would.
    @discardableResult
    func click(_ node: AXNode) -> Bool {
        guard let frame = node.frame else { return false }
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: 1) else { return false }
            window.sendEvent(event)
        }
        settle()
        return true
    }

    /// Depth-first search of the accessibility tree.
    func elements(where match: (AXNode) -> Bool) -> [AXNode] {
        var found: [AXNode] = []
        var stack: [AXNode] = [AXNode(hostingView)]
        var visited = Set<ObjectIdentifier>()
        while let node = stack.popLast(), visited.count < 5_000 {
            guard visited.insert(ObjectIdentifier(node.object)).inserted else { continue }
            if match(node) { found.append(node) }
            stack.append(contentsOf: node.children.reversed())
        }
        return found
    }

    func element(id: String) -> AXNode? { elements(id: id).first }

    func elements(id: String) -> [AXNode] { elements { $0.identifier == id } }

    /// Text of every node (label + value), for "is this string on screen" checks.
    var allText: String {
        elements { _ in true }.map { "\($0.label ?? "") \($0.value ?? "")" }.joined(separator: "\n")
    }

    func close() { window.close() }
}

/// Stays where it's put (offscreen) instead of being pulled onto a display.
final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// One accessibility element. SwiftUI's nodes are plain Objective-C objects that don't
/// bridge to the Swift NSAccessibilityProtocol type, so attributes are read dynamically.
struct AXNode {
    let object: NSObject
    init(_ object: NSObject) { self.object = object }

    private func attr(_ key: String) -> Any? {
        object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
    }

    var identifier: String? { attr("accessibilityIdentifier") as? String }
    var role: String? { (attr("accessibilityRole") as? NSAccessibility.Role)?.rawValue ?? attr("accessibilityRole") as? String }
    var label: String? { attr("accessibilityLabel") as? String }
    var value: String? { attr("accessibilityValue").map { "\($0)" } }
    var frame: NSRect? { (attr("accessibilityFrame") as? NSValue)?.rectValue }
    var children: [AXNode] {
        var objects = ((attr("accessibilityChildren") as? [Any]) ?? []).compactMap { $0 as? NSObject }
        // List rows host their content in separate views that aren't always linked into the
        // accessibility tree of an offscreen window, so walk real subviews too.
        if let view = object as? NSView {
            objects += view.subviews.filter { sub in !objects.contains { $0 === sub } }
        }
        return objects.map(AXNode.init)
    }

    /// Same as a click from VoiceOver / UI automation.
    @discardableResult
    func press() -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return false }
        _ = object.perform(selector)
        return true
    }
}

// MARK: - Snapshot testing

/// Compares a view's rendering to a reference PNG in __Snapshots__/.
/// Record or re-record with: RECORD_SNAPSHOTS=1 swift test
///
/// Views in on-screen windows (the overlay pill) render at that display's scale, so references are
/// kept per scale: `name.png` at 1×, `name@2x.png` on Retina. Resampling one to the other would
/// blur edges and make the pixel comparison flaky.
func assertSnapshot(of view: NSView, named name: String, tolerance: Double = 0.01,
                    file: StaticString = #filePath, line: UInt = #line) {
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        return XCTFail("could not render \(name)", file: file, line: line)
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        return XCTFail("could not encode \(name)", file: file, line: line)
    }
    let dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().appendingPathComponent("__Snapshots__")
    let scale = view.bounds.width > 0 ? Int((Double(rep.pixelsWide) / Double(view.bounds.width)).rounded()) : 1
    let reference = dir.appendingPathComponent(scale == 1 ? "\(name).png" : "\(name)@\(scale)x.png")
    let record = ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1"
    if record || !FileManager.default.fileExists(atPath: reference.path) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? png.write(to: reference)
        if !record {
            XCTFail("recorded new snapshot \(reference.lastPathComponent) — review it and re-run", file: file, line: line)
        }
        return
    }
    guard let expected = NSBitmapImageRep(data: (try? Data(contentsOf: reference)) ?? Data()) else {
        return XCTFail("unreadable reference \(name).png", file: file, line: line)
    }
    let failures = dir.appendingPathComponent("failures")
    func saveFailure() {
        try? FileManager.default.createDirectory(at: failures, withIntermediateDirectories: true)
        try? png.write(to: failures.appendingPathComponent(reference.lastPathComponent))
    }
    guard expected.pixelsWide == rep.pixelsWide, expected.pixelsHigh == rep.pixelsHigh else {
        saveFailure()
        return XCTFail("\(name): size \(rep.pixelsWide)x\(rep.pixelsHigh) ≠ reference \(expected.pixelsWide)x\(expected.pixelsHigh); actual saved to __Snapshots__/failures/", file: file, line: line)
    }
    var differing = 0
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard let a = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                  let b = expected.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let delta = max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
                            abs(a.blueComponent - b.blueComponent), abs(a.alphaComponent - b.alphaComponent))
            if delta > 0.08 { differing += 1 }
        }
    }
    let fraction = Double(differing) / Double(rep.pixelsWide * rep.pixelsHigh)
    if fraction > tolerance {
        saveFailure()
        XCTFail(String(format: "%@: %.2f%% of pixels differ (limit %.2f%%); actual saved to __Snapshots__/failures/",
                       name, fraction * 100, tolerance * 100), file: file, line: line)
    }
}

// MARK: - Performance budgets

/// Average wall time per iteration must stay under `budget` seconds.
/// XCTest's measure{} has no pass/fail outside Xcode baselines, so budgets are explicit.
func assertFaster(than budget: TimeInterval, iterations: Int = 1, _ label: String,
                  file: StaticString = #filePath, line: UInt = #line, _ block: () -> Void) {
    block()  // warm up
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations { block() }
    let average = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9 / Double(iterations)
    print(String(format: "[perf] %@: %.3f ms avg (budget %.3f ms)", label, average * 1000, budget * 1000))
    XCTAssertLessThan(average, budget, "\(label) too slow", file: file, line: line)
}
