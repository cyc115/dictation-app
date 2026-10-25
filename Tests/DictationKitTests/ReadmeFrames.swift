import AppKit
import SwiftUI
import XCTest
@testable import DictationKit

/// Frames of the real app for the README's animations (scripts/readme-gifs.py), one folder per
/// scene: the recording pill playing a script of events, and Settings while the on-device model
/// downloads. Each folder gets PNGs and a frames.json (file, ms, and what the script composes with).
/// Skipped unless README_FRAMES=<dir> is set; the script sets it.
final class ReadmeFrames: XCTestCase {
    static let fps = 25.0

    private func folder(_ scene: String) throws -> URL {
        guard let dir = ProcessInfo.processInfo.environment["README_FRAMES"] else { throw XCTSkip("README_FRAMES not set") }
        let out = URL(fileURLWithPath: dir).appendingPathComponent(scene)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return out
    }

    // MARK: Scenes

    /// A Bluetooth mic starting, going live, a few seconds of speech, then polishing.
    func testHero() throws {
        try recordPill(try folder("hero"), length: 6.9, talking: [1.5...4.7], beats: [
            (0, { $0.showListening(micName: "Pixel Buds Pro", warmingUp: true) }),
            (0.95, { $0.micLive() }),
            (5.0, { $0.showProcessing() }),
            (5.9, { $0.hide() }),
        ])
    }

    /// What the pill's colors mean: starting, live (green), a better mic (yellow), no audio (red).
    func testPillStates() throws {
        try recordPill(try folder("pill"), length: 8.6, talking: [1.3...2.8, 3.3...4.6], beats: [
            (0, { $0.showListening(micName: "Pixel Buds Pro", warmingUp: true) }),
            (0.95, { $0.micLive() }),
            (3.0, { $0.micSwitched(to: "MacBook Pro Microphone") }),
            (4.9, { $0.micSilent() }),
            (6.9, { $0.showProcessing() }),
            (7.8, { $0.hide() }),
        ], captions: [(0, "A Bluetooth mic takes a moment to start"), (0.95, "Green: it's live, talk"),
                      (3.0, "Yellow: moved to the mic that hears you best"), (4.9, "Red: no sound is coming in"),
                      (6.9, "Stopped: transcribing and polishing")])
    }

    /// A command that runs (green) and one that doesn't fit any command (red, with what was heard).
    func testCommandMode() throws {
        let mic = "MacBook Pro Microphone"
        try recordPill(try folder("commands"), length: 8.8, talking: [0.35...1.6, 4.65...5.8], beats: [
            (0, { $0.showListening(micName: mic, command: true) }),
            (1.8, { $0.showProcessing() }),
            (2.3, { $0.show(PillMessage(title: "Volume 40%", tone: .done, seconds: 99)) }),
            (3.8, { $0.hide() }),
            (4.3, { $0.showListening(micName: mic, command: true) }),
            (6.0, { $0.showProcessing() }),
            (6.4, { $0.show(PillMessage(title: "Command not found", detail: "“open the pod bay doors”", tone: .failed, seconds: 99)) }),
            (8.2, { $0.hide() }),
        ], captions: [(0, "Enter button: command mode"), (0.35, "“声音小一点”"), (1.8, "Picking a command… 0.3 s"),
                      (2.3, "Ran volume −10"), (3.8, ""), (4.3, "Enter button again"), (4.65, "“open the pod bay doors”"),
                      (6.4, "Nothing fits, so nothing runs")],
           shakeAt: 6.4)
    }

    /// Settings › Speech model as the on-device model downloads from Hugging Face, then loads.
    @MainActor
    func testOnDeviceDownload() throws {
        let out = try folder("on-device")
        let runtime = SteppedRuntime()
        let model = LocalSpeechModel(repo: DictationSetup.onDevice.localModelID!, runtime: runtime)
        let settings = makeSettings(self, localModel: model)
        settings.setup = .onDevice
        let hosted = HostedView(Form { SpeechModelSection(settings: settings) }.formStyle(.grouped),
                                size: NSSize(width: 640, height: 250))
        addTeardownBlock { hosted.close() }
        var frames: [[String: Any]] = []
        func frame(_ ms: Int, caption: String) throws {
            spinRunLoop(0.05)
            let name = String(format: "frame-%03d.png", frames.count)
            try XCTUnwrap(snapshotBitmap(of: hosted.hostingView)?.representation(using: .png, properties: [:]))
                .write(to: out.appendingPathComponent(name))
            frames.append(["file": name, "ms": ms, "caption": caption])
        }
        try frame(1400, caption: "Pick On-device: 2.5 GB, once")
        model.prepare()
        waitUntil { runtime.report != nil }
        for step in 0...24 {
            runtime.report?(Double(step) / 24)
            try frame(step == 24 ? 400 : 90, caption: "Downloading from Hugging Face")
        }
        runtime.finish()
        waitUntil { if case .ready = model.state { return true } else { return false } }
        try frame(2200, caption: "Ready: nothing leaves your Mac")
        try JSONSerialization.data(withJSONObject: ["frames": frames, "scale": snapshotScale], options: [.prettyPrinted])
            .write(to: out.appendingPathComponent("frames.json"))
    }

    // MARK: The pill

    /// Plays `beats` (time, action) on a real pill, `fps` frames a second for `length` seconds, the
    /// mic sending speech during `talking` (room noise otherwise; silence once it shows no audio).
    /// frames.json has each frame's caption (the latest at or before it) and a sideways offset
    /// (`dx`, points) for the shake that follows `shakeAt`, which the rendering leaves out.
    private func recordPill(_ out: URL, length: Double, talking: [ClosedRange<Double>],
                            beats: [(Double, (OverlayWindow) -> Void)], captions: [(Double, String)] = [],
                            shakeAt: Double? = nil) throws {
        let overlay = OverlayWindow()
        overlay.makePanel = { OffscreenPanel(contentRect: $0, styleMask: [.borderless, .nonactivatingPanel],
                                             backing: .buffered, defer: false) }
        addTeardownBlock { overlay.hide() }
        var clock: TimeInterval = 0
        overlay.now = { clock }
        overlay.reduceMotion = { false }
        let syllables = talking.flatMap { Self.syllables(from: $0.lowerBound, to: $0.upperBound) }
        var pending = beats, nextPush = 0.0, nextRipple = 0.0, frames: [[String: Any]] = []
        for index in 0..<Int(length * Self.fps) {
            let t = Double(index) / Self.fps
            while nextPush <= t {  // the mic's ~21 ms buffers
                if overlay.mode == .listening, !overlay.isWarmingUp {
                    overlay.setLevel(overlay.isShowingNoAudio ? 0 : Self.level(at: nextPush, syllables))
                }
                nextPush += HALInput.chunkSeconds
            }
            clock = t
            while let beat = pending.first, beat.0 <= t {
                pending.removeFirst()
                beat.1(overlay)
                if overlay.mode == .processing { nextRipple = t }
            }
            while overlay.mode == .processing, nextRipple <= t { overlay.waveform.tick(); nextRipple += 1.0 / 30 }
            // A message isn't animated (the app stops the timer), and a redraw would drop its glow.
            if overlay.mode != .message { overlay.tick() }
            let name = String(format: "frame-%03d.png", index)
            let shown = overlay.mode != .hidden
            if shown, let png = try render(overlay) { try png.write(to: out.appendingPathComponent(name)) }
            // While a glow shows, the app turns the window's drop shadow off.
            frames.append(["file": shown ? name : NSNull(), "ms": Int(1000 / Self.fps),
                           "shadow": overlay.panel?.hasShadow ?? true,
                           "caption": captions.last { $0.0 <= t }?.1 ?? "",
                           "dx": shakeAt.map { Self.shake(t - $0) } ?? 0])
        }
        let index = try JSONSerialization.data(withJSONObject: ["frames": frames, "margin": OverlayWindow.glowMargin,
                                                                "scale": snapshotScale], options: [.prettyPrinted])
        try index.write(to: out.appendingPathComponent("frames.json"))
    }

    /// The failed-command shake (OverlayWindow.show: 0, −6, 6, −4, 4, 0 over 0.3 s) at `t` seconds in.
    private static func shake(_ t: Double) -> Double {
        let values: [Double] = [0, -6, 6, -4, 4, 0], duration = 0.3
        guard t > 0, t < duration else { return 0 }
        let position = t / duration * Double(values.count - 1), i = Int(position)
        return values[i] + (values[i + 1] - values[i]) * (position - Double(i))
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
        var seed: UInt64 = 0x5EED &+ UInt64(start * 1000)
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

/// A model download that moves only when told: `report` the progress, then `finish`.
private final class SteppedRuntime: SpeechRuntime {
    private(set) var report: (@MainActor (Double) -> Void)?
    private var done: CheckedContinuation<Void, Never>?

    func downloaded(_ repo: String) -> URL? { nil }

    func download(_ repo: String, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        report = progress
        await withCheckedContinuation { done = $0 }
        return URL(fileURLWithPath: "/tmp/readme-model")
    }

    func finish() { done?.resume(); done = nil }
    func load(_ directory: URL) async throws {}
    func transcribe(_ samples: [Float], maxTokens: Int, context: String) async throws -> String { "" }
    func unload() {}
}
