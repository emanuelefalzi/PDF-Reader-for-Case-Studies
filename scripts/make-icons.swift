#!/usr/bin/env swift
// Generates the master images for AppIcon and ChatLogo from logo/E.png.
// Used by scripts/make-icons.sh (SPEC §10.1). It has no external
// dependencies: only AppKit/CoreGraphics.
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: make-icons.swift <source.png> <outDir> <cropX,cropY,cropW,cropH>\n".data(using: .utf8)!)
    exit(1)
}
let sourcePath = args[1]
let outDir = args[2]
let cropParts = args[3].split(separator: ",").compactMap { CGFloat(Double($0) ?? -1) }
guard cropParts.count == 4 else {
    FileHandle.standardError.write("invalid crop rect\n".data(using: .utf8)!)
    exit(1)
}
let cropRectTopLeft = CGRect(x: cropParts[0], y: cropParts[1], width: cropParts[2], height: cropParts[3])

let sourceURL = URL(fileURLWithPath: sourcePath)
guard let sourceImage = NSImage(contentsOf: sourceURL),
      let sourceCG = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("cannot read \(sourcePath)\n".data(using: .utf8)!)
    exit(1)
}
let srcW = sourceCG.width
let srcH = sourceCG.height

func writePNG(_ cg: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("cannot encode PNG for \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? data.write(to: URL(fileURLWithPath: path))
}

// CGImage has its origin at the bottom left; the crop rectangle passed in is
// instead expressed in "screen" coordinates (origin at the top left), as
// one would read the image by eye.
func cropRectInCGSpace(_ topLeftRect: CGRect, imageHeight: Int) -> CGRect {
    let flippedY = CGFloat(imageHeight) - topLeftRect.origin.y - topLeftRect.height
    return CGRect(x: topLeftRect.origin.x, y: flippedY, width: topLeftRect.width, height: topLeftRect.height)
}

/// Finds the bounding box of the non-transparent pixels (alpha > threshold) inside `rect`.
func alphaBoundingBox(of cg: CGImage, within rect: CGRect) -> CGRect {
    let x0 = max(0, Int(rect.minX)), y0 = max(0, Int(rect.minY))
    let x1 = min(cg.width, Int(rect.maxX)), y1 = min(cg.height, Int(rect.maxY))
    let w = x1 - x0, h = y1 - y0
    guard w > 0, h > 0 else { return rect }
    var raw = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &raw, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                               space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return rect }
    ctx.draw(cg, in: CGRect(x: -x0, y: -(cg.height - y1), width: cg.width, height: cg.height))
    var minX = w, minY = h, maxX = 0, maxY = 0
    for row in 0..<h {
        for col in 0..<w {
            let alpha = raw[(row * w + col) * 4 + 3]
            if alpha > 10 {
                if col < minX { minX = col }
                if col > maxX { maxX = col }
                if row < minY { minY = row }
                if row > maxY { maxY = row }
            }
        }
    }
    guard maxX >= minX, maxY >= minY else { return rect }
    // converts back to absolute CG coordinates (origin at the bottom left)
    let absMinX = x0 + minX
    let absMaxX = x0 + maxX
    let absMinYFromTop = y0 + minY
    let absMaxYFromTop = y0 + maxY
    let cgY0 = cg.height - absMaxYFromTop - 1
    let cgY1 = cg.height - absMinYFromTop - 1
    return CGRect(x: absMinX, y: cgY0, width: absMaxX - absMinX + 1, height: cgY1 - cgY0 + 1)
}

func squarePadded(_ cg: CGImage, from box: CGRect, marginFraction: CGFloat = 0.06) -> CGImage {
    let side = max(box.width, box.height) * (1 + marginFraction * 2)
    let cx = box.midX, cy = box.midY
    let canvas = CGRect(x: 0, y: 0, width: side, height: side)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
                         space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.clear(canvas)
    let dest = CGRect(x: side / 2 - cx, y: side / 2 - cy, width: CGFloat(cg.width), height: CGFloat(cg.height))
    ctx.draw(cg, in: dest)
    return ctx.makeImage()!
}

func compositeOnWhiteRoundedSquare(_ cg: CGImage, canvasSize: CGFloat = 1024, paddingFraction: CGFloat = 0.10, cornerFraction: CGFloat = 0.22) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: Int(canvasSize), height: Int(canvasSize), bitsPerComponent: 8, bytesPerRow: 0,
                         space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let full = CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
    ctx.clear(full)
    let corner = canvasSize * cornerFraction
    let path = CGPath(roundedRect: full, cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.addPath(path)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillPath()

    let pad = canvasSize * paddingFraction
    let logoAvailable = canvasSize - pad * 2
    // preserves the logo's aspect ratio inside the available area
    let logoAspect = CGFloat(cg.width) / CGFloat(cg.height)
    var logoW = logoAvailable, logoH = logoAvailable
    if logoAspect > 1 { logoH = logoAvailable / logoAspect } else { logoW = logoAvailable * logoAspect }
    let logoRect = CGRect(x: (canvasSize - logoW) / 2, y: (canvasSize - logoH) / 2, width: logoW, height: logoH)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.draw(cg, in: logoRect)
    ctx.restoreGState()
    return ctx.makeImage()!
}

// 1. Crop of the EF monogram (rectangle passed on the command line).
let cropCG = cropRectInCGSpace(cropRectTopLeft, imageHeight: srcH)
guard let monogramCropped = sourceCG.cropping(to: cropCG) else {
    FileHandle.standardError.write("monogram crop failed\n".data(using: .utf8)!)
    exit(1)
}
let monogramBox = alphaBoundingBox(of: monogramCropped, within: CGRect(x: 0, y: 0, width: monogramCropped.width, height: monogramCropped.height))
let monogramSquare = squarePadded(monogramCropped, from: monogramBox)
writePNG(monogramSquare, to: "\(outDir)/monogram_master.png")

// 2. Whole logo (alpha bbox over the whole image) composited on a rounded white square.
let fullBox = alphaBoundingBox(of: sourceCG, within: CGRect(x: 0, y: 0, width: srcW, height: srcH))
guard let fullCropped = sourceCG.cropping(to: fullBox) else {
    FileHandle.standardError.write("whole-logo crop failed\n".data(using: .utf8)!)
    exit(1)
}
let largeMaster = compositeOnWhiteRoundedSquare(fullCropped)
writePNG(largeMaster, to: "\(outDir)/large_master.png")

print("OK: monogram_master.png (\(monogramSquare.width)x\(monogramSquare.height)), large_master.png (\(largeMaster.width)x\(largeMaster.height))")
