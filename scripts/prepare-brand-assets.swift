#!/usr/bin/env swift

import AppKit
import Foundation

let repoRoot = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .deletingLastPathComponent()

let logoSource = repoRoot.appendingPathComponent("Brand/WindowLens_Logo-compressed.png")
let menuBarSource = repoRoot.appendingPathComponent("Brand/WindowLens_MenuBar.png")
let menuBarCropped = repoRoot.appendingPathComponent("Brand/WindowLens_MenuBar-cropped.png")

func cropMenuBarMaster(at url: URL, to destination: URL) -> Bool {
    guard let image = NSImage(contentsOf: url),
          let rep = NSBitmapImageRep(data: image.tiffRepresentation ?? Data()) else {
        return false
    }

    var minX = rep.pixelsWide
    var minY = rep.pixelsHigh
    var maxX = 0
    var maxY = 0

    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            guard luminance > 0.35, alpha > 0.2 else { continue }

            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
    }

    guard maxX > minX, maxY > minY else { return false }

    let padding = Int(Double(max(maxX - minX, maxY - minY)) * 0.12)
    minX = max(0, minX - padding)
    minY = max(0, minY - padding)
    maxX = min(rep.pixelsWide - 1, maxX + padding)
    maxY = min(rep.pixelsHigh - 1, maxY + padding)

    let cropWidth = maxX - minX + 1
    let cropHeight = maxY - minY + 1
    let side = max(cropWidth, cropHeight)
    let centeredX = minX - max(0, (side - cropWidth) / 2)
    let centeredY = minY - max(0, (side - cropHeight) / 2)
    let clampedX = max(0, min(centeredX, rep.pixelsWide - side))
    let clampedY = max(0, min(centeredY, rep.pixelsHigh - side))
    let cropRect = NSRect(
        x: clampedX,
        y: rep.pixelsHigh - clampedY - side,
        width: side,
        height: side
    )

    guard let cgImage = rep.cgImage,
          let croppedCG = cgImage.cropping(to: cropRect) else {
        return false
    }

    let cropped = NSBitmapImageRep(cgImage: croppedCG)
    guard let png = cropped.representation(
        using: NSBitmapImageRep.FileType.png,
        properties: [:]
    ) else { return false }
    do {
        try png.write(to: destination)
        return true
    } catch {
        return false
    }
}
let appIconSet = repoRoot.appendingPathComponent("WindowLens/Resources/Assets.xcassets/AppIcon.appiconset")
let menuBarSet = repoRoot.appendingPathComponent("WindowLens/Resources/Assets.xcassets/MenuBarIcon.imageset")
let aboutLogoSet = repoRoot.appendingPathComponent("WindowLens/Resources/Assets.xcassets/AboutLogo.imageset")

struct IconSize {
    let size: Int
    let scale: Int
    let name: String
}

let appIconSizes: [IconSize] = [
    IconSize(size: 16, scale: 1, name: "icon_16x16"),
    IconSize(size: 16, scale: 2, name: "icon_16x16@2x"),
    IconSize(size: 32, scale: 1, name: "icon_32x32"),
    IconSize(size: 32, scale: 2, name: "icon_32x32@2x"),
    IconSize(size: 128, scale: 1, name: "icon_128x128"),
    IconSize(size: 128, scale: 2, name: "icon_128x128@2x"),
    IconSize(size: 256, scale: 1, name: "icon_256x256"),
    IconSize(size: 256, scale: 2, name: "icon_256x256@2x"),
    IconSize(size: 512, scale: 1, name: "icon_512x512"),
    IconSize(size: 512, scale: 2, name: "icon_512x512@2x"),
]

func loadImage(at url: URL) -> NSImage? {
    guard FileManager.default.fileExists(atPath: url.path) else {
        fputs("Missing file: \(url.path)\n", stderr)
        return nil
    }
    return NSImage(contentsOf: url)
}

func resizedImage(_ image: NSImage, pixelSize: Int) -> NSImage {
    let target = NSSize(width: pixelSize, height: pixelSize)
    let output = NSImage(size: target)
    output.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(
        in: NSRect(origin: .zero, size: target),
        from: NSRect(origin: .zero, size: image.size),
        operation: .copy,
        fraction: 1
    )
    output.unlockFocus()
    return output
}

func writePNG(_ image: NSImage, to url: URL) throws {
    if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        try writePNG(cgImage: cgImage, to: url)
        return
    }

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "prepare-brand-assets", code: 1)
    }
    try png.write(to: url)
}

func writePNG(cgImage: CGImage, to url: URL) throws {
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "prepare-brand-assets", code: 1)
    }
    try png.write(to: url)
}

func makeMenuBarTemplate(from image: NSImage, pixelSize: Int) -> NSImage? {
    let source = resizedImage(image, pixelSize: pixelSize)
    guard let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return nil
    }

    let width = pixelSize
    let height = pixelSize
    var data = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    guard let context = CGContext(
        data: &data,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        return nil
    }

    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    guard let pixelData = context.data else { return nil }
    let pixels = pixelData.bindMemory(to: UInt8.self, capacity: width * height * 4)

    for index in 0..<(width * height) {
        let offset = index * 4
        let alpha = pixels[offset + 3]

        // Strokes are carried primarily in the alpha channel (premultiplied white on black).
        if alpha > 20 {
            pixels[offset] = 0
            pixels[offset + 1] = 0
            pixels[offset + 2] = 0
            pixels[offset + 3] = alpha
        } else {
            pixels[offset] = 0
            pixels[offset + 1] = 0
            pixels[offset + 2] = 0
            pixels[offset + 3] = 0
        }
    }

    guard let output = context.makeImage() else {
        return nil
    }

    return NSImage(cgImage: output, size: NSSize(width: width, height: height))
}

@discardableResult
func runSips(arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    process.arguments = arguments
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

func writeAppIconSet(from logoPath: URL) throws {
    try FileManager.default.createDirectory(at: appIconSet, withIntermediateDirectories: true)

    for entry in appIconSizes {
        let pixelSize = entry.size * entry.scale
        let url = appIconSet.appendingPathComponent("\(entry.name).png")
        guard runSips(arguments: [
            "-z", "\(pixelSize)", "\(pixelSize)",
            logoPath.path,
            "--out", url.path,
        ]) else {
            throw NSError(domain: "prepare-brand-assets", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "sips failed for \(entry.name)",
            ])
        }
        print("  App icon \(entry.name).png (\(pixelSize)px)")
    }

    let contents: [String: Any] = [
        "images": appIconSizes.map { entry in
            [
                "filename": "\(entry.name).png",
                "idiom": "mac",
                "scale": "\(entry.scale)x",
                "size": "\(entry.size)x\(entry.size)",
            ] as [String: Any]
        },
        "info": ["author": "xcode", "version": 1],
    ]

    let data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: appIconSet.appendingPathComponent("Contents.json"))
}

func writeImageSet(
    at folder: URL,
    name: String,
    images: [(filename: String, size: String, scale: String)],
    template: Bool
) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    var properties: [String: Any] = [:]
    if template {
        properties["template-rendering-intent"] = "template"
    }

    var payload: [String: Any] = [
        "images": images.map { image in
            [
                "filename": image.filename,
                "idiom": "mac",
                "scale": image.scale,
                "size": image.size,
            ] as [String: Any]
        },
        "info": ["author": "xcode", "version": 1],
    ]

    if !properties.isEmpty {
        payload["properties"] = properties
    }

    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: folder.appendingPathComponent("Contents.json"))
    print("  \(name) image set")
}

guard let logo = loadImage(at: logoSource) else {
    exit(1)
}

if !cropMenuBarMaster(at: menuBarSource, to: menuBarCropped) {
    fputs("Failed to crop menu bar master\n", stderr)
    exit(1)
}

guard let menuBar = loadImage(at: menuBarCropped) else {
    exit(1)
}

print("Preparing app icons…")
do {
    try writeAppIconSet(from: logoSource)

    print("Preparing menu bar template icon…")
    try FileManager.default.createDirectory(at: menuBarSet, withIntermediateDirectories: true)
    for staleName in ["menubar-22.png", "menubar-22@2x.png"] {
        try? FileManager.default.removeItem(at: menuBarSet.appendingPathComponent(staleName))
    }
    guard let menuBar18 = makeMenuBarTemplate(from: menuBar, pixelSize: 18),
          let menuBar36 = makeMenuBarTemplate(from: menuBar, pixelSize: 36),
          let cg18 = menuBar18.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let cg36 = menuBar36.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw NSError(domain: "prepare-brand-assets", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Failed to convert menu bar icon to template",
        ])
    }

    let menuBar18URL = menuBarSet.appendingPathComponent("menubar.png")
    let menuBar36URL = menuBarSet.appendingPathComponent("menubar@2x.png")
    try writePNG(cgImage: cg18, to: menuBar18URL)
    try writePNG(cgImage: cg36, to: menuBar36URL)
    try writeImageSet(
        at: menuBarSet,
        name: "MenuBarIcon",
        images: [
            (filename: "menubar.png", size: "18x18", scale: "1x"),
            (filename: "menubar@2x.png", size: "18x18", scale: "2x"),
        ],
        template: true
    )

    print("Preparing About logo…")
    try FileManager.default.createDirectory(at: aboutLogoSet, withIntermediateDirectories: true)
    try writePNG(resizedImage(logo, pixelSize: 128), to: aboutLogoSet.appendingPathComponent("about-logo.png"))
    try writePNG(resizedImage(logo, pixelSize: 256), to: aboutLogoSet.appendingPathComponent("about-logo@2x.png"))
    try writeImageSet(
        at: aboutLogoSet,
        name: "AboutLogo",
        images: [
            (filename: "about-logo.png", size: "128x128", scale: "1x"),
            (filename: "about-logo@2x.png", size: "128x128", scale: "2x"),
        ],
        template: false
    )

    let iconsetPath = repoRoot.appendingPathComponent("AppIcon.iconset")
    try? FileManager.default.removeItem(at: iconsetPath)
    try FileManager.default.createDirectory(at: iconsetPath, withIntermediateDirectories: true)

    for entry in appIconSizes {
        let pixelSize = entry.size * entry.scale
        let destination = iconsetPath.appendingPathComponent("\(entry.name).png")
        guard runSips(arguments: [
            "-z", "\(pixelSize)", "\(pixelSize)",
            logoSource.path,
            "--out", destination.path,
        ]) else {
            throw NSError(domain: "prepare-brand-assets", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "sips failed for iconset \(entry.name)",
            ])
        }
    }

    let icnsDestination = repoRoot.appendingPathComponent("AppIcon.icns")
    try? FileManager.default.removeItem(at: icnsDestination)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", "-o", icnsDestination.path, iconsetPath.path]
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        fputs("iconutil failed\n", stderr)
        exit(1)
    }

    try? FileManager.default.removeItem(at: iconsetPath)
    print("  AppIcon.icns")

    print("Done.")
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
