#!/usr/bin/env swift
// Genere Packaging/Icon/AppIcon.iconset (puis iconutil en fait AppIcon.icns).
// Motif : un petit treemap en coussins sur un carre arrondi sombre.

import AppKit

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

/// Tuiles du treemap dans la zone 0...1 (origine en bas a gauche), avec leur couleur.
let tiles: [(NSRect, NSColor)] = [
    (NSRect(x: 0.00, y: 0.00, width: 0.56, height: 0.62), rgb(56, 107, 255)),
    (NSRect(x: 0.00, y: 0.62, width: 0.56, height: 0.38), rgb(255, 66, 66)),
    (NSRect(x: 0.56, y: 0.55, width: 0.44, height: 0.45), rgb(56, 214, 82)),
    (NSRect(x: 0.56, y: 0.22, width: 0.25, height: 0.33), rgb(255, 214, 31)),
    (NSRect(x: 0.81, y: 0.22, width: 0.19, height: 0.33), rgb(240, 82, 240)),
    (NSRect(x: 0.56, y: 0.00, width: 0.20, height: 0.22), rgb(31, 214, 240)),
    (NSRect(x: 0.76, y: 0.00, width: 0.24, height: 0.22), rgb(255, 143, 31)),
]

func draw(size: CGFloat) {
    let scale = size / 1024
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: scale, y: scale)

    // Grille d'icone macOS : carre arrondi de 824 points centre.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = rgb(0, 0, 0, 0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 24
    shadow.set()
    rgb(20, 22, 28).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: rgb(48, 52, 62), ending: rgb(18, 20, 26))!.draw(in: tilePath, angle: -90)

    let area = tile.insetBy(dx: 110, dy: 110)
    let gap: CGFloat = size <= 32 ? 22 : 12
    for (unit, color) in tiles {
        let rect = NSRect(x: area.minX + unit.minX * area.width, y: area.minY + unit.minY * area.height,
                          width: unit.width * area.width, height: unit.height * area.height)
            .insetBy(dx: gap / 2, dy: gap / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18)
        // Coussin : reflet vers le haut a gauche, bords assombris.
        let gradient = NSGradient(colors: [color.blended(withFraction: 0.55, of: .white)!, color,
                                           color.blended(withFraction: 0.55, of: .black)!],
                                  atLocations: [0, 0.45, 1], colorSpace: .sRGB)!
        gradient.draw(in: path, relativeCenterPosition: NSPoint(x: -0.35, y: 0.35))
    }
}

let sizes: [(String, CGFloat)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
    ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
    ("512x512", 512), ("512x512@2x", 1024),
]
let iconset = URL(fileURLWithPath: outputDirectory).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, size) in sizes {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(size: size)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!
        .write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
print("OK: \(iconset.path)")
