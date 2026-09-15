import Foundation
import ImageIO
import Metal
import simd
import RawCore
import ColorKit
import PixelEngine
import Catalog
import MergeKit

// Phase-1 harness:
//   latent-cli render <raw-file> [options]
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

// `catalog` subcommand: open (or create) the catalog for a folder,
// reconcile it, and list what it holds. The command-line way to watch
// Phase 2 work before there's a grid to look at.
if args.count >= 3, args[1] == "catalog" {
    let folder = URL(fileURLWithPath: args[2])
    let includeSubfolders = args.contains("--include-subfolders")
    do {
        let catalog = try Catalog.open(at: folder)
        if includeSubfolders { try await catalog.setDefaultSubfolderMode(.included) }
        let report = try await catalog.reconcile()
        print("Reconciled \(folder.path): \(report)")
        for undecided in report.undecidedSubfolders {
            print("  subfolder '\(undecided)' needs a decision (included / independent); " +
                  "pass --include-subfolders to include all")
        }
        for failure in report.failures {
            print("  FAILED \(failure.relPath): \(failure.reason)")
        }
        let thumbs = try await catalog.generateMissingThumbnails()
        print("Thumbnails: \(thumbs)")
        for failure in thumbs.failures {
            print("  FAILED \(failure.relPath): \(failure.reason)")
        }
        let images = try await catalog.allImages()
        print("\(images.count) images:")
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        for image in images {
            let when = image.captureTime.map {
                dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval($0)))
            } ?? "no date"
            let stars = String(repeating: "★", count: image.rating)
                      + String(repeating: "☆", count: 5 - image.rating)
            let keywords = try await catalog.keywords(forImageID: image.id ?? -1)
            print(String(format: "  %@  %@  %@  %dx%d  ISO %@ %@ f/%@ %@mm  %@%@",
                         stars, when, image.camera ?? "?",
                         image.width ?? 0, image.height ?? 0,
                         image.iso.map(String.init) ?? "?",
                         image.shutter.map { $0 >= 1 ? String(format: "%.0fs", $0) : "1/\(Int((1 / $0).rounded()))" } ?? "?",
                         image.aperture.map { String(format: "%.1f", $0) } ?? "?",
                         image.focal.map { String(format: "%.0f", $0) } ?? "?",
                         image.relPath,
                         keywords.isEmpty ? "" : "  [" + keywords.joined(separator: ", ") + "]"))
        }
    } catch {
        print("Failed: \(error)")
        exit(1)
    }
    exit(0)
}

// `merge-hdr` subcommand: analyse a bracket, merge it and write the DNG,
// printing what the analysis found and what each stage cost. The command-
// line way to watch Photo Merge's HDR engine (docs/PhotoMerge.md section 3)
// before the app has a dialog for it.
//
// With --preview it writes the dialog's preview as a JPEG instead of
// merging, and times it twice: the first preview and one more, which is
// what every option change in the dialog costs.
if args.count >= 2, args[1] == "merge-hdr" {
    var positional: [String] = []
    var referenceOverride: Int?
    var deghost = DeghostAmount.none
    var autoAlign = true
    var previewOutput: URL?
    var previewLongEdge = 1024
    var overlay = false
    var autoSettings = false
    var index = 2
    while index < args.count {
        if args[index] == "--reference", index + 1 < args.count, let n = Int(args[index + 1]) {
            referenceOverride = n
            index += 2
        } else if args[index] == "--preview", index + 1 < args.count {
            previewOutput = URL(fileURLWithPath: args[index + 1])
            index += 2
        } else if args[index] == "--long-edge", index + 1 < args.count, let n = Int(args[index + 1]), n > 0 {
            previewLongEdge = n
            index += 2
        } else if args[index] == "--overlay" {
            overlay = true
            index += 1
        } else if args[index] == "--auto-settings" {
            autoSettings = true
            index += 1
        } else if args[index] == "--no-align" {
            autoAlign = false
            index += 1
        } else if args[index] == "--deghost", index + 1 < args.count {
            guard let amount = DeghostAmount(rawValue: args[index + 1]) else {
                print("--deghost takes none, low, medium or high")
                exit(1)
            }
            deghost = amount
            index += 2
        } else {
            positional.append(args[index])
            index += 1
        }
    }
    // With --preview there is no DNG: every path given is a photo.
    guard positional.count >= (previewOutput == nil ? 3 : 2) else {
        print("Usage: latent-cli merge-hdr <output.dng> <raw> <raw> [...] [--reference N] [--no-align] "
              + "[--deghost none|low|medium|high] [--auto-settings]\n"
              + "       latent-cli merge-hdr --preview <out.jpg> <raw> <raw> [...] [--long-edge N] [--overlay] "
              + "[--reference N] [--no-align] [--deghost none|low|medium|high]")
        exit(1)
    }
    let output = URL(fileURLWithPath: previewOutput == nil ? positional[0] : "")
    let inputs = (previewOutput == nil ? positional.dropFirst() : positional[...]).map { URL(fileURLWithPath: $0) }

    /// `text` cut or padded with spaces to `width` characters (String(format:)
    /// can't pad a %@).
    func column(_ text: String, _ width: Int) -> String {
        text.count >= width ? String(text.prefix(width)) : text.padding(toLength: width, withPad: " ", startingAt: 0)
    }
    func printReport(_ report: HDRMergeReport, title: String) {
        print("  \(title):")
        for stage in report.stages {
            print("    " + column(stage.name, 40) + String(format: "%7.3f s", stage.seconds))
        }
        print("    " + column("total", 40) + String(format: "%7.3f s", report.totalSeconds))
    }
    /// "1/250" for short shutter speeds, "2.5s" for long ones.
    func shutterText(_ seconds: Double) -> String {
        guard seconds > 0 else { return "?" }
        return seconds >= 1 ? String(format: "%gs", seconds) : "1/\(Int((1 / seconds).rounded()))"
    }
    /// `url` relative to `folder`, as a merge recipe records its sources.
    func relativePath(of url: URL, from folder: URL) -> String {
        let target = url.standardizedFileURL.pathComponents, base = folder.standardizedFileURL.pathComponents
        var shared = 0
        while shared < min(target.count, base.count), target[shared] == base[shared] { shared += 1 }
        return (Array(repeating: "..", count: base.count - shared) + target[shared...]).joined(separator: "/")
    }

    do {
        let gpu = try GPUContext()
        // A preview wants the frames kept while they are read for the analysis.
        let merger = HDRMerger(gpu: gpu, keepsPreviewFrames: previewOutput != nil)
        let options = HDRMergeOptions(referenceIndex: referenceOverride, deghost: deghost, autoAlign: autoAlign)
        let (analysis, analysisReport) = try await merger.analyseWithReport(inputs, options: options)
        let reference = referenceOverride ?? analysis.referenceIndex
        // What Auto Align will do with each frame for the reference used.
        let plan = analysis.alignment?.plan(reference: reference)
        print(String(format: "Analysed %d photos in %.2f s", analysis.frames.count, analysisReport.totalSeconds))
        print("   #  " + column("File", 28) + " Shutter    ISO     f  EXIF EV  Measured EV  Clipped  Alignment")
        for (i, frame) in analysis.frames.enumerated() {
            let alignment: String
            switch plan?.frames[i] {
            case nil: alignment = "off"
            case .reference?: alignment = "reference"
            case .aligned(let shift)?: alignment = String(format: "moved %.2f px", shift)
            case .unaligned?: alignment = "not aligned"
            case .leftOut?: alignment = "left out"
            }
            print(String(format: "  %2d", i) + (i == reference ? "* " : "  ") + column(frame.url.lastPathComponent, 28)
                  + " " + column(shutterText(frame.exposureSeconds), 7)
                  + String(format: " %6.0f %5.1f  %+7.2f  %+11.2f  %6.2f%%  ", frame.iso, frame.aperture,
                           frame.exifRelativeEV, frame.relativeEV, frame.clippedFraction * 100) + alignment)
        }
        if let alignment = analysis.alignment {
            // Each neighbour pair as the aligner judged it.
            for (k, link) in alignment.links.enumerated() {
                let (a, b) = (alignment.chainOrder[k], alignment.chainOrder[k + 1])
                let verdict = link.accepted ? "accepted" : "rejected (\(link.rejection.map { String(describing: $0) } ?? "?"))"
                // Where the link moves the frame's centre, and how it turns it.
                let centre = SIMD2(Double(analysis.width), Double(analysis.height)) / 2
                let moved = Homography.apply(link.estimatedHomography, centre) - centre
                print(String(format: "  align %d -> %d: centre (%+.2f, %+.2f) px, rotation %+.3f deg, corners %.2f px, "
                             + "NCC %.3f, overlap %.3f, scale %+.3f%%, ",
                             a, b, moved.x, moved.y, Homography.rotationDegrees(link.estimatedHomography, at: centre),
                             link.maxCornerShift, link.ncc, link.overlapFraction, link.scaleChange * 100)
                      + verdict)
            }
        }
        print(String(format: "  * reference. Range %.2f EV, %d x %d px, DNG about %.0f MB",
                     analysis.exposureRangeStops, analysis.width, analysis.height,
                     Double(analysis.estimatedOutputBytes) / 1_000_000))
        if analysis.warnings.isEmpty { print("Warnings: none") }
        for warning in analysis.warnings {
            switch warning {
            case .framesLookMisaligned(let pixels):
                print(String(format: "Warning: the frames look misaligned by up to %.1f px (Auto Align is off)", pixels))
            case .frameCouldNotBeAligned(let frame, let leftOut):
                print("Warning: photo \(frame) couldn't be aligned; " + (leftOut ? "it is left out" : "merged where it is"))
            case .exposureMetadataDisagrees(let frame, let exif, let measured):
                print(String(format: "Warning: photo %d measures %+.2f EV but its EXIF says %+.2f EV; using the measurement",
                             frame, measured, exif))
            case .smallExposureRange(let stops):
                print(String(format: "Warning: the bracket spans only %.2f EV", stops))
            }
        }

        if let previewOutput {
            let started = ContinuousClock.now
            let (image, report) = try await merger.previewWithReport(analysis, options: options,
                                                                     longEdge: previewLongEdge,
                                                                     showDeghostOverlay: overlay)
            let first = ContinuousClock.now - started
            // Once more with the frames already kept and the GPU's pipelines
            // built: what each option change in the dialog costs.
            let again = ContinuousClock.now
            _ = try await merger.preview(analysis, options: options, longEdge: previewLongEdge,
                                         showDeghostOverlay: overlay)
            let second = ContinuousClock.now - again
            guard let destination = CGImageDestinationCreateWithURL(previewOutput as CFURL, "public.jpeg" as CFString,
                                                                    1, nil) else {
                print("Failed: can't write \(previewOutput.path)")
                exit(1)
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                print("Failed: can't write \(previewOutput.path)")
                exit(1)
            }
            print("Timings:")
            printReport(analysisReport, title: "analysis")
            printReport(report, title: "first preview")
            func seconds(_ duration: Duration) -> Double {
                Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
            }
            if !report.ghostMaskedFractions.isEmpty {
                let shares = zip(report.ghostFlaggedFractions, report.ghostMaskedFractions).enumerated()
                    .map { i, share in
                        i == reference ? "\(i): reference"
                            : String(format: "%d: %.2f%% moving, %.2f%% left out", i, share.0 * 100, share.1 * 100)
                    }
                print("Deghosting (\(deghost.rawValue)) at preview size: " + shares.joined(separator: "; "))
            }
            print(String(format: "Preview %d x %d px: first %.3f s, again %.3f s", image.width, image.height,
                         seconds(first), seconds(second)))
            print("Wrote \(previewOutput.path)")
            exit(0)
        }

        var sources: [MergeRecipe.Source] = []
        for frame in analysis.frames {
            let captured = try RawFile(path: frame.url.path, metadataOnly: true).summary.captureTime
            sources.append(MergeRecipe.Source(
                path: relativePath(of: frame.url, from: output.deletingLastPathComponent()),
                hash: FileHash.hexString(try FileHash.xxh64(ofFileAt: frame.url)),
                captureTime: Int64(captured.timeIntervalSince1970)))
        }
        let (result, mergeReport) = try await merger.mergeWithReport(
            analysis, options: options,
            sources: sources, to: output,
            prepareSidecar: { _ in }, progress: { _ in })
        print("Timings:")
        printReport(analysisReport, title: "analysis")
        printReport(mergeReport, title: "merge")
        if !mergeReport.ghostMaskedFractions.isEmpty {
            let shares = zip(mergeReport.ghostFlaggedFractions, mergeReport.ghostMaskedFractions).enumerated()
                .map { i, share in
                    i == reference ? "\(i): reference"
                        : String(format: "%d: %.2f%% moving, %.2f%% left out", i, share.0 * 100, share.1 * 100)
                }
            print("Deghosting (\(deghost.rawValue)): " + shares.joined(separator: "; "))
        }
        let peak = max(analysisReport.peakGPUBytes, mergeReport.peakGPUBytes)
        print(String(format: "Peak GPU memory: %.2f GB (device allocations while merging)", Double(peak) / 1_073_741_824))
        print(String(format: "Wrote %@ (%.1f MB, BaselineExposure %+.2f, clip level %g)", result.url.path as NSString,
                     Double(result.byteCount) / 1_000_000, result.baselineExposure, result.recipe.clipLevel))
        if autoSettings {
            // What ⌘U makes of the result, as the app's Auto Settings stores it.
            let edit = try HDRAutoSettings.edit(forPhotoAt: result.url, gpu: gpu)
            let wb = edit.suggestion.whiteBalance.map { String(format: ", white balance %.0f K tint %+.0f", $0.temperature, $0.tint) } ?? ""
            print(String(format: "Auto Settings: exposure %+.2f EV, contrast %.2f", edit.suggestion.exposureEV,
                         edit.suggestion.contrast) + wb)
            let folder = result.url.deletingLastPathComponent()
            let root = FolderAccess.hasCatalog(folder) ? folder : FolderAccess.owningCatalog(of: folder)?.root
            if let root, let json = edit.editStackJSON {
                // Catalogued like any new file, then given the edit through
                // the catalog, which writes it into the result's sidecar.
                let catalog = try Catalog.open(at: root)
                _ = try await catalog.reconcile()
                let relPath = String(result.url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
                guard let id = try await catalog.image(forRelPath: relPath)?.id else {
                    print("Failed: \(relPath) isn't in the catalog of \(root.path) after reading the folder")
                    exit(1)
                }
                try await catalog.setEditStack(json, schemaVersion: EditStack.schemaVersion,
                                               processVersion: EditStack.processVersion, forImageID: id)
                print("Wrote the Auto Settings edit to \(relPath)'s sidecar in the catalog of \(root.path)")
            } else if root == nil {
                print("No catalog in \(folder.path): the Auto Settings edit isn't stored")
            } else {
                print("Auto Adjust leaves the result at its defaults: no edit to store")
            }
        }
    } catch let error as HDRMergeError {
        print("Failed: \(error.errorDescription ?? String(describing: error))")
        exit(1)
    } catch {
        print("Failed: \(error)")
        exit(1)
    }
    exit(0)
}

guard args.count >= 3, args[1] == "render" else {
    print("""
    Usage:
      latent-cli render <path-to-raw-file> [options]
      latent-cli catalog <folder> [--include-subfolders]
      latent-cli merge-hdr <output.dng> <raw> <raw> [...] [--reference N]
                           [--no-align] [--deghost none|low|medium|high]
                           [--auto-settings]
      latent-cli merge-hdr --preview <out.jpg> <raw> <raw> [...] [--long-edge N]
                           [--overlay] [--reference N] [--no-align]
                           [--deghost none|low|medium|high]

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
      --sharpen <amount>     unsharp mask amount 0-2 (default 0 = off)
      --no-lens              disable profile lens corrections
      --denoise <strength>   luminance+colour noise reduction 0-1 (default 0)

    Examples:
      latent-cli render photo.nef --out /tmp/rcd.png --demosaic rcd
      latent-cli render photo.nef --out /tmp/bilinear.png --demosaic bilinear
      latent-cli render photo.nef --viewport 2560 --repeat 200
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
    outputSpace: outputSpace,
    denoiseLuminance: floatArg("--denoise", 0),
    denoiseColor: floatArg("--denoise", 0),
    sharpenAmount: floatArg("--sharpen", 0),
    lensDistortion: !args.contains("--no-lens"),
    lensTCA: !args.contains("--no-lens"),
    lensVignetting: !args.contains("--no-lens")
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
          "in \(Int((t1.timeIntervalSince(t0)) * 1000))ms " +
          "(decoder: \(file.decodedInService ? "XPC service" : "in-process"), " +
          "service \(RawDecoderXPC.isServiceAvailable ? "available" : "absent"))")
    let area = file.summary.activeArea
    print("  sensor readout \(area.fullWidth)x\(area.fullHeight), active area at (\(area.left), \(area.top))")
    switch file.summary.sourceKind {
    case .bayer:
        print("  source: Bayer mosaic")
    case .linearRGB:
        // Already demosaiced: a Photo Merge result or another LinearRaw DNG.
        let merge = file.summary.mergeInfo.map {
            String(format: "merge %@, clip level %g, lens %@, baseline shift %d", $0.kind, $0.clipLevel,
                   $0.lensApplied ? "applied" : "not applied", $0.baselineShift)
        } ?? "no merge recipe"
        print(String(format: "  source: linear RGB, BaselineExposure %+.2f EV, %@",
                     file.summary.baselineExposure, merge))
    }

    let li = file.summary.lens
    print(String(format: "  lens: name='%@' makernotes='%@' make='%@' id=%llu nikonID=%d type=%d " +
                 "range %.0f-%.0fmm f/%.1f-%.1f crop=%.2f",
                 file.summary.lensModel, li.makerNotesName, li.make, li.makerLensID,
                 Int(li.nikonLensID), Int(li.nikonLensType), li.minFocal, li.maxFocal,
                 li.maxApertureAtMinFocal, li.maxApertureAtMaxFocal, li.cropFactor))

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
    if let lens = session.lensCorrection {
        print("  lens profile: \(lens.profileName) (lensfun \(lens.databaseVersion)), " +
              "distortion \(lens.distortion != nil ? "yes" : "no"), CA \(lens.tca != nil ? "yes" : "no"), " +
              "vignetting \(lens.vignetting != nil ? "yes" : "no")" +
              String(format: ", autoscale %.4f, crop ratio %.3f", lens.autoScale, lens.cropRatio))
    } else if session.lensCorrectionAlreadyApplied {
        print("  lens profile: none (the merge already applied lens corrections)")
    } else {
        print("  lens profile: none")
    }

    let pipeline = RenderPipeline(gpu: gpu)

    if args.contains("--auto") {
        var current = parameters
        current.whiteBalance = session.asShotWhiteBalance
        let s = try AutoAdjust.suggest(for: session, pipeline: pipeline, gpu: gpu, current: current)
        print(String(format: "Auto suggests: %+.2f EV, contrast %.2f, WB %@",
                     s.exposureEV, s.contrast,
                     s.whiteBalance.map { String(format: "%.0fK %+.0f", $0.temperature, $0.tint) } ?? "unchanged"))
    }

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
                      info.demosaicUsed?.rawValue ?? "none (linear source)"))
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
    if session.sourceKind == .linearRGB {
        // What Photo Merge's size rule budgets per pixel (bytesPerEditPixel):
        // the plane plus every texture this render left in the session.
        print(String(format: "  linear source: %.1f bytes of GPU memory per source pixel after this render",
                     Double(session.approximateBytesHeld) / Double(file.summary.rawWidth * file.summary.rawHeight)))
    }

    if repeatCount > 1 {
        // With --repeat, runs 2..N hit the stage cache: same white balance,
        // same region, so only the colour stage runs. Show what that costs
        // on its own — it's the slider-drag number for exposure and tone.
        var cachedInfo = info
        let c0 = Date()
        texture = try pipeline.render(session, scale: scale, parameters: parameters, info: &cachedInfo)
        let c1 = Date()
        print(String(format: "  colour stage alone (demosaic cached: %@): %.2fms",
                      cachedInfo.demosaicWasCached ? "yes" : "no",
                      c1.timeIntervalSince(c0) * 1000))
        // And the honest uncached number, by changing white balance so the
        // demosaic must re-run.
        var wbParams = parameters
        wbParams.whiteBalance = ColorKit.WhiteBalance(temperature: 5000, tint: 0)
        let u0 = Date()
        texture = try pipeline.render(session, scale: scale, parameters: wbParams, info: &cachedInfo)
        let u1 = Date()
        print(String(format: "  full render, demosaic cached: %@: %.2fms",
                      cachedInfo.demosaicWasCached ? "yes" : "no",
                      u1.timeIntervalSince(u0) * 1000))
    }

    if let outputPath {
        let w0 = Date()
        let ext = (outputPath as NSString).pathExtension.lowercased()
        let format: ExportSettings.Format = ext == "jpg" || ext == "jpeg" ? .jpeg
            : ext == "heic" ? .heic : ext == "tif" || ext == "tiff" ? .tiff : .png
        try Exporter(gpu: gpu).write(finalTexture, to: URL(fileURLWithPath: outputPath),
                                     settings: ExportSettings(format: format), colorSpace: outputSpace)
        print(String(format: "Wrote %@ in %.0fms (GPU pack + %@ encode)", outputPath,
                     Date().timeIntervalSince(w0) * 1000, format.rawValue))
    }

    print("Total: \(Int((t5.timeIntervalSince(t0)) * 1000))ms")
} catch {
    print("Failed: \(error)")
    exit(1)
}
