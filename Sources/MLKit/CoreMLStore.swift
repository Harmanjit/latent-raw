import Foundation
import CoreML

/// Finds, compiles and caches the Core ML packages bundled with MLKit.
///
/// A `.mlpackage` is source form; Core ML runs `.mlmodelc`, the compiled
/// form. Compiling the 80 MB SAM encoder takes a second or two, so it's
/// done once and cached in Application Support. A package loaded through
/// its manifest is keyed by its content hash; the name-only loader the
/// denoiser still uses keys by the weights file's size and modification
/// date. Either way a replaced model recompiles.
public enum CoreMLStore {
    public enum StoreError: Error, CustomStringConvertible {
        case modelMissing(String)
        /// A catalogue row's package: listed, not installed, so no hash to key its compiled copy by.
        case noChecksum(String)
        public var description: String {
            switch self {
            case .modelMissing(let n): return "Core ML model '\(n)' is not bundled (see Sources/MLKit/Resources/Models/README.md)"
            case .noChecksum(let n): return "Core ML package '\(n)' has no checksum in its manifest, so it is not installed"
            }
        }
    }

    /// The bundled packages, their manifests and the catalogue.
    public static var modelsDirectory: URL? {
        Bundle.latentResources.url(forResource: "Models", withExtension: nil)
    }

    /// The rows Settings › AI › Models offers with a source link but no
    /// package (docs/Retouch.md §5); nil when the bundle has no Models folder.
    public static var catalogueURL: URL? { modelsDirectory?.appendingPathComponent("ModelCatalog.json") }

    /// Where imported models live, one folder per model id with the
    /// manifest and its packages inside (`ModelImporter`; docs/Retouch.md
    /// §2 A). Kept out of the app bundle so the app itself stays small
    /// and a model can be added or removed without reinstalling.
    public static var externalModelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("latent/models", isDirectory: true)
    }

    /// The one package still looked for flat in `externalModelsDirectory`
    /// (`<name>.mlpackage` with no folder or manifest): the width-64
    /// denoiser the dormant download path once put there. Everything else
    /// in that directory is a model folder the registry lists.
    static let legacyFlatPackages: Set<String> = ["NAFNet_SIDD_width64"]

    /// The package for `name`: bundled first, then the flat legacy layout
    /// for the one name that may use it.
    static func packageURL(_ name: String) -> URL? {
        let file = name + ".mlpackage"
        if let dir = modelsDirectory {
            let bundled = dir.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
        guard legacyFlatPackages.contains(name) else { return nil }
        let external = externalModelsDirectory.appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: external.path) ? external : nil
    }

    public static func isAvailable(_ name: String) -> Bool {
        packageURL(name) != nil
    }

    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("latent/mlmodels", isDirectory: true)
        // Reuse the pre-rename app's compiled models rather than recompiling.
        let old = base.appendingPathComponent("rawhead/mlmodels", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: old.path) {
            try? fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: old, to: dir)
        }
        return dir
    }

    /// Which processors Core ML may use.
    ///
    /// Not `.all`, deliberately. `.all` admits the Neural Engine, and on
    /// macOS 15.7 Core ML's ANE compiler (Espresso e5rt, which runs
    /// in-process at model load) hangs indefinitely on both SAM 2 and
    /// SegFormer — seen as a process stuck at 0% CPU inside
    /// e5rt_e5_compiler_compile_from_ir_program, intermittently for SAM 2
    /// and every time for SegFormer. Hugging Face's own SAM 2 demo pins
    /// `.cpuAndGPU` for, presumably, the same reason. The GPU runs these
    /// models fast enough (SegFormer ~260 ms, SAM 2 clicks ~40 ms), and
    /// a hang is not a trade worth making for a few tens of milliseconds.
    /// LATENT_ML_COMPUTE=all opts back in for testing on newer systems.
    public static let computePreferenceKey = "latent.mlCompute"

    /// Environment first (for tests and experiments), then the preference
    /// the Preferences window writes, then the safe default.
    public static var defaultComputeUnits: MLComputeUnits {
        let choice = ProcessInfo.processInfo.environment["LATENT_ML_COMPUTE"]
            ?? UserDefaults.standard.string(forKey: computePreferenceKey)
        switch choice {
        case "all": return .all
        case "cpu": return .cpuOnly
        default: return .cpuAndGPU
        }
    }

    /// Loads `name`.mlpackage, compiling on first use.
    public static func load(_ name: String,
                            computeUnits: MLComputeUnits? = nil) async throws -> MLModel {
        let computeUnits = computeUnits ?? defaultComputeUnits
        guard let package = packageURL(name) else { throw StoreError.modelMissing(name) }

        // Cache key from the weights file, the part that actually changes.
        let weights = package.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")
        let attrs = (try? FileManager.default.attributesOfItem(atPath: weights.path)) ?? [:]
        let size = (attrs[.size] as? Int) ?? 0
        let mtime = Int((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        return try await load(package: package, cacheKey: "\(name)-\(size)-\(mtime).mlmodelc",
                              computeUnits: computeUnits)
    }

    /// Compiles and loads one package of `manifest` from `directory`
    /// (docs/Retouch.md §2 A). Cache key
    /// "<manifest.id>-<package.name>-<sha256.prefix(16)>.mlmodelc": the
    /// content hash, so a replaced package recompiles and a package copied
    /// elsewhere does not. Older "<id>-<name>-*" entries are deleted first;
    /// each model keeps one compiled copy.
    public static func load(_ package: ModelManifest.Package, of manifest: ModelManifest, at directory: URL,
                            computeUnits: MLComputeUnits) async throws -> MLModel {
        guard let sha256 = package.sha256 else { throw StoreError.noChecksum(package.name) }
        let url = directory.appendingPathComponent(package.name)
        guard FileManager.default.fileExists(atPath: url.path) else { throw StoreError.modelMissing(package.name) }
        let prefix = "\(manifest.id)-\(package.name)-"
        let key = prefix + String(sha256.prefix(16)) + ".mlmodelc"
        let fm = FileManager.default
        let stale = ((try? fm.contentsOfDirectory(atPath: cacheDirectory.path)) ?? [])
            .filter { $0.hasPrefix(prefix) && $0 != key }
        for entry in stale { try? fm.removeItem(at: cacheDirectory.appendingPathComponent(entry)) }
        return try await load(package: url, cacheKey: key, computeUnits: computeUnits)
    }

    /// The compile-once-and-load step both loaders share.
    private static func load(package: URL, cacheKey: String, computeUnits: MLComputeUnits) async throws -> MLModel {
        let compiled = cacheDirectory.appendingPathComponent(cacheKey)
        if !FileManager.default.fileExists(atPath: compiled.path) {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let temp = try await MLModel.compileModel(at: package)
            if FileManager.default.fileExists(atPath: compiled.path) {
                try? FileManager.default.removeItem(at: compiled)
            }
            try FileManager.default.moveItem(at: temp, to: compiled)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        return try MLModel(contentsOf: compiled, configuration: configuration)
    }

    /// Bundled JSON next to a model (class labels).
    public static func json<T: Decodable>(_ fileName: String, as type: T.Type) -> T? {
        json(fileName, in: nil, as: type)
    }

    /// JSON beside a model: `directory` first (an imported model's folder),
    /// then the bundled Models directory.
    public static func json<T: Decodable>(_ fileName: String, in directory: URL?, as type: T.Type) -> T? {
        for dir in [directory, modelsDirectory].compactMap({ $0 }) {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)) else { continue }
            return try? JSONDecoder().decode(type, from: data)
        }
        return nil
    }
}

// MARK: - Image helpers shared by the models

enum MLImage {
    /// Draws `image` stretched into a BGRA pixel buffer of `width x height`.
    /// Stretching (not letterboxing) is what these networks were trained
    /// and evaluated with; the mask is un-stretched on the way out simply
    /// by resampling it to the image's aspect ratio.
    static func pixelBuffer(from image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                      kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &buffer) == kCVReturnSuccess,
              let pb = buffer else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pb
    }
}

extension MLMultiArray {
    /// Reads a float16 or float32 array as Floats, in memory order.
    func floats() -> [Float] {
        let n = count
        var out = [Float](repeating: 0, count: n)
        switch dataType {
        case .float32:
            let p = dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<n { out[i] = p[i] }
        case .float16:
            let p = dataPointer.assumingMemoryBound(to: Float16.self)
            for i in 0..<n { out[i] = Float(p[i]) }
        case .double:
            let p = dataPointer.assumingMemoryBound(to: Double.self)
            for i in 0..<n { out[i] = Float(p[i]) }
        default:
            for i in 0..<n { out[i] = self[i].floatValue }
        }
        return out
    }
}

extension Bundle {
    /// The resource bundle for this module, found the way a shipped app
    /// needs it. SwiftPM's generated `Bundle.module` looks only in the app
    /// bundle's root and in a hard-coded `.build/` path, so an app built by
    /// scripts/make_app.sh (resources in Contents/Resources, per macOS
    /// convention) crashed at launch once the build directory was gone.
    /// Check Contents/Resources first; `Bundle.module` still serves
    /// `swift run` and `swift test`.
    static let latentResources: Bundle = {
        let name = "latent_MLKit.bundle"
        if let url = Bundle.main.resourceURL?.appendingPathComponent(name),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()
}
