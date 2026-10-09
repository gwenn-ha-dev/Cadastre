// Shared icon generator — gwenn-ha-dev project charter §7.
//
// Copy this file to <Project>/outils/icone.swift, set FAMILY and NAME, then
// write the glyph in `drawGlyph`. Everything else — squircle, margin, gradient,
// sizes — is fixed by the charter and must not be edited per project.
//
//   swift outils/icone.swift "$PWD"
//   iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
//
// `make icon` does both, and only when this file is newer than the .icns.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// ---------------------------------------------------------------- per project

let NAME = "Cadastre"
// Tools: Cadastre is a system utility (LSApplicationCategoryType utilities),
// like Marnage and Sejour. It handles neither sound nor images, so neither the
// audio nor the image family would say what it is.
let FAMILY = Family.tools   // .audio | .image | .tools

/// The glyph, white, inside `box` — the centred 56 % of the canvas.
/// A squarified treemap (Bruls, Huizing, van Wijk) of a dozen weights: one
/// dominant block and a readable tail, which is what a disk looks like and
/// what the app draws. The tiles are packed by the same algorithm as the map,
/// not drawn to resemble it; their opacity steps down with their size.
func drawGlyph(_ ctx: CGContext, _ box: CGRect) {
    let weights: [CGFloat] = [34, 19, 13, 9, 7, 5, 4, 3, 2.2, 1.8, 1.4, 1.1]
    let gap = max(box.width * 0.022, 0.5)
    let tiles = squarify(weights, in: box)
    for (index, tile) in tiles.enumerated() {
        let alpha = 1.0 - 0.45 * CGFloat(index) / CGFloat(tiles.count - 1)
        let inset = tile.insetBy(dx: gap / 2, dy: gap / 2)
        guard inset.width > 0, inset.height > 0 else { continue }
        ctx.setFillColor(white(alpha))
        ctx.addPath(CGPath(roundedRect: inset, cornerWidth: gap * 0.8, cornerHeight: gap * 0.8, transform: nil))
        ctx.fillPath()
    }
}

/// Squarified layout of `weights` (sorted, largest first) into `rect`.
func squarify(_ weights: [CGFloat], in rect: CGRect) -> [CGRect] {
    let total = weights.reduce(0, +)
    let scale = rect.width * rect.height / total
    var areas = weights.map { $0 * scale }
    var free = rect
    var out: [CGRect] = []

    func worst(_ row: [CGFloat], _ side: CGFloat) -> CGFloat {
        let sum = row.reduce(0, +)
        guard let big = row.max(), let small = row.min(), sum > 0 else { return .infinity }
        return max(side * side * big / (sum * sum), (sum * sum) / (side * side * small))
    }

    while !areas.isEmpty {
        let side = min(free.width, free.height)
        var row: [CGFloat] = [areas.removeFirst()]
        while let next = areas.first, worst(row + [next], side) <= worst(row, side) {
            row.append(areas.removeFirst())
        }
        let sum = row.reduce(0, +)
        if free.width >= free.height {
            // A column on the left, filled from the top.
            let width = sum / free.height
            var y = free.maxY
            for area in row {
                let height = area / width
                out.append(CGRect(x: free.minX, y: y - height, width: width, height: height))
                y -= height
            }
            free = CGRect(x: free.minX + width, y: free.minY, width: free.width - width, height: free.height)
        } else {
            // A row along the top, filled from the left.
            let height = sum / free.width
            var x = free.minX
            for area in row {
                let width = area / height
                out.append(CGRect(x: x, y: free.maxY - height, width: width, height: height))
                x += width
            }
            free = CGRect(x: free.minX, y: free.minY, width: free.width, height: free.height - height)
        }
    }
    return out
}

// ---------------------------------------------------------------- the charter

enum Family {
    case audio, image, tools

    /// Linear gradient, top-left → bottom-right. Charter §7.
    var ramp: [[CGFloat]] {
        switch self {
        case .audio: return [[0.106, 0.227, 0.294, 1], [0.180, 0.545, 0.659, 1]]  // #1B3A4B → #2E8BA8
        case .image: return [[0.169, 0.129, 0.094, 1], [0.784, 0.529, 0.227, 1]]  // #2B2118 → #C8873A
        case .tools: return [[0.086, 0.200, 0.165, 1], [0.243, 0.557, 0.420, 1]]  // #16332A → #3E8E6B
        }
    }
}

let rgb = CGColorSpaceCreateDeviceRGB()
func white(_ a: CGFloat) -> CGColor { CGColor(colorSpace: rgb, components: [1, 1, 1, a])! }
func squircle(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func render(_ side: Int) -> CGImage {
    let t = CGFloat(side)
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                        bytesPerRow: 0, space: rgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Squircle background: 5.5 % margin, 22.5 % corner radius — macOS proportions.
    let margin = t * 0.055
    let plate = CGRect(x: margin, y: margin, width: t - 2 * margin, height: t - 2 * margin)
    ctx.saveGState()
    ctx.addPath(squircle(plate, t * 0.225))
    ctx.clip()
    let ramp = FAMILY.ramp
    let gradient = CGGradient(colorsSpace: rgb, colors: [
        CGColor(colorSpace: rgb, components: ramp[0])!,
        CGColor(colorSpace: rgb, components: ramp[1])!,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: t), end: CGPoint(x: t, y: 0), options: [])
    ctx.restoreGState()

    // The glyph occupies the centred 56 % of the canvas. Charter §7.
    let g = t * 0.56
    drawGlyph(ctx, CGRect(x: (t - g) / 2, y: (t - g) / 2, width: g, height: g))

    return ctx.makeImage()!
}

// ---------------------------------------------------------------- iconset

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath
let out = URL(fileURLWithPath: root).appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

for side in [16, 32, 128, 256, 512] {
    for (scale, suffix) in [(1, ""), (2, "@2x")] {
        let image = render(side * scale)
        let file = out.appendingPathComponent("icon_\(side)x\(side)\(suffix).png")
        let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
print("› \(NAME): Resources/AppIcon.iconset written (10 images)")
