// Renders the app icon: a black tile with a bold white waveform (high contrast).
//
//   swift scripts/make-icon.swift [output-dir]     (default: Assets)
//
// Writes AppIcon-1024.png and AppIcon.icns (via sips + iconutil).
import AppKit

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

// High-contrast design: black tile, bold white waveform. No glow or blur, so it stays crisp
// and recognizable at Dock and menu sizes (down to 16 px).
let heights: [CGFloat] = [0.30, 0.58, 0.86, 1.0, 0.70, 0.46, 0.24]
let barWidth: CGFloat = 64, gap: CGFloat = 36, maxHeight: CGFloat = 460
let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap

let ctx = makeContext()
let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Soft drop shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(color(0x0B0B0C))
ctx.fillPath()
ctx.restoreGState()

// Tile: near-black with a barely-there lift toward the top.
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let body = CGGradient(colorsSpace: space, colors: [color(0x26272B), color(0x0B0B0C)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(body, start: CGPoint(x: size / 2, y: tile.maxY), end: CGPoint(x: size / 2, y: tile.minY + 200), options: [])

// Bars: solid white, fully rounded.
ctx.setFillColor(color(0xFFFFFF))
let originX = (size - totalWidth) / 2
for (i, h) in heights.enumerated() {
    let height = max(barWidth, h * maxHeight)
    let rect = CGRect(x: originX + CGFloat(i) * (barWidth + gap), y: size / 2 - height / 2, width: barWidth, height: height)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
}
ctx.fillPath()
ctx.restoreGState()

// Thin rim so the black tile stays defined on a dark Dock.
ctx.saveGState()
ctx.addPath(tilePath.copy(strokingWithWidth: 3, lineCap: .round, lineJoin: .round, miterLimit: 1))
ctx.clip()
let rim = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0.06)] as CFArray, locations: [0, 1])!
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
