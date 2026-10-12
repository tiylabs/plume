#!/usr/bin/env swift
//
// Turns the two design exports in Design/ into the assets the app bundle wants.
//
//   Scripts/make-icons.swift
//   Scripts/make-icons.swift --app-only   leave menu-bar resources unchanged
//   Scripts/make-icons.swift --menu-only  leave app icons unchanged
//
// Run it by hand when the artwork changes; the outputs are committed, so a plain checkout builds
// without needing to regenerate anything. `Scripts/build-app.sh` picks both of them up on its own.
//
//   Design/AppIcon.png       square PNG      ->  App/AppIcon.icns
//   Design/MenuBarIcon.png   monochrome PNG  ->  App/Resources/MenuBar{,@2x,@3x}.png
//
// The app export already includes the intended transparent margin: keep its entire canvas and
// alpha unchanged, and only resample for smaller icon representations. The menu-bar export is
// fitted separately to its 18-point canvas, and a flattened export — white paper baked in as
// opaque pixels with the alpha channel dropped — is keyed back to alpha first; see
// `keyWhitePaper`.

import AppKit
import CoreGraphics
import Foundation

// ---------------------------------------------------------------------------------------------
// Bitmap
// ---------------------------------------------------------------------------------------------

/// Straight-alpha RGBA8, which is what the keying maths below assumes.
struct Bitmap {
    var pixels: [UInt8]
    let width: Int
    let height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    subscript(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        get {
            let i = (y * width + x) * 4
            return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
        }
        set {
            let i = (y * width + x) * 4
            pixels[i] = newValue.r
            pixels[i + 1] = newValue.g
            pixels[i + 2] = newValue.b
            pixels[i + 3] = newValue.a
        }
    }

}

func loadBitmap(_ url: URL) -> Bitmap {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        fail("could not read \(url.path)")
    }

    var bitmap = Bitmap(width: image.width, height: image.height)

    // Backing memory the context owns for its whole life. Reaching into the array with
    // `withUnsafeMutableBytes` and letting the context outlive the closure would hand CoreGraphics a
    // pointer Swift is free to move.
    let byteCount = image.width * image.height * 4
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 4)
    buffer.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
    defer { buffer.deallocate() }

    // A bitmap context can only be premultiplied; straight alpha is recovered just below.
    guard let context = CGContext(
        data: buffer,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fail("could not make a bitmap context")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    bitmap.pixels.withUnsafeMutableBytes { destination in
        destination.copyMemory(from: UnsafeRawBufferPointer(start: buffer, count: byteCount))
    }

    // Recover straight alpha before wrapping the pixels as a CGImage. Transparent artwork and
    // soft shadows would otherwise be premultiplied again when the icon canvas draws them.
    for i in stride(from: 0, to: bitmap.pixels.count, by: 4) {
        let a = Int(bitmap.pixels[i + 3])
        guard a > 0, a < 255 else { continue }
        for c in 0..<3 {
            bitmap.pixels[i + c] = UInt8(min(255, Int(bitmap.pixels[i + c]) * 255 / a))
        }
    }
    return bitmap
}

/// Wraps a straight-alpha bitmap as a `CGImage`.
///
/// Via a data provider rather than a bitmap context, because a context cannot hold straight alpha —
/// its only RGBA option is premultiplied — while a `CGImage` is happy to. Going through a context
/// here would premultiply the keyed edge ring a second time and darken it.
func cgImage(_ bitmap: Bitmap) -> CGImage {
    guard let provider = CGDataProvider(data: Data(bitmap.pixels) as CFData) else {
        fail("could not wrap the pixels")
    }
    guard let image = CGImage(
        width: bitmap.width,
        height: bitmap.height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bitmap.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    ) else {
        fail("could not build an image")
    }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil
    ) else {
        fail("could not write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("could not finalise \(url.path)") }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// Bounds are in bitmap-row coordinates, where CGContext's first row is at the bottom.
func inkBounds(_ bitmap: Bitmap, minimumAlpha: UInt8 = 9) -> CGRect {
    var minX = bitmap.width, maxX = -1, minY = bitmap.height, maxY = -1
    for y in 0..<bitmap.height {
        for x in 0..<bitmap.width where bitmap[x, y].a >= minimumAlpha {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else { fail("the artwork is entirely transparent") }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

/// Keys a flattened white-paper export back into the alpha PNG this pipeline expects.
///
/// The menu-bar glyph ships as a template image, so its alpha *is* the mask macOS tints — an
/// export that arrives with the paper baked in as opaque pixels would put a white square in the
/// menu bar. Some export presets drop the alpha channel that way, and for a monochrome glyph on
/// white paper the composite inverts exactly: an observed value `v` between black ink and white
/// paper is `v = 255 · (1 − a)`, so `a = 255 − v` with the ink left black, and the anti-aliased
/// edge ring comes back as the soft alpha it was before the export flattened it.
///
/// Only fully opaque pixels are keyed, so an export that already carries its own alpha passes
/// through untouched — black ink on transparent pixels keys to itself.
func keyWhitePaper(_ bitmap: inout Bitmap) {
    for i in stride(from: 0, to: bitmap.pixels.count, by: 4) {
        guard bitmap.pixels[i + 3] == 255 else { continue }
        let ink = 255 - min(bitmap.pixels[i], min(bitmap.pixels[i + 1], bitmap.pixels[i + 2]))
        bitmap.pixels[i] = 0
        bitmap.pixels[i + 1] = 0
        bitmap.pixels[i + 2] = 0
        bitmap.pixels[i + 3] = UInt8(ink)
    }
}

/// Draws `image`'s `crop` region centred in a `size`² canvas, scaled so its longest side is `fit`.
func compose(_ image: CGImage, crop: CGRect, canvas: Int, fit: Double) -> CGImage {
    let imageCrop = CGRect(x: crop.minX, y: CGFloat(image.height) - crop.maxY,
                           width: crop.width, height: crop.height)
    guard let cropped = image.cropping(to: imageCrop) else { fail("crop failed") }

    let scale = fit / Double(max(crop.width, crop.height))
    let w = Double(crop.width) * scale
    let h = Double(crop.height) * scale

    guard let context = CGContext(
        data: nil,
        width: canvas,
        height: canvas,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fail("could not make a \(canvas)² canvas")
    }

    context.interpolationQuality = .high
    context.draw(
        cropped,
        in: CGRect(
            x: (Double(canvas) - w) / 2,
            y: (Double(canvas) - h) / 2,
            width: w,
            height: h
        )
    )
    guard let out = context.makeImage() else { fail("could not render the canvas") }
    return out
}

/// Resamples a square master down to `size`².
func resize(_ image: CGImage, to size: Int) -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fail("could not make a \(size)² canvas")
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let out = context.makeImage() else { fail("resize failed") }
    return out
}

// ---------------------------------------------------------------------------------------------
// Run
// ---------------------------------------------------------------------------------------------

let root = URL(fileURLWithPath: CommandLine.arguments.first.map {
    URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path
} ?? FileManager.default.currentDirectoryPath)

let design = root.appendingPathComponent("Design")
let appFolder = root.appendingPathComponent("App")
let resources = appFolder.appendingPathComponent("Resources")
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.isEmpty || arguments == ["--app-only"] || arguments == ["--menu-only"] else {
    fail("usage: Scripts/make-icons.swift [--app-only|--menu-only]")
}

// ---- app icon ---------------------------------------------------------------------------------

if arguments != ["--menu-only"] {
    print("==> App icon")

    let appURL = design.appendingPathComponent("AppIcon.png")
    guard let appSource = CGImageSourceCreateWithURL(appURL as CFURL, nil),
          let master = CGImageSourceCreateImageAtIndex(appSource, 0, nil) else {
        fail("could not read \(appURL.path)")
    }
    guard master.width == master.height else { fail("AppIcon.png must have a square canvas") }
    print("    preserved full \(master.width)×\(master.height) canvas and original alpha")

    let iconset = appFolder.appendingPathComponent("AppIcon.iconset")
    try? FileManager.default.removeItem(at: iconset)
    try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

    // Copy representations matching the source dimensions verbatim; smaller sizes use the whole image.
    for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                            (256, 1), (256, 2), (512, 1), (512, 2)] {
        let pixels = points * scale
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let destination = iconset.appendingPathComponent(name)
        if pixels == master.width {
            try Data(contentsOf: appURL).write(to: destination)
        } else {
            writePNG(resize(master, to: pixels), to: destination)
        }
    }

    let icns = appFolder.appendingPathComponent("AppIcon.icns")
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
    try! iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else { fail("iconutil failed") }

    // The .iconset is an intermediate; the .icns is the artefact worth committing.
    try? FileManager.default.removeItem(at: iconset)
    print("    wrote App/AppIcon.icns")
}

// ---- menu bar icon ----------------------------------------------------------------------------

if arguments == ["--app-only"] { exit(0) }
print("==> Menu bar icon")

var menuSource = loadBitmap(design.appendingPathComponent("MenuBarIcon.png"))
keyWhitePaper(&menuSource)
let menuImage = cgImage(menuSource)
let glyph = inkBounds(menuSource)
print("    artwork \(Int(glyph.width))×\(Int(glyph.height))")

// 18 pt is the status-item convention, and the glyph sits at 16 of those 18 so it has the same
// optical weight as the system items either side of it. The current artwork is a filled
// silhouette whose finest features are the paper's cut lines — 41 px in the 2048 px export, about
// 0.6 px at @2x — with the gap between the scroll and the quill at 131 px, about 2 px. Those sit
// in the same range as the details on the SF Symbols beside it, so the shapes hold up at this
// size without being thickened.
for scale in 1...3 {
    let suffix = scale == 1 ? "" : "@\(scale)x"
    writePNG(
        compose(menuImage, crop: glyph, canvas: 18 * scale, fit: Double(16 * scale)),
        to: resources.appendingPathComponent("MenuBar\(suffix).png")
    )
}
print("    wrote App/Resources/MenuBar{,@2x,@3x}.png")
