#!/usr/bin/env swift
//
// Renders the AnkiClone app icon.
//
//   swift Tools/make-icon.swift AnkiClone/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
//
// The mark is a flashcard with a sound wave coming off it: the two things the
// app is: Anki cards, and hearing them. Drawn in code so it can be regenerated
// at any size and tweaked without a design tool.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side: CGFloat = 1024
let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon.png"

// MARK: - Palette

func srgb(_ hex: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

let backgroundTop = srgb(0x6366F1)     // indigo
let backgroundBottom = srgb(0x7C3AED)  // violet
let ink = srgb(0x3F3AC4)               // the glyph, a shade deeper than the ground
let paper = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

// MARK: - Canvas

guard let context = CGContext(
    data: nil,
    width: Int(side),
    height: Int(side),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("could not create the bitmap context")
}

// Background: a diagonal gradient. iOS applies the rounded-rect mask itself, so
// the artwork is drawn full-bleed.
let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [backgroundTop, backgroundBottom] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: side),
    end: CGPoint(x: side, y: 0),
    options: []
)

// MARK: - Cards

let center = CGPoint(x: side / 2, y: side / 2)
let cardSize = CGSize(width: 700, height: 508)
let cardRadius: CGFloat = 68

func cardPath(size: CGSize, radius: CGFloat) -> CGPath {
    CGPath(
        roundedRect: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height),
        cornerWidth: radius,
        cornerHeight: radius,
        transform: nil
    )
}

/// The card behind, peeking out — a deck, not a single card.
context.saveGState()
context.translateBy(x: center.x, y: center.y + 26)
context.rotate(by: -7 * .pi / 180)
context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.32))
context.addPath(cardPath(size: cardSize, radius: cardRadius))
context.fillPath()
context.restoreGState()

/// The card in front.
context.saveGState()
context.translateBy(x: center.x, y: center.y - 14)
context.setShadow(offset: CGSize(width: 0, height: -18), blur: 44,
                  color: CGColor(srgbRed: 0.1, green: 0.05, blue: 0.35, alpha: 0.30))
context.setFillColor(paper)
context.addPath(cardPath(size: cardSize, radius: cardRadius))
context.fillPath()
context.restoreGState()

// MARK: - Sound mark
//
// A speaker with three arcs. Sized and positioned so the whole mark is optically
// centred on the front card.

context.saveGState()
context.translateBy(x: center.x, y: center.y - 14)

// `coneRight` is picked so the speaker plus its arcs are centred on the card:
// the mark runs from `bodyLeft` to the outermost arc, and that span straddles 0.
let coneRight: CGFloat = -16     // where the speaker's cone ends and the arcs begin
let bodyHalfHeight: CGFloat = 38
let coneHalfHeight: CGFloat = 106
let bodyLeft: CGFloat = coneRight - 194
let bodyRight: CGFloat = coneRight - 102

let speaker = CGMutablePath()
speaker.move(to: CGPoint(x: bodyLeft + 16, y: -bodyHalfHeight))
speaker.addLine(to: CGPoint(x: bodyRight, y: -bodyHalfHeight))
speaker.addLine(to: CGPoint(x: coneRight, y: -coneHalfHeight))
speaker.addLine(to: CGPoint(x: coneRight, y: coneHalfHeight))
speaker.addLine(to: CGPoint(x: bodyRight, y: bodyHalfHeight))
speaker.addLine(to: CGPoint(x: bodyLeft + 16, y: bodyHalfHeight))
speaker.closeSubpath()

context.setFillColor(ink)
context.setLineJoin(.round)
context.setLineWidth(34)
context.setStrokeColor(ink)
context.addPath(speaker)
context.drawPath(using: .fillStroke)

context.setLineCap(.round)
context.setLineWidth(33)
for radius in stride(from: CGFloat(82), through: 206, by: 62) {
    context.addArc(
        center: CGPoint(x: coneRight + 4, y: 0),
        radius: radius,
        startAngle: -52 * .pi / 180,
        endAngle: 52 * .pi / 180,
        clockwise: false
    )
    context.strokePath()
}
context.restoreGState()

// MARK: - Write

guard let image = context.makeImage() else { fatalError("could not render the icon") }
let url = URL(fileURLWithPath: outputPath)
guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("could not open \(outputPath) for writing")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(outputPath)") }
print("wrote \(outputPath) (\(Int(side))×\(Int(side)))")
