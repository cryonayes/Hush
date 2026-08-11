// Generates AppIcon.icns — three faders on a squircle. Run via ./build.sh, or
// `swift make-icon.swift` directly after tweaking the palette below.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024
let art: CGFloat = 824            // macOS icons inset their art inside the canvas
let topColor = CGColor(red: 0.42, green: 0.55, blue: 1.00, alpha: 1)   // #6B8CFF
let bottomColor = CGColor(red: 0.55, green: 0.31, blue: 0.98, alpha: 1) // #8C4FFA

/// Apple's rounded corners are a continuous superellipse, not a circular arc —
/// a plain rounded rect reads subtly wrong next to real app icons.
func squircle(in rect: CGRect, n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 360
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func drawIcon(size: CGFloat) -> CGImage {
    let scale = size / canvas
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    ctx.setAllowsAntialiasing(true)

    let inset = (canvas - art) / 2
    let body = CGRect(x: inset, y: inset, width: art, height: art)

    // Gradient body
    ctx.saveGState()
    ctx.addPath(squircle(in: body))
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [topColor, bottomColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: body.minX, y: body.maxY),
                           end: CGPoint(x: body.maxX, y: body.minY),
                           options: [])
    ctx.restoreGState()

    // Three faders at different levels — reads as "mixer" instantly, unlike a
    // speaker glyph which reads as "volume" generally.
    let trackW: CGFloat = 52, trackH: CGFloat = 470
    let spacing: CGFloat = 172
    let levels: [CGFloat] = [0.62, 0.34, 0.78]   // knob position, fraction from bottom
    let trackBottom = body.midY - trackH / 2

    for (i, level) in levels.enumerated() {
        let x = body.midX + CGFloat(i - 1) * spacing
        let track = CGRect(x: x - trackW / 2, y: trackBottom, width: trackW, height: trackH)

        ctx.setFillColor(CGColor(gray: 1, alpha: 0.22))
        ctx.addPath(CGPath(roundedRect: track, cornerWidth: trackW / 2,
                           cornerHeight: trackW / 2, transform: nil))
        ctx.fillPath()

        // Filled portion below the knob, so each fader shows a level.
        let filled = CGRect(x: track.minX, y: track.minY, width: trackW, height: trackH * level)
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.92))
        ctx.addPath(CGPath(roundedRect: filled, cornerWidth: trackW / 2,
                           cornerHeight: trackW / 2, transform: nil))
        ctx.fillPath()

        let knobW: CGFloat = 132, knobH: CGFloat = 72
        let knob = CGRect(x: x - knobW / 2, y: trackBottom + trackH * level - knobH / 2,
                          width: knobW, height: knobH)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18,
                      color: CGColor(gray: 0, alpha: 0.28))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.addPath(CGPath(roundedRect: knob, cornerWidth: knobH / 2,
                           cornerHeight: knobH / 2, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
    }

    return ctx.makeImage()!
}

let iconset = URL(fileURLWithPath: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        let url = iconset.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, drawIcon(size: CGFloat(px)), nil)
        CGImageDestinationFinalize(dest)
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "AppIcon.iconset", "-o", "AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("wrote AppIcon.icns")
