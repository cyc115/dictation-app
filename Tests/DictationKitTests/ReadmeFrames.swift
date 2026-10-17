import AppKit
import XCTest
@testable import DictationKit

/// Frames of the real pill for the README's animated screenshot (scripts/readme-screenshot.py):
/// a Bluetooth mic starting, going live, a few seconds of speech, then polishing. Skipped unless
/// README_FRAMES=<dir> is set; the script sets it.
final class ReadmeFrames: XCTestCase {
    static let fps = 25.0

    func testWriteFrames() throws {
        guard let dir = ProcessInfo.processInfo.environment["README_FRAMES"] else { throw XCTSkip("README_FRAMES not set") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let overlay = OverlayWindow()
        overlay.makePanel = { OffscreenPanel(contentRect: $0, styleMask: [.borderless, .nonactivatingPanel],
                                             backing: .buffered, defer: false) }
        addTeardownBlock { overlay.hide() }
        var clock: TimeInterval = 0
        overlay.now = { clock }
        overlay.reduceMotion = { false }

        let live = 0.95, speech = (1.5, 4.7), polish = 5.0, hide = 5.9, end = 6.9
        let syllables = Self.syllables(from: speech.0, to: speech.1)
        overlay.showListening(micName: "Pixel Buds Pro", warmingUp: true)
        var nextPush = 0.0, nextRipple = polish, frames: [[String: Any]] = []
        for index in 0..<Int(end * Self.fps) {
            let t = Double(index) / Self.fps
            while nextPush <= t {  // the mic's ~21 ms buffers
                if nextPush >= live, nextPush < polish { overlay.setLevel(Self.level(at: nextPush, syllables)) }
                nextPush += HALInput.chunkSeconds
            }
            clock = t
            if t >= live, overlay.isWarmingUp { overlay.micLive() }
            if t >= polish, overlay.mode == .listening { overlay.showProcessing() }
            while overlay.mode == .processing, nextRipple <= t { overlay.waveform.tick(); nextRipple += 1.0 / 30 }
            overlay.tick()
            let name = String(format: "frame-%03d.png", index)
            let shown = t < hide
            if shown, let png = try render(overlay) { try png.write(to: out.appendingPathComponent(name)) }
            // While the green glow shows, the app turns the window's drop shadow off.
            frames.append(["file": shown ? name : NSNull(), "ms": Int(1000 / Self.fps),
                           "shadow": overlay.panel?.hasShadow ?? true])
        }
        let index = try JSONSerialization.data(withJSONObject: ["frames": frames, "margin": OverlayWindow.glowMargin,
                                                                "scale": snapshotScale], options: [.prettyPrinted])
        try index.write(to: out.appendingPathComponent("frames.json"))
    }

    /// The pill as the window server shows it: its own drawing, with the view's current glow
    /// (`shadow`) and bounce (layer transform) applied, which `cacheDisplay` alone leaves out.
    private func render(_ overlay: OverlayWindow) throws -> Data? {
        let view = try XCTUnwrap(overlay.panel?.contentView)
        let pill = try XCTUnwrap(view.subviews.first)
        view.layoutSubtreeIfNeeded()
        let scale = snapshotScale
        guard let pillImage = snapshotBitmap(of: pill)?.cgImage,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale),
                                         pixelsHigh: Int(view.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)?.retagging(with: .sRGB),
              let context = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: pill.frame.minX, y: pill.frame.minY)
        if let transform = pill.layer?.transform { context.concatenate(CATransform3DGetAffineTransform(transform)) }
        if let glow = pill.shadow, let color = glow.shadowColor {
            // Shadow sizes are in pixels, not points.
            context.setShadow(offset: CGSize(width: glow.shadowOffset.width * scale, height: glow.shadowOffset.height * scale),
                              blur: glow.shadowBlurRadius * scale, color: color.cgColor)
        }
        context.draw(pillImage, in: pill.bounds)
        return rep.representation(using: .png, properties: [:])
    }

    /// Speech as syllables (start, length, loudness), deterministic so the frames don't change.
    private static func syllables(from start: Double, to end: Double) -> [(Double, Double, Double)] {
        var seed: UInt64 = 0x5EED
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        var out: [(Double, Double, Double)] = []
        var t = start
        while t < end {
            for _ in 0..<(2 + Int(random() * 4)) where t < end {
                let length = 0.11 + random() * 0.07
                out.append((t, length, 0.55 + random() * 0.4))
                t += length + 0.03 + random() * 0.04
            }
            t += 0.12 + random() * 0.16
        }
        return out
    }

    private static func level(at t: Double, _ syllables: [(Double, Double, Double)]) -> Float {
        for (start, length, loudness) in syllables where t >= start && t < start + length {
            return Float(loudness * pow(sin(.pi * (t - start) / length), 0.8))
        }
        return 0.04  // room noise
    }
}
