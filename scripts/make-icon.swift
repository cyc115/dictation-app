// Renders the app icon: a dark glass tile with a glowing aurora waveform.
//
//   swift scripts/make-icon.swift [output-dir]     (default: Assets)
//
// Writes AppIcon-1024.png and AppIcon.icns (via sips + iconutil).
import AppKit
import CoreImage

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Assets", isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let size: CGFloat = 1024
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)  // Apple's macOS icon grid
let radius: CGFloat = 185
let space = CGColorSpace(name: CGColorSpace.displayP3)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255,
                                           CGFloat(hex & 0xff) / 255, alpha])!
}

func makeContext() -> CGContext {
    CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

let aurora = CGGradient(colorsSpace: space, colors: [color(0x22E4FF), color(0x6A7BFF), color(0xA855F7), color(0xFF4FB8)] as CFArray,
                        locations: [0, 0.38, 0.68, 1])!

// Waveform bars: speech-like, tallest just right of center.
let heights: [CGFloat] = [0.20, 0.36, 0.58, 0.44, 0.86, 1.0, 0.70, 0.50, 0.30, 0.18]
let barWidth: CGFloat = 38, gap: CGFloat = 26, maxHeight: CGFloat = 420
let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
let barsOrigin = CGPoint(x: (size - totalWidth) / 2, y: size / 2)

func barsPath() -> CGPath {
    let path = CGMutablePath()
    for (i, h) in heights.enumerated() {
        let height = max(barWidth, h * maxHeight)
        let rect = CGRect(x: barsOrigin.x + CGFloat(i) * (barWidth + gap), y: barsOrigin.y - height / 2,
                          width: barWidth, height: height)
        path.addRoundedRect(in: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2)
    }
    return path
}

/// The waveform filled with the aurora gradient, on a transparent layer.
func waveformLayer() -> CGImage {
    let ctx = makeContext()
    ctx.addPath(barsPath())
    ctx.clip()
    ctx.drawLinearGradient(aurora, start: CGPoint(x: barsOrigin.x, y: size * 0.3),
                           end: CGPoint(x: barsOrigin.x + totalWidth, y: size * 0.7), options: [])
    // Glassy top sheen on each bar.
    let sheen = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.55), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: size / 2 + maxHeight / 2), end: CGPoint(x: 0, y: size / 2), options: [])
    return ctx.makeImage()!
}

func blurred(_ image: CGImage, radius: CGFloat) -> CGImage {
    let input = CIImage(cgImage: image)
    let blur = input.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: input.extent)
    return CIContext(options: [.workingColorSpace: space]).createCGImage(blur, from: input.extent)!
}

let ctx = makeContext()
let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Drop shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: color(0x000000, 0.45))
ctx.addPath(tilePath)
ctx.setFillColor(color(0x0A0C1C))
ctx.fillPath()
ctx.restoreGState()

// Tile body: deep indigo-black with a violet glow rising from below.
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let body = CGGradient(colorsSpace: space, colors: [color(0x1B1640), color(0x0B0D20), color(0x05060F)] as CFArray,
                      locations: [0, 0.55, 1])!
ctx.drawLinearGradient(body, start: CGPoint(x: size / 2, y: tile.maxY), end: CGPoint(x: size / 2, y: tile.minY), options: [])
let underglow = CGGradient(colorsSpace: space, colors: [color(0x7C3AED, 0.55), color(0x7C3AED, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(underglow, startCenter: CGPoint(x: size / 2, y: tile.minY + 40), startRadius: 0,
                       endCenter: CGPoint(x: size / 2, y: tile.minY + 40), endRadius: 560, options: [])
let topglow = CGGradient(colorsSpace: space, colors: [color(0x22D3EE, 0.20), color(0x22D3EE, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(topglow, startCenter: CGPoint(x: tile.minX + 180, y: tile.maxY - 120), startRadius: 0,
                       endCenter: CGPoint(x: tile.minX + 180, y: tile.maxY - 120), endRadius: 520, options: [])

// "Listening" rings behind the waveform.
for (r, a) in [(300.0, 0.16), (360.0, 0.09), (420.0, 0.05)] as [(CGFloat, CGFloat)] {
    ctx.setStrokeColor(color(0x8B9CFF, a))
    ctx.setLineWidth(3)
    ctx.strokeEllipse(in: CGRect(x: size / 2 - r, y: size / 2 - r, width: 2 * r, height: 2 * r))
}

// Waveform with bloom: wide soft glow, tight glow, then crisp bars.
let wave = waveformLayer()
let full = CGRect(x: 0, y: 0, width: size, height: size)
ctx.setBlendMode(.screen)
ctx.setAlpha(0.9); ctx.draw(blurred(wave, radius: 60), in: full)
ctx.setAlpha(0.8); ctx.draw(blurred(wave, radius: 18), in: full)
ctx.setBlendMode(.normal)
ctx.setAlpha(1); ctx.draw(wave, in: full)

// Glass highlight across the top half of the tile.
let glass = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.07), color(0xFFFFFF, 0.0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(glass, start: CGPoint(x: size / 2, y: tile.maxY), end: CGPoint(x: size / 2, y: size / 2 + 60), options: [])
ctx.restoreGState()

// Rim: bright at the top edge, fading out toward the bottom.
ctx.saveGState()
ctx.addPath(tilePath.copy(strokingWithWidth: 4, lineCap: .round, lineJoin: .round, miterLimit: 1))
ctx.clip()
let rim = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.45), color(0xA5B4FC, 0.12), color(0xFFFFFF, 0.04)] as CFArray,
                     locations: [0, 0.5, 1])!
ctx.drawLinearGradient(rim, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
ctx.restoreGState()

// Write PNG + icns.
let png = outDir.appendingPathComponent("AppIcon-1024.png")
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try rep.representation(using: .png, properties: [:])!.write(to: png)

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func run(_ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    try p.run(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw NSError(domain: args[0], code: Int(p.terminationStatus)) }
}
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try run(["sips", "-z", "\(px)", "\(px)", png.path, "--out", iconset.appendingPathComponent(name).path])
    }
}
try run(["iconutil", "-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path])
try? FileManager.default.removeItem(at: iconset)
print("wrote \(png.path) and \(outDir.appendingPathComponent("AppIcon.icns").path)")
