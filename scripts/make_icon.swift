// Makes the app icon from the logo's vector artwork.
//
//   swift scripts/make_icon.swift
//
// reads Assets/Latent.pdf and writes
//
//   Assets/AppIcon.icns   <- every size macOS asks for, 16 to 1024 pixels;
//                            scripts/make_app.sh copies it into the bundle
//   Assets/AppIcon.png    <- 512 pixels, for the README
//
// Run it again whenever the PDF changes, and commit what it writes. Each
// size is drawn from the vector artwork at that size, not scaled down from
// the largest, so the small ones stay as sharp as the pixels allow.
//
// The artwork is placed on Apple's macOS icon grid rather than as drawn:
// on a 1024-pixel canvas the tile is 824 pixels square with 100 clear on
// every side, which leaves room for the Dock's magnification and for the
// tile's shadow. The PDF's tile fills almost the whole page, so it is
// scaled down to fit and given the grid's soft shadow.
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Apple's grid, on a 1024-pixel canvas. The shadow falls 10 pixels down,
/// blurred with a 10-pixel standard deviation, black at 30%. These are
/// measured from the system's own icons (App Store, Calculator and Photos
/// on macOS 15 share them exactly), not guessed.
enum Grid {
    static let canvas: CGFloat = 1024
    static let tile: CGFloat = 824
    static let shadowDrop: CGFloat = 10
    static let shadowSigma: CGFloat = 10
    static let shadowOpacity: CGFloat = 0.3
}

let repository = URL(fileURLWithPath: #filePath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    .standardizedFileURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let assets = repository.appendingPathComponent("Assets", isDirectory: true)
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make_icon: \(message)\n".utf8))
    exit(1)
}

func bitmap(_ side: Int) -> CGContext {
    guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("couldn't make a \(side)-pixel bitmap") }
    context.interpolationQuality = .high
    return context
}

/// The artwork's outline on the page, in page units: where its edges cross
/// half coverage, found from a 2048-pixel rendering (to within a quarter
/// of a pixel of the finished 1024-pixel icon). The page's own margin
/// around the tile is not part of it.
func artworkBounds(of page: CGPDFPage) -> CGRect {
    let box = page.getBoxRect(.mediaBox)
    let side = 2048
    let scale = CGFloat(side) / max(box.width, box.height)
    let context = bitmap(side)
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -box.minX, y: -box.minY)
    context.drawPDFPage(page)
    guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { fail("couldn't read the rendering") }
    var left = side, right = -1, top = side, bottom = -1
    for row in 0..<side {
        for column in 0..<side where pixels[(row * side + column) * 4 + 3] >= 128 {
            left = min(left, column); right = max(right, column)
            top = min(top, row); bottom = max(bottom, row)
        }
    }
    guard right >= left else { fail("the PDF's page is empty") }
    // The bitmap's rows run down from the top; the page's y runs up.
    return CGRect(x: box.minX + CGFloat(left) / scale,
                  y: box.minY + CGFloat(side - 1 - bottom) / scale,
                  width: CGFloat(right - left + 1) / scale,
                  height: CGFloat(bottom - top + 1) / scale)
}

/// The icon at `side` pixels: the artwork centred in the grid's tile, over
/// its shadow.
func icon(_ page: CGPDFPage, artwork: CGRect, side: Int) -> CGImage {
    let pixelsPerPoint = CGFloat(side) / Grid.canvas
    let scale = Grid.tile * pixelsPerPoint / max(artwork.width, artwork.height)
    func drawArtwork(in context: CGContext) {
        context.saveGState()
        context.translateBy(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -artwork.midX, y: -artwork.midY)
        context.drawPDFPage(page)
        context.restoreGState()
    }
    let alone = bitmap(side)
    drawArtwork(in: alone)
    guard let artworkImage = alone.makeImage() else { fail("couldn't render the artwork") }

    // The shadow is the artwork's silhouette: black, at the grid's opacity,
    // blurred and moved down (Core Image's y runs up, so down is negative).
    let canvas = CGRect(x: 0, y: 0, width: side, height: side)
    let silhouette = CIImage(cgImage: artworkImage)
        .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: Grid.shadowOpacity),
        ])
        .applyingGaussianBlur(sigma: Double(Grid.shadowSigma * pixelsPerPoint))
        .transformed(by: CGAffineTransform(translationX: 0, y: -Grid.shadowDrop * pixelsPerPoint))
        .cropped(to: canvas)
    guard let shadow = CIContext().createCGImage(silhouette, from: canvas, format: .RGBA8, colorSpace: sRGB)
    else { fail("couldn't render the shadow") }

    // The artwork is drawn again from the vectors on top, not composited
    // from the bitmap above, so its edges are antialiased only once.
    let finished = bitmap(side)
    finished.draw(shadow, in: canvas)
    drawArtwork(in: finished)
    guard let image = finished.makeImage() else { fail("couldn't finish the \(side)-pixel icon") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("couldn't write \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("couldn't write \(url.path)") }
}

let source = assets.appendingPathComponent("Latent.pdf")
guard let document = CGPDFDocument(source as CFURL), let page = document.page(at: 1) else {
    fail("couldn't open \(source.path)")
}
let artwork = artworkBounds(of: page)

// iconutil wants a folder named .iconset holding these exact file names.
let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("AppIcon-\(ProcessInfo.processInfo.processIdentifier).iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
do {
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
} catch {
    fail("couldn't make \(iconset.path): \(error.localizedDescription)")
}
defer { try? FileManager.default.removeItem(at: iconset) }

var rendered: [Int: CGImage] = [:]
for points in [16, 32, 128, 256, 512] {
    for (density, suffix) in [(1, ""), (2, "@2x")] {
        let side = points * density
        let image = rendered[side] ?? icon(page, artwork: artwork, side: side)
        rendered[side] = image
        writePNG(image, to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}

let icns = assets.appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", icns.path, iconset.path]
do { try iconutil.run() } catch { fail("couldn't run iconutil: \(error.localizedDescription)") }
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fail("iconutil failed") }

writePNG(rendered[512]!, to: assets.appendingPathComponent("AppIcon.png"))
print("Artwork \(Int(artwork.width.rounded())) x \(Int(artwork.height.rounded())) of a \(Int(page.getBoxRect(.mediaBox).width.rounded()))-point page, placed in the grid's \(Int(Grid.tile))-point tile")
print("Wrote \(icns.path) and \(assets.appendingPathComponent("AppIcon.png").path)")
