import Foundation
import CoreML

/// Finds, compiles and caches the Core ML packages bundled with MLKit.
///
/// A `.mlpackage` is source form; Core ML runs `.mlmodelc`, the compiled
/// form. Compiling the 80 MB SAM encoder takes a second or two, so it's
/// done once and cached in Application Support, keyed by the package's
/// size and modification date so a replaced model recompiles.
public enum CoreMLStore {
    public enum StoreError: Error, CustomStringConvertible {
        case modelMissing(String)
        public var description: String {
            switch self {
            case .modelMissing(let n): return "Core ML model '\(n)' is not bundled (see Sources/MLKit/Resources/Models/README.md)"
            }
        }
    }

    static var modelsDirectory: URL? {
        Bundle.latentResources.url(forResource: "Models", withExtension: nil)
    }

    public static func isAvailable(_ name: String) -> Bool {
        guard let dir = modelsDirectory else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(name + ".mlpackage").path)
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
    nonisolated(unsafe) public static var defaultComputeUnits: MLComputeUnits = {
        switch ProcessInfo.processInfo.environment["LATENT_ML_COMPUTE"] {
        case "all": return .all
        case "cpu": return .cpuOnly
        default: return .cpuAndGPU
        }
    }()

    /// Loads `name`.mlpackage, compiling on first use.
    public static func load(_ name: String,
                            computeUnits: MLComputeUnits? = nil) async throws -> MLModel {
        let computeUnits = computeUnits ?? defaultComputeUnits
        guard let dir = modelsDirectory else { throw StoreError.modelMissing(name) }
        let package = dir.appendingPathComponent(name + ".mlpackage")
        guard FileManager.default.fileExists(atPath: package.path) else { throw StoreError.modelMissing(name) }

        // Cache key from the weights file, the part that actually changes.
        let weights = package.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")
        let attrs = (try? FileManager.default.attributesOfItem(atPath: weights.path)) ?? [:]
        let size = (attrs[.size] as? Int) ?? 0
        let mtime = Int((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let compiled = cacheDirectory.appendingPathComponent("\(name)-\(size)-\(mtime).mlmodelc")

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
        guard let dir = modelsDirectory,
              let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
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
