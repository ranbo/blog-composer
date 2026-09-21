// Copyright © 2026 Randy Wilson. All rights reserved.
//
// Builds the BlogComposer app icon from the master artwork in
// Tools/AppIcon-source.png (an antique sepia world globe).
//
// Usage:  swift Tools/MakeAppIcon.swift [source.png] [output-dir]
//
// The source need not be square or tightly cropped: its opaque bounds are
// measured, then centred in a square canvas so nothing is stretched. Writes
// Icons/AppIcon.iconset/, Icons/AppIcon.icns (for an .app bundle) and
// Sources/BlogComposerCore/Resources/AppIcon.png (the Dock icon set at launch).

import AppKit
import Foundation

let fm = FileManager.default
let repoRoot = URL(fileURLWithPath: fm.currentDirectoryPath)
let args = CommandLine.arguments

let sourceURL = URL(fileURLWithPath: args.count > 1 ? args[1] : "Tools/AppIcon-source.png",
                    relativeTo: repoRoot)
let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "Icons", relativeTo: repoRoot)

guard let src = NSImage(contentsOf: sourceURL),
      let srcCG = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(
        Data("error: cannot read artwork at \(sourceURL.path)\n".utf8))
    exit(1)
}

// MARK: - Measure the artwork's opaque bounds

/// Tightest rect containing pixels with alpha above `threshold`.
func opaqueBounds(of image: CGImage, threshold: UInt8 = 24) -> CGRect {
    let w = image.width, h = image.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return CGRect(x: 0, y: 0, width: w, height: h)
    }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h {
        let row = y * w * 4
        for x in 0..<w where buf[row + x * 4 + 3] > threshold {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
    guard maxX >= minX, maxY >= minY else {
        return CGRect(x: 0, y: 0, width: w, height: h)
    }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

let bounds = opaqueBounds(of: srcCG)
guard let trimmed = srcCG.cropping(to: bounds) else {
    FileHandle.standardError.write(Data("error: could not crop artwork\n".utf8))
    exit(1)
}
print("artwork \(srcCG.width)×\(srcCG.height), opaque bounds "
      + "\(Int(bounds.width))×\(Int(bounds.height)) at "
      + "(\(Int(bounds.minX)), \(Int(bounds.minY)))")

// MARK: - Render

/// Draws the trimmed artwork centred, aspect preserved, in a square of `size`px.
func renderPNG(size: Int) -> Data {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("could not create a \(size)px bitmap context")
    }
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)

    let side = CGFloat(size)
    let scale = min(side / CGFloat(trimmed.width), side / CGFloat(trimmed.height))
    let w = CGFloat(trimmed.width) * scale
    let h = CGFloat(trimmed.height) * scale
    ctx.draw(trimmed, in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))

    guard let image = ctx.makeImage() else { fatalError("could not render \(size)px icon") }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(size)px PNG")
    }
    return data
}

// MARK: - Write the iconset, the .icns and the bundled Dock icon

let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(px: Int, name: String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")
]

var rendered: [Int: Data] = [:]
for variant in variants {
    let data = rendered[variant.px] ?? renderPNG(size: variant.px)
    rendered[variant.px] = data
    try data.write(to: iconset.appendingPathComponent(variant.name))
}

let icns = Process()
icns.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
icns.arguments = ["-c", "icns", iconset.path,
                  "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try icns.run()
icns.waitUntilExit()
guard icns.terminationStatus == 0 else { exit(icns.terminationStatus) }

// The app sets its Dock icon from this at launch, so `swift run` shows it too.
let resources = URL(fileURLWithPath: "Sources/BlogComposerCore/Resources",
                    relativeTo: repoRoot)
try fm.createDirectory(at: resources, withIntermediateDirectories: true)
try rendered[1024]!.write(to: resources.appendingPathComponent("AppIcon.png"))

print("wrote \(iconset.path)")
print("wrote \(outDir.appendingPathComponent("AppIcon.icns").path)")
print("wrote \(resources.appendingPathComponent("AppIcon.png").path)")
