#!/usr/bin/env swift
import AppKit
import Foundation

// Derive only the dev asset; regenerating it must never rewrite the shipped artwork.
// Scripts/tools/make-dev-icon.swift -> the repository root is three levels up.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
guard let source = NSImage(contentsOf: root.appendingPathComponent("App/AppIcon.icns")) else {
    fatalError("could not read App/AppIcon.icns")
}
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let iconset = temporary.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                        (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let size = NSSize(width: pixels, height: pixels)
    let image = NSImage(size: size, flipped: false) { rect in
        source.draw(in: rect)
        // A corner badge leaves the central mark visible; amber separates it from the blue art.
        let badge = NSRect(x: rect.width * 0.49, y: rect.height * 0.68,
                           width: rect.width * 0.34, height: rect.height * 0.15)
        let shape = NSBezierPath(roundedRect: badge, xRadius: rect.width * 0.035,
                                 yRadius: rect.height * 0.035)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowOffset = NSSize(width: 0, height: -rect.height * 0.006)
        shadow.shadowBlurRadius = rect.height * 0.012
        shadow.set()
        NSColor(srgbRed: 1, green: 0.70, blue: 0.14, alpha: 1).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.7).setStroke()
        shape.lineWidth = rect.width * 0.003
        shape.stroke()
        let text = NSAttributedString(string: "DEV", attributes: [
            .font: NSFont.systemFont(ofSize: rect.height * 0.082, weight: .bold),
            .foregroundColor: NSColor(srgbRed: 0.19, green: 0.13, blue: 0.06, alpha: 1),
            .kern: rect.width * 0.004,
        ])
        let textSize = text.size()
        text.draw(at: NSPoint(x: badge.midX - textSize.width / 2,
                              y: badge.midY - textSize.height / 2))
        return true
    }
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("could not render development icon")
    }
    let suffix = scale == 1 ? "" : "@2x"
    try png.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o",
                     root.appendingPathComponent("App/AppIcon-dev.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
print("Generated App/AppIcon-dev.icns (release icon unchanged)")
