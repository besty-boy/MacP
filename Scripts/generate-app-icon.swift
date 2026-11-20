#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

// Renders a native macOS Squircle Liquid Glass AppIcon set for MacP into Assets.xcassets.

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let rootDir = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let iconsetDir = rootDir
    .appendingPathComponent("MacPApp", isDirectory: true)
    .appendingPathComponent("Assets.xcassets", isDirectory: true)
    .appendingPathComponent("AppIcon.appiconset", isDirectory: true)

try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

func renderIcon(pixelSize: Int) -> CGImage {
    let size = CGFloat(pixelSize)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Clear transparent canvas
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

    // macOS HIG Squircle bounds (~10% inset for shadow breathing room)
    let inset = size * 0.095
    let cardRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let cornerRadius = cardRect.width * 0.225
    let cardPath = CGPath(roundedRect: cardRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Soft ambient shadow behind tile
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -size * 0.025),
        blur: size * 0.05,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.42)
    )
    ctx.addPath(cardPath)
    ctx.setFillColor(CGColor(red: 0.06, green: 0.09, blue: 0.20, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // Clip to squircle for Liquid Glass interior
    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.clip()

    // Base midnight sapphire vertical gradient
    let bgColors = [
        CGColor(red: 0.05, green: 0.08, blue: 0.18, alpha: 1.0),
        CGColor(red: 0.10, green: 0.19, blue: 0.40, alpha: 1.0),
        CGColor(red: 0.14, green: 0.30, blue: 0.58, alpha: 1.0)
    ] as CFArray
    let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.55, 1.0])!
    ctx.drawLinearGradient(
        bgGradient,
        start: CGPoint(x: cardRect.midX, y: cardRect.minY),
        end: CGPoint(x: cardRect.midX, y: cardRect.maxY),
        options: []
    )

    // Cyan-electric aurora glow in upper-right
    let glowColors1 = [
        CGColor(red: 0.22, green: 0.78, blue: 1.0, alpha: 0.55),
        CGColor(red: 0.22, green: 0.78, blue: 1.0, alpha: 0.0)
    ] as CFArray
    let glow1 = CGGradient(colorsSpace: colorSpace, colors: glowColors1, locations: [0.0, 1.0])!
    ctx.drawRadialGradient(
        glow1,
        startCenter: CGPoint(x: cardRect.minX + cardRect.width * 0.74, y: cardRect.minY + cardRect.height * 0.78),
        startRadius: 0,
        endCenter: CGPoint(x: cardRect.minX + cardRect.width * 0.74, y: cardRect.minY + cardRect.height * 0.78),
        endRadius: cardRect.width * 0.58,
        options: []
    )

    // Subtle indigo/violet lower-left glow
    let glowColors2 = [
        CGColor(red: 0.48, green: 0.32, blue: 1.0, alpha: 0.48),
        CGColor(red: 0.48, green: 0.32, blue: 1.0, alpha: 0.0)
    ] as CFArray
    let glow2 = CGGradient(colorsSpace: colorSpace, colors: glowColors2, locations: [0.0, 1.0])!
    ctx.drawRadialGradient(
        glow2,
        startCenter: CGPoint(x: cardRect.minX + cardRect.width * 0.24, y: cardRect.minY + cardRect.height * 0.22),
        startRadius: 0,
        endCenter: CGPoint(x: cardRect.minX + cardRect.width * 0.24, y: cardRect.minY + cardRect.height * 0.22),
        endRadius: cardRect.width * 0.55,
        options: []
    )

    // Liquid Glass top specular dome reflection
    let glassSheenRect = CGRect(
        x: cardRect.minX - cardRect.width * 0.1,
        y: cardRect.minY + cardRect.height * 0.52,
        width: cardRect.width * 1.2,
        height: cardRect.height * 0.65
    )
    let sheenColors = [
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.24),
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.0)
    ] as CFArray
    let sheenGradient = CGGradient(colorsSpace: colorSpace, colors: sheenColors, locations: [0.0, 1.0])!
    ctx.saveGState()
    ctx.addEllipse(in: glassSheenRect)
    ctx.clip()
    ctx.drawLinearGradient(
        sheenGradient,
        start: CGPoint(x: cardRect.midX, y: cardRect.maxY),
        end: CGPoint(x: cardRect.midX, y: cardRect.midY),
        options: []
    )
    ctx.restoreGState()

    // Centered MCP Bridge Emblem (3 glowing constellation nodes + sleek glass bridges)
    let cx = cardRect.midX
    let cy = cardRect.midY
    let r = cardRect.width * 0.235

    let topNode = CGPoint(x: cx, y: cy + r * 0.96)
    let leftNode = CGPoint(x: cx - r * 0.92, y: cy - r * 0.66)
    let rightNode = CGPoint(x: cx + r * 0.92, y: cy - r * 0.66)
    let centerNode = CGPoint(x: cx, y: cy - r * 0.06)

    // Connecting bridge arcs/lines with glow
    ctx.saveGState()
    ctx.setShadow(
        offset: .zero,
        blur: size * 0.035,
        color: CGColor(red: 0.35, green: 0.85, blue: 1.0, alpha: 0.85)
    )
    ctx.setStrokeColor(CGColor(red: 0.86, green: 0.96, blue: 1.0, alpha: 0.92))
    ctx.setLineWidth(max(1.2, size * 0.038))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // Outer bridge triangle + hub spokes
    let lines: [(CGPoint, CGPoint)] = [
        (leftNode, topNode),
        (topNode, rightNode),
        (leftNode, rightNode),
        (centerNode, topNode),
        (centerNode, leftNode),
        (centerNode, rightNode)
    ]
    for (i, pair) in lines.enumerated() {
        ctx.setLineWidth(i < 3 ? max(1.2, size * 0.034) : max(1.0, size * 0.022))
        ctx.setStrokeColor(
            i < 3
                ? CGColor(red: 0.86, green: 0.96, blue: 1.0, alpha: 0.88)
                : CGColor(red: 0.50, green: 0.88, blue: 1.0, alpha: 0.62)
        )
        ctx.beginPath()
        ctx.move(to: pair.0)
        ctx.addLine(to: pair.1)
        ctx.strokePath()
    }
    ctx.restoreGState()

    // Draw luminous frosted glass nodes
    func drawNode(at point: CGPoint, radius: CGFloat, isHub: Bool) {
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -size * 0.008),
            blur: size * 0.028,
            color: CGColor(red: 0.0, green: 0.15, blue: 0.35, alpha: 0.55)
        )
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        let nodeColors: CFArray = isHub
            ? ([
                CGColor(red: 0.45, green: 0.92, blue: 1.0, alpha: 1.0),
                CGColor(red: 0.16, green: 0.58, blue: 1.0, alpha: 1.0)
            ] as CFArray)
            : ([
                CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
                CGColor(red: 0.78, green: 0.91, blue: 1.0, alpha: 1.0)
            ] as CFArray)
        let nodeGrad = CGGradient(colorsSpace: colorSpace, colors: nodeColors, locations: [0.0, 1.0])!
        ctx.addEllipse(in: rect)
        ctx.clip()
        ctx.drawLinearGradient(
            nodeGrad,
            start: CGPoint(x: point.x, y: point.y + radius),
            end: CGPoint(x: point.x, y: point.y - radius),
            options: []
        )
        ctx.restoreGState()
    }

    let outerRadius = max(2.2, size * 0.072)
    let hubRadius = max(2.8, size * 0.092)
    drawNode(at: topNode, radius: outerRadius, isHub: false)
    drawNode(at: leftNode, radius: outerRadius, isHub: false)
    drawNode(at: rightNode, radius: outerRadius, isHub: false)
    drawNode(at: centerNode, radius: hubRadius, isHub: true)

    // Crisp Liquid Glass inner rim stroke
    ctx.addPath(cardPath)
    ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.32))
    ctx.setLineWidth(max(1.0, size * 0.012))
    ctx.strokePath()

    ctx.restoreGState()

    return ctx.makeImage()!
}

struct IconSpec {
    let sizePt: Int
    let scale: Int
    var pixels: Int { sizePt * scale }
    var filename: String { "icon_\(sizePt)x\(sizePt)@\(scale)x.png" }
}

let specs: [IconSpec] = [
    IconSpec(sizePt: 16, scale: 1),
    IconSpec(sizePt: 16, scale: 2),
    IconSpec(sizePt: 32, scale: 1),
    IconSpec(sizePt: 32, scale: 2),
    IconSpec(sizePt: 128, scale: 1),
    IconSpec(sizePt: 128, scale: 2),
    IconSpec(sizePt: 256, scale: 1),
    IconSpec(sizePt: 256, scale: 2),
    IconSpec(sizePt: 512, scale: 1),
    IconSpec(sizePt: 512, scale: 2)
]

for spec in specs {
    let cgImg = renderIcon(pixelSize: spec.pixels)
    let rep = NSBitmapImageRep(cgImage: cgImg)
    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to encode PNG for \(spec.filename)")
    }
    try pngData.write(to: iconsetDir.appendingPathComponent(spec.filename), options: .atomic)
}

let imagesJSON = specs.map { spec in
    """
        {
          "filename" : "\(spec.filename)",
          "idiom" : "mac",
          "scale" : "\(spec.scale)x",
          "size" : "\(spec.sizePt)x\(spec.sizePt)"
        }
    """
}.joined(separator: ",\n")

let contentsJSON = """
{
  "images" : [
\(imagesJSON)
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""

try contentsJSON.write(
    to: iconsetDir.appendingPathComponent("Contents.json"),
    atomically: true,
    encoding: .utf8
)

print("Generated \(specs.count) native macOS AppIcon assets in \(iconsetDir.path)")
