import Foundation
import Metal
import simd
import RawCore
import ColorKit
import PixelEngine

// Phase-1 harness:
//   rawhead-cli render <raw-file> [options]
//
// Timing separates three costs that behave very differently in a real
// editing session:
//
//   unpack   — paid once when the image is opened (LibRaw decode)
//   session  — paid once when the image is opened (sensor upload to GPU)
//   render   — paid on EVERY slider drag, zoom, or panel change
//
// Only the last governs whether editing feels responsive.

let args = CommandLine.arguments
guard args.count >= 3, args[1] == "render" else {
    print("""
    Usage:
      rawhead-cli render <path-to-raw-file> [options]

    Options:
      --out <path.png>       write the result as a PNG
      --repeat <N>           render N times, report the average (default 1)
      --viewport <N>         render for an N-pixel long edge (default: full res)
      --region x,y,w,h       full-res render of just that sensor rectangle
                             (the 100%-zoom tile path; overrides --viewport)
      --demosaic <method>    bilinear | rcd (default rcd; full-res only)
      --ev <stops>           exposure adjustment, e.g. -1.5 or 0.7 (default 0)
      --contrast <x>         tone curve contrast (default 1.5)
      --grey <x>             scene-linear value mapped to mid grey (default 0.1845)
      --space <sRGB|p3>      output colour space (default sRGB)

    Examples:
      rawhead-cli render photo.nef --out /tmp/rcd.png --demosaic rcd
      rawhead-cli render photo.nef --out /tmp/bilinear.png --demosaic bilinear
      rawhead-cli render photo.nef --viewport 2560 --repeat 200
    """)
    exit(1)
}

let inputPath = args[2]

func stringArg(_ name: String) -> String? {
    guard let idx = args.firstIndex(of: name), args.count > idx + 1 else { return nil }
    return args[idx + 1]
}
func floatArg(_ name: String, _ fallback: Float) -> Float {
    stringArg(name).flatMap { Float($0) } ?? fallback
}

let outputPath = stringArg("--out")
let repeatCount = max(1, Int(stringArg("--repeat") ?? "1") ?? 1)
let viewportDimension = Int(stringArg("--viewport") ?? "")
let regionValues = stringArg("--region")?.split(separator: ",").compactMap { Int($0) } ?? []
let scale: RenderScale
if regionValues.count == 4 {
    scale = .region(x: regionValues[0], y: regionValues[1],
                    width: regionValues[2], height: regionValues[3])
} else {
    scale = viewportDimension.map { .fitting(maxDimension: $0) } ?? .full
}

let demosaic = DemosaicMethod(rawValue: (stringArg("--demosaic") ?? "rcd").lowercased()) ?? .rcd
let outputSpace: ColorKit.OutputSpace =
    (stringArg("--space")?.lowercased() == "p3") ? .displayP3 : .sRGB

let parameters = EditParameters(
    exposureEV: floatArg("--ev", 0),
    contrast: floatArg("--contrast", 1.5),
    greyPoint: floatArg("--grey", 0.1845),
    demosaic: demosaic,
    outputSpace: outputSpace
)

func formatBytes(_ bytes: Int) -> String {
    String(format: "%.1f MB", Double(bytes) / 1_048_576)
}

do {
    let t0 = Date()
    let file = try RawFile(path: inputPath)
    let t1 = Date()
    print("Opened + unpacked: \(file.summary.cameraMake) \(file.summary.cameraModel), " +
          "\(file.summary.rawWidth)x\(file.summary.rawHeight), " +
          "in \(Int((t1.timeIntervalSince(t0)) * 1000))ms")

    let gpu = try GPUContext()

    let t2 = Date()
    let session = try ImageSession(file: file, gpu: gpu)
    let t3 = Date()
    print(String(format: "Session created in %.1fms", (t3.timeIntervalSince(t2)) * 1000))

    if let matrix = session.cameraToWorkingMatrix {
        // Feeding neutral camera RGB through the matrix must come back
        // neutral. If these three aren't near-identical, the row
        // normalization is wrong and every image carries a colour cast.
        let neutral = matrix * SIMD3<Float>(1, 1, 1)
        print(String(format: "  camera matrix OK — neutral maps to (%.4f, %.4f, %.4f)",
                      neutral.x, neutral.y, neutral.z))
    } else {
        print("  WARNING: no camera colour profile; cannot render")
    }
    print(String(format: "  as-shot WB: %.0fK %+.0f",
                  session.asShotWhiteBalance.temperature,
                  session.asShotWhiteBalance.tint))

    let pipeline = RenderPipeline(gpu: gpu)

    var texture: MTLTexture? = nil
    var info = RenderInfo(outputWidth: 0, outputHeight: 0, binQuads: 1, isFullResolution: true)

    let t4 = Date()
    for _ in 0..<repeatCount {
        texture = try pipeline.render(session, scale: scale, parameters: parameters, info: &info)
    }
    let t5 = Date()

    guard let finalTexture = texture else {
        print("Failed: render produced no texture")
        exit(1)
    }

    let totalRenderMs = (t5.timeIntervalSince(t4)) * 1000
    let perRenderMs = totalRenderMs / Double(repeatCount)

    if repeatCount > 1 {
        print(String(format: "GPU render: %.2fms avg over %d runs (%.0fms total)",
                      perRenderMs, repeatCount, totalRenderMs))
    } else {
        print(String(format: "GPU render: %.2fms", perRenderMs))
    }

    let sensorMP = Double(file.summary.rawWidth * file.summary.rawHeight) / 1_000_000
    let outputMP = Double(info.outputWidth * info.outputHeight) / 1_000_000
    if info.isFullResolution {
        print(String(format: "  path: full resolution, %dx%d (%.1f MP), demosaic: %@",
                      info.outputWidth, info.outputHeight, outputMP,
                      info.demosaicUsed?.rawValue ?? "?"))
        print(String(format: "  covers sensor rect x=%.0f y=%.0f w=%.0f h=%.0f",
                      info.sensorRect.origin.x, info.sensorRect.origin.y,
                      info.sensorRect.width, info.sensorRect.height))
    } else {
        print(String(format: "  path: binned %dx%d quads -> %dx%d (%.1f MP of %.1f MP sensor, %.0f%%)",
                      info.binQuads, info.binQuads,
                      info.outputWidth, info.outputHeight,
                      outputMP, sensorMP, outputMP / sensorMP * 100))
        print("        (binning skips demosaic entirely — --demosaic has no effect here)")
    }
    print("  session holds: \(formatBytes(session.approximateBytesHeld)) of GPU memory")

    if let outputPath {
        try writePNG(texture: finalTexture, to: outputPath)
        print("Wrote \(outputPath)")
    }

    print("Total: \(Int((t5.timeIntervalSince(t0)) * 1000))ms")
} catch {
    print("Failed: \(error)")
    exit(1)
}
