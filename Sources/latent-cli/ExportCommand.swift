import Foundation
import PixelEngine
import ColorKit
import Catalog
import MLKit

/// `latent-cli export`: renders photos with their saved edits, without the
/// app, through the same `ExportWorker` and batch planner the export sheet
/// uses, so a file written here is the file the app would write with the
/// same settings.
///
/// Each photo's edit comes from its folder's catalog when the folder has
/// one (opened as it is, never reconciled), else from its sidecar in
/// `_latent/xmp/`, else it is exported at Latent's defaults
/// (`HeadlessSources`). Settings start from an export preset's JSON when
/// one is given, and flags override it.
enum ExportCommand {
    static let usage = """
    Usage: latent-cli export <folder | file…> --out-dir <folder> [options]

      --out-dir <folder>       where the files go (made if missing); required
      --preset <file.json>     start from an export preset saved as JSON
      --format <name>          jpeg | heic | tiff | png | avif | jxl (default jpeg)
      --quality <0-100>        JPEG, HEIC, AVIF and JPEG XL quality (default 92)
      --long-edge <pixels>     resize to this long edge, never enlarging (default full size)
      --space <name>           srgb | p3 | adobergb (default srgb)
      --template <text>        file naming, e.g. "{date}-{name}" (default {name})
      --on-conflict <policy>   number | skip | replace, for names already taken (default number)
      --no-metadata            write pixels only: no camera, date, keywords or rating
      --jobs <n|auto>          photos exported at once (default auto: what this Mac can take,
                               at most the fastest measured count)
      --dry-run                list what would be written and write nothing
    """

    /// Why the command line can't be used; written as a string literal.
    struct UsageError: Error, CustomStringConvertible, ExpressibleByStringInterpolation {
        let description: String
        init(stringLiteral value: String) { description = value }
    }

    struct Options {
        var inputs: [URL] = []
        var outDir: URL?
        var presetPath: URL?
        var format: ExportSettings.Format?
        var quality: Float?
        var longEdge: Int?
        var space: String?
        var template: String?
        var collision: ExportNaming.Collision?
        var noMetadata = false
        var dryRun = false
        /// Photos at once; nil for automatic (`ExportConcurrency`).
        var jobs: Int?
    }

    /// The command line after `export`, or why it can't be used.
    static func parse(_ args: [String]) -> Result<Options, UsageError> {
        var options = Options()
        var index = 0
        func value(_ flag: String) -> String? {
            guard index + 1 < args.count else { return nil }
            index += 1
            return args[index]
        }
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--out-dir":
                guard let v = value(arg) else { return .failure("--out-dir needs a folder") }
                options.outDir = URL(fileURLWithPath: v, isDirectory: true)
            case "--preset":
                guard let v = value(arg) else { return .failure("--preset needs a JSON file") }
                options.presetPath = URL(fileURLWithPath: v)
            case "--format":
                guard let v = value(arg), let format = formatNamed(v) else {
                    return .failure("--format takes jpeg, heic, tiff, png, avif or jxl")
                }
                options.format = format
            case "--quality":
                guard let v = value(arg), let q = Float(v), q >= 0, q <= 100 else {
                    return .failure("--quality takes a number from 0 to 100")
                }
                options.quality = q / 100
            case "--long-edge":
                guard let v = value(arg), let n = Int(v), n > 0, n <= ExportSizing.maximumEdge else {
                    return .failure("--long-edge takes a size in pixels, 1 to \(ExportSizing.maximumEdge)")
                }
                options.longEdge = n
            case "--space":
                guard let v = value(arg)?.lowercased(), ["srgb", "p3", "adobergb"].contains(v) else {
                    return .failure("--space takes srgb, p3 or adobergb")
                }
                options.space = v
            case "--template":
                guard let v = value(arg), !v.isEmpty else { return .failure("--template needs a naming template") }
                options.template = v
            case "--on-conflict":
                switch value(arg) {
                case "number": options.collision = .addNumber
                case "skip": options.collision = .skip
                case "replace": options.collision = .replace
                default: return .failure("--on-conflict takes number, skip or replace")
                }
            case "--no-metadata":
                options.noMetadata = true
            case "--jobs":
                guard let v = value(arg) else { return .failure("--jobs takes a number or auto") }
                if v == "auto" {
                    options.jobs = nil
                } else if let n = Int(v), n >= 1, n <= ExportConcurrency.hardCap {
                    options.jobs = n
                } else {
                    return .failure("--jobs takes auto or a number from 1 to \(ExportConcurrency.hardCap)")
                }
            case "--dry-run":
                options.dryRun = true
            default:
                if arg.hasPrefix("--") { return .failure("unknown option \(arg)") }
                options.inputs.append(URL(fileURLWithPath: arg))
            }
            index += 1
        }
        guard !options.inputs.isEmpty else { return .failure("name a folder or some photos to export") }
        guard options.outDir != nil else { return .failure("--out-dir is required") }
        return .success(options)
    }

    static func formatNamed(_ name: String) -> ExportSettings.Format? {
        switch name.lowercased() {
        case "jpg", "jpeg": .jpeg
        case "heic", "heif": .heic
        case "tif", "tiff": .tiff
        case "png": .png
        case "avif": .avif
        case "jxl", "jpegxl": .jxl
        default: nil
        }
    }

    /// Runs the command; the process's exit status.
    static func run(_ args: [String]) async -> Int32 {
        let options: Options
        switch parse(args) {
        case .success(let parsed): options = parsed
        case .failure(let message):
            print("export: \(message)\n\n\(usage)")
            return 2
        }
        var preset = CLIExportPreset()
        if let path = options.presetPath {
            do {
                preset = try CLIExportPreset.load(from: path)
            } catch {
                print("export: couldn't read the preset \(path.path): \(error)")
                return 1
            }
            guard preset.fileKind == "image" else {
                print("export: the preset writes \(preset.fileKind == "dng" ? "DNGs" : "originals"); "
                      + "latent-cli export writes images only. Use the app for that preset.")
                return 1
            }
        }
        preset.apply(options)
        guard preset.format.isAvailable else {
            print("export: " + (preset.format.unavailableReason ?? "\(preset.format.displayName) can't be written here"))
            return 1
        }
        let settings: ExportSettings
        do {
            settings = try preset.settings()
        } catch {
            print("export: \(error)")
            return 1
        }
        let outDir = options.outDir!.standardizedFileURL

        let resolved: HeadlessSources.Resolved
        do {
            resolved = try await HeadlessSources.resolve(options.inputs)
        } catch {
            print("export: \(error)")
            return 1
        }
        for note in resolved.notes { print("Note: \(note)") }
        guard !resolved.sources.isEmpty else {
            print("export: no photos to export")
            return 1
        }
        let sources = resolved.sources
        let catalogName = sources[0].root.lastPathComponent
        let planOptions = preset.planOptions(catalogName: catalogName)
        var plan = ExportBatchPlanner.plan(sources.map(\.record), into: outDir, options: planOptions,
                                           probe: options.dryRun && !FileManager.default.fileExists(atPath: outDir.path)
                                               ? .nothingOnDisk : .system)
        guard plan.unknownTokens.isEmpty else {
            print("export: the template has tokens Latent doesn't know: " + plan.unknownTokens.joined(separator: ", "))
            print("Known tokens: " + ExportNaming.tokens.map(\.token).joined(separator: " "))
            return 2
        }
        print("Exporting \(sources.count) photo\(sources.count == 1 ? "" : "s") as \(preset.summary) into \(outDir.path)")

        if options.dryRun {
            for output in plan.outputs {
                let source = sources[output.index]
                let action: String
                switch output.action {
                case .write: action = "write"
                case .replace: action = "replace"
                case .skip: action = "skip (already there)"
                case .fail(let reason): action = "fail: \(reason)"
                }
                print("  \(source.record.relPath) -> \(output.relativePath(to: outDir))  [\(action); edit from \(source.origin.description)]")
            }
            print("Dry run: \(plan.count(.write)) to write, \(plan.count(.replace)) to replace, "
                  + "\(plan.count(.skip)) to skip, \(plan.failures.count) failing; nothing written")
            return plan.failures.isEmpty ? 0 : 1
        }

        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            print("export: couldn't create \(outDir.path): \(error)")
            return 1
        }
        let gpu: GPUContext
        do {
            gpu = try GPUContext()
        } catch {
            print("export: no Metal device: \(error)")
            return 1
        }

        // Several photos at once, as the app's export does (ExportPipeline):
        // names are settled and results printed in order, one photo after
        // another; only the render and write overlap.
        let sourceMegapixels = sources.map {
            ExportConcurrency.estimatedMegapixels(width: $0.record.width, height: $0.record.height,
                                                  fileBytes: $0.record.size)
        }.max() ?? 24
        let limit = ExportConcurrency.limit(machine: .current(device: gpu.device), sourceMegapixels: sourceMegapixels,
                                            outputMegapixels: preset.outputMegapixels(source: sourceMegapixels))
        let workers = ExportConcurrency.resolve(choice: options.jobs ?? ExportConcurrency.automaticChoice,
                                                 limit: limit)
        print("Photos at once: \(workers.workers) (this Mac can take up to \(limit) of these)"
              + (workers.clamped ? "; --jobs \(options.jobs ?? 0) is more than that" : ""))

        let started = Date()
        var written = 0, skipped = 0, failed = 0
        var nextIndex = 0
        await ExportPipeline.run(
            workers: workers.workers,
            next: { () async -> ExportPipeline.Step<CLIPhoto, CLIOutcome>? in
                guard nextIndex < plan.outputs.count else { return nil }
                let index = nextIndex
                nextIndex += 1
                let source = sources[plan.outputs[index].index]
                let name = source.record.relPath
                let output = plan.recheck(index)
                if planOptions.makesFolders, case .write = output.action {
                    try? FileManager.default.createDirectory(at: output.url.deletingLastPathComponent(),
                                                             withIntermediateDirectories: true)
                }
                if let json = source.editStackJSON, (try? EditStack.decode(json: json))?.modules.aidenoise != nil,
                   !AIDenoiser.isAvailable {
                    print("  warning \(name): AI Denoise is in the edit but its model isn't on this Mac; exported without it")
                }
                let photo = CLIPhoto(index: index, name: name, output: output, started: Date(),
                                     request: preset.request(for: source, destination: output.url, settings: settings))
                switch output.action {
                case .write, .replace: return .run(photo)
                case .skip: return .done(CLIOutcome(photo: photo, result: .failure(SkipFile())))
                case .fail(let reason): return .done(CLIOutcome(photo: photo, result: .failure(PlanFailure(reason: reason))))
                }
            },
            work: { photo in
                do {
                    return CLIOutcome(photo: photo, result: .success(try await ExportWorker.export(photo.request, gpu: gpu)))
                } catch {
                    return CLIOutcome(photo: photo, result: .failure(error))
                }
            },
            retry: { outcome in
                // A file that appeared under the name while this one
                // rendered: settled again by the policy, as the app does.
                guard case .failure(let error) = outcome.result, error is SafeFileWriter.DestinationExists,
                      outcome.photo.attempts < 3 else { return nil }
                var photo = outcome.photo
                photo.output = plan.recheck(photo.index)
                photo.attempts += 1
                switch photo.output.action {
                case .write, .replace:
                    photo.request = preset.request(for: sources[plan.outputs[photo.index].index],
                                                   destination: photo.output.url, settings: settings)
                    return .run(photo)
                case .skip: return .done(CLIOutcome(photo: photo, result: .failure(SkipFile())))
                case .fail(let reason): return .done(CLIOutcome(photo: photo, result: .failure(PlanFailure(reason: reason))))
                }
            },
            commit: { outcome in
                let name = outcome.photo.name, output = outcome.photo.output
                switch outcome.result {
                case .success(let result):
                    written += 1
                    let seconds = String(format: "%.1f", Date().timeIntervalSince(outcome.photo.started))
                    print("  ok      \(name) -> \(output.relativePath(to: outDir))  "
                          + "(\(result.pixelWidth)x\(result.pixelHeight), \(seconds) s)")
                    if !result.maskSubstitutions.isEmpty {
                        print("  note    \(name): made with stand-ins for " + result.maskSubstitutions.joined(separator: ", "))
                    }
                case .failure(let error) where error is SkipFile:
                    skipped += 1
                    print("  skip    \(name): \(output.url.lastPathComponent) is already there")
                case .failure(let error):
                    failed += 1
                    print("  FAILED  \(name): \(error)")
                }
            })
        print(String(format: "%d exported, %d skipped, %d failed in %.1f s", written, skipped, failed,
                     Date().timeIntervalSince(started)))
        return failed == 0 ? 0 : 1
    }

    private struct SkipFile: Error {}

    /// One photo on its way through the pipeline.
    private struct CLIPhoto: Sendable {
        var index: Int
        var name: String
        var output: ExportBatchPlan.Output
        var started: Date
        var request: ExportWorker.Request
        var attempts = 1
    }

    private struct CLIOutcome: Sendable {
        var photo: CLIPhoto
        var result: Result<ExportWorker.Outcome, Error>
    }
    private struct PlanFailure: Error, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }
}

extension HeadlessSource.Origin: CustomStringConvertible {
    public var description: String {
        switch self {
        case .catalog: "catalog"
        case .sidecar: "sidecar"
        case .none: "none (defaults)"
        }
    }
}

/// The parts of the app's export preset (`ExportPreset` in latent-app)
/// that a headless export uses, read from the same JSON keys, leniently:
/// a key that is missing or can't be read keeps the app's default. The
/// file may be a preset or a named preset (`{"name": …, "preset": {…}}`).
struct CLIExportPreset {
    var format: ExportSettings.Format = .jpeg
    var quality: Float = 0.92
    var colorSpaceIsP3 = false
    var profileKind: ExportColorProfile.Kind?
    var profilePath: String?
    var resize = false
    var maxLongEdge = 2048
    var sizing: ExportSizing?
    var template = ExportNaming.defaultTemplate
    var sequenceStart = 1
    var sequenceStep = 1
    var sequencePadding = 3
    var letterCase: ExportNaming.LetterCase = .unchanged
    var uppercaseExtension = false
    var collision: ExportNaming.Collision = .addNumber
    var dateSubfolders = false
    var subfolder = ""
    var includeMetadata = true
    var includeLocation = false
    var metadataLevel: ExportMetadataLevel = .all
    var hdrGainMap = false
    var hdrMaximizeCompatibility = true
    var watermark: ExportWatermark?
    var ppi: Double?
    var sharpening: OutputSharpening?
    var sizeLimitBytes: Int?
    var tiffBitDepth = 16
    var tiffCompression: TIFFCompression = .none
    var fileKind = "image"

    static func load(from url: URL) throws -> CLIExportPreset {
        let data = try Data(contentsOf: url)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PresetError("it isn't a JSON object")
        }
        if let inner = object["preset"] as? [String: Any] { object = inner }
        return CLIExportPreset(object)
    }

    struct PresetError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    init() {}

    init(_ o: [String: Any]) {
        func string(_ key: String) -> String? { o[key] as? String }
        func bool(_ key: String) -> Bool? { o[key] as? Bool }
        func int(_ key: String) -> Int? { (o[key] as? NSNumber)?.intValue }
        func double(_ key: String) -> Double? { (o[key] as? NSNumber)?.doubleValue }
        func decoded<T: Decodable>(_ key: String, as type: T.Type) -> T? {
            guard let value = o[key], JSONSerialization.isValidJSONObject([value]),
                  let data = try? JSONSerialization.data(withJSONObject: [value]) else { return nil }
            return (try? JSONDecoder().decode([T].self, from: data))?.first
        }
        format = string("format").flatMap(ExportSettings.Format.init(rawValue:)) ?? format
        quality = double("quality").map { Float($0) } ?? quality
        colorSpaceIsP3 = bool("colorSpaceIsP3") ?? colorSpaceIsP3
        if let profile = o["profile"] as? [String: Any] {
            profileKind = (profile["kind"] as? String).flatMap(ExportColorProfile.Kind.init(rawValue:))
            profilePath = profile["path"] as? String
        }
        resize = bool("resize") ?? resize
        maxLongEdge = int("maxLongEdge") ?? maxLongEdge
        template = string("template") ?? template
        if let suffix = string("suffix"), !suffix.isEmpty, !template.contains(suffix) { template += suffix }
        sequenceStart = int("sequenceStart") ?? sequenceStart
        sequenceStep = int("sequenceStep") ?? sequenceStep
        sequencePadding = int("sequencePadding") ?? sequencePadding
        letterCase = string("letterCase").flatMap(ExportNaming.LetterCase.init(rawValue:)) ?? letterCase
        uppercaseExtension = bool("uppercaseExtension") ?? uppercaseExtension
        collision = string("collision").flatMap(ExportNaming.Collision.init(rawValue:)) ?? collision
        dateSubfolders = bool("dateSubfolders") ?? dateSubfolders
        includeMetadata = bool("includeMetadata") ?? includeMetadata
        includeLocation = bool("includeLocation") ?? includeLocation
        metadataLevel = string("metadataLevel").flatMap(ExportMetadataLevel.init(rawValue:)) ?? metadataLevel
        hdrGainMap = bool("hdrGainMap") ?? hdrGainMap
        hdrMaximizeCompatibility = bool("hdrMaximizeCompatibility") ?? hdrMaximizeCompatibility
        if bool("watermarkEnabled") == true, let mark = decoded("watermark", as: ExportWatermark.self), !mark.isEmpty {
            watermark = mark
        }
        if bool("ppiEnabled") == true { ppi = Double(min(max(int("ppi") ?? 300, 1), 9999)) }
        if bool("sharpenEnabled") == true {
            sharpening = OutputSharpening(
                medium: string("sharpenMedium").flatMap(OutputSharpening.Medium.init(rawValue:)) ?? .screen,
                strength: string("sharpenStrength").flatMap(OutputSharpening.Strength.init(rawValue:)) ?? .standard)
        }
        let mode = string("sizingMode").flatMap(ExportSizing.Mode.init(rawValue:)) ?? .longEdge
        let dontEnlarge = bool("dontEnlarge") ?? true
        if resize, mode != .longEdge || !dontEnlarge {
            sizing = ExportSizing(mode: mode, longEdge: maxLongEdge, shortEdge: int("shortEdge") ?? 1365,
                                  width: int("boxWidth") ?? 2048, height: int("boxHeight") ?? 2048,
                                  megapixels: double("megapixels") ?? 12, percentage: double("percentage") ?? 50,
                                  dontEnlarge: dontEnlarge)
        }
        if bool("sizeLimitEnabled") == true { sizeLimitBytes = max(int("sizeLimitKB") ?? 500, 1) * 1024 }
        tiffBitDepth = int("tiffBitDepth") == 8 ? 8 : 16
        tiffCompression = string("tiffCompression").flatMap(TIFFCompression.init(rawValue:)) ?? tiffCompression
        subfolder = string("subfolder") ?? subfolder
        fileKind = string("fileKind") ?? fileKind
        // Same folder as original has no meaning for an export that is
        // told where to go; the files go into --out-dir.
    }

    /// The flags given, over the preset.
    mutating func apply(_ options: ExportCommand.Options) {
        if let format = options.format { self.format = format }
        if let quality = options.quality { self.quality = quality }
        if let longEdge = options.longEdge {
            resize = true
            maxLongEdge = longEdge
            sizing = nil
        }
        if let space = options.space {
            switch space {
            case "p3": colorSpaceIsP3 = true; profileKind = nil
            case "adobergb": colorSpaceIsP3 = false; profileKind = .adobeRGB
            default: colorSpaceIsP3 = false; profileKind = nil
            }
        }
        if let template = options.template { self.template = template }
        if let collision = options.collision { self.collision = collision }
        if options.noMetadata { includeMetadata = false }
    }

    var colorSpace: ColorKit.OutputSpace { colorSpaceIsP3 ? .displayP3 : .sRGB }

    func settings() throws -> ExportSettings {
        var s = ExportSettings(format: format, quality: min(max(quality, 0), 1), hdrGainMap: hdrGainMap,
                               watermark: watermark)
        s.hdrFull = !hdrMaximizeCompatibility
        switch profileKind {
        case .adobeRGB: s.colorProfile = .adobeRGB
        case .proPhoto: s.colorProfile = .proPhoto
        case .icc:
            guard let profilePath, let data = try? Data(contentsOf: URL(fileURLWithPath: profilePath)) else {
                throw PresetError("the preset's ICC profile \(profilePath ?? "") can't be read")
            }
            s.colorProfile = ExportColorProfile(kind: .icc, name: (profilePath as NSString).lastPathComponent,
                                                iccData: data)
        case .sRGB, .displayP3, nil: break
        }
        s.ppi = ppi
        s.outputSharpening = sharpening
        s.tiffBitDepth = tiffBitDepth
        s.tiffCompression = tiffCompression
        return s
    }

    var fileExtension: String {
        uppercaseExtension ? format.fileExtension.uppercased() : format.fileExtension
    }

    func planOptions(catalogName: String) -> ExportBatchPlanner.Options {
        var options = ExportBatchPlanner.Options(template: template, start: sequenceStart, step: sequenceStep,
                                                 padding: sequencePadding, letterCase: letterCase,
                                                 fileExtension: fileExtension, collision: collision,
                                                 dateSubfolders: dateSubfolders, catalogName: catalogName)
        options.subfolder = subfolder
        return options
    }

    /// The megapixels of a file made from a photo of `source` megapixels
    /// (3:2 assumed), for the photos-at-once limit.
    func outputMegapixels(source: Double) -> Double {
        let height = (source * 1_000_000 / 1.5).squareRoot(), width = height * 1.5
        let edge = sizing.map { $0.targetLongEdge(width: Int(width), height: Int(height)) } ?? (resize ? maxLongEdge : nil)
        guard let edge, Double(edge) < width else { return source }
        return Double(edge) * Double(edge) / 1.5 / 1_000_000
    }

    func request(for source: HeadlessSource, destination: URL, settings: ExportSettings) -> ExportWorker.Request {
        let record = source.record
        var request = ExportWorker.Request(
            sourceURL: source.fileURL, destinationURL: destination, editStackJSON: source.editStackJSON,
            userRotation: record.userRotation, settings: settings, colorSpace: colorSpace,
            maxLongEdge: resize ? maxLongEdge : nil,
            keywords: includeMetadata ? source.keywords : [],
            rating: includeMetadata ? record.rating : 0,
            includeMetadata: includeMetadata,
            includeLocation: includeMetadata && includeLocation,
            replacesExisting: collision == .replace)
        if includeMetadata {
            request.descriptive = ExportDescription(title: record.title, caption: record.caption,
                                                    creator: record.creator, copyright: record.copyright)
        }
        request.sizing = sizing
        request.sizeLimitBytes = format.supportsQuality ? sizeLimitBytes : nil
        request.metadataLevel = metadataLevel
        return request
    }

    /// "JPEG, quality 92, sRGB, 2048 px", for the first line printed.
    var summary: String {
        var parts = [format.displayName]
        if format.supportsQuality { parts.append("quality \(Int((quality * 100).rounded()))") }
        switch profileKind {
        case .adobeRGB: parts.append("Adobe RGB")
        case .proPhoto: parts.append("ProPhoto RGB")
        case .icc: parts.append("ICC profile")
        default: parts.append(colorSpaceIsP3 ? "Display P3" : "sRGB")
        }
        parts.append(resize ? "\(maxLongEdge) px" : "full size")
        return parts.joined(separator: ", ")
    }
}
