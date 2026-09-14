import Foundation
import Metal
import RawCore

public enum GPUContextError: Error, CustomStringConvertible {
    case noMetalDevice
    case commandQueueCreationFailed
    case shaderLibraryNotFound
    case missingShaderFunction(String)

    public var description: String {
        switch self {
        case .noMetalDevice:
            return "No Metal device found (should be unreachable on Apple Silicon)."
        case .commandQueueCreationFailed:
            return "Failed to create a Metal command queue."
        case .shaderLibraryNotFound:
            return "No compiled Metal library or bundled .metal sources found in the PixelEngine resource bundle."
        case .missingShaderFunction(let name):
            return "Metal function '\(name)' not found in the shader library."
        }
    }
}

/// Owns the Metal device, command queue and pipeline states. One instance
/// lives for the app's lifetime; there is no per-image device setup.
///
/// Deployment target: Latent must run on both macOS 15 (Sequoia) and
/// macOS 26 (Tahoe). Metal 4 exists only on Tahoe, so this class targets
/// **Metal 3** as its baseline. Metal-4-only capabilities are optional fast
/// paths only, gated with `if #available(macOS 26, *)` at the call site.
/// Safe to share across actors: every stored property is a `let`, and
/// Metal's device, command queue and pipeline states are documented as
/// thread-safe. This is the one place in the codebase asserting something
/// the compiler can't check, so it stays narrow — if GPUContext ever gains
/// mutable state, this conformance has to go.
public final class GPUContext: @unchecked Sendable {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    let library: MTLLibrary

    // Pipeline states are built once at startup, not per frame.
    let whiteBalanceBlackLevelPSO: MTLComputePipelineState
    let demosaicBilinearPSO: MTLComputePipelineState
    let demosaicBinnedPSO: MTLComputePipelineState
    let colorAndTonePSO: MTLComputePipelineState
    let presentPSO: MTLComputePipelineState
    let histogramPSO: MTLComputePipelineState
    let waveformPSO: MTLComputePipelineState
    let vectorscopePSO: MTLComputePipelineState
    let denoisePSO: MTLComputePipelineState
    let sharpenBlurHPSO: MTLComputePipelineState
    let sharpenBlurVPSO: MTLComputePipelineState
    let sharpenApplyPSO: MTLComputePipelineState
    let lensCorrectPSO: MTLComputePipelineState
    let packForExportPSO: MTLComputePipelineState
    let exportSampleLinearPSO: MTLComputePipelineState
    let exportResampleRowsPSO: MTLComputePipelineState
    let exportResampleColumnsPSO: MTLComputePipelineState
    let exportGainMapPSO: MTLComputePipelineState
    let healStatsPSO: MTLComputePipelineState
    let healApplyPSO: MTLComputePipelineState
    let lcPreparePSO: MTLComputePipelineState
    let lcDownsamplePSO: MTLComputePipelineState
    let lcBlurHPSO: MTLComputePipelineState
    let lcBlurVPSO: MTLComputePipelineState
    let lcApplyPSO: MTLComputePipelineState
    let aiDenoiseBlendPSO: MTLComputePipelineState

    // RCD demosaic, six passes (see RCD.metal).
    let rcdDirectionsVHPSO: MTLComputePipelineState
    let rcdLowPassPSO: MTLComputePipelineState
    let rcdGreenPSO: MTLComputePipelineState
    let rcdDiagonalStatsPSO: MTLComputePipelineState
    let rcdDirectionsPQPSO: MTLComputePipelineState
    let rcdRedBlueAtOppositePSO: MTLComputePipelineState
    let rcdRedBlueAtGreenPSO: MTLComputePipelineState

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw GPUContextError.noMetalDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw GPUContextError.commandQueueCreationFailed
        }
        let library = try GPUContext.loadShaderLibrary(device: device)

        // Captures only the locals `device` and `library`, never `self` —
        // Swift forbids touching self until every property is initialized.
        func makePipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw GPUContextError.missingShaderFunction(name)
            }
            return try device.makeComputePipelineState(function: function)
        }
        let whiteBalancePSO = try makePipeline("blackLevelAndWhiteBalance")
        let bilinearPSO = try makePipeline("demosaicBilinear")
        let binnedPSO = try makePipeline("demosaicBinned")
        let colorPSO = try makePipeline("colorAndTone")
        let presentPipeline = try makePipeline("presentToScreen")
        let histogramPipeline = try makePipeline("computeHistogram")
        let waveformPipeline = try makePipeline("computeWaveform")
        let vectorscopePipeline = try makePipeline("computeVectorscope")
        let denoisePipeline = try makePipeline("denoiseBilateral")
        let blurHPipeline = try makePipeline("sharpenBlurH")
        let blurVPipeline = try makePipeline("sharpenBlurV")
        let sharpenPipeline = try makePipeline("sharpenApply")
        let lensPipeline = try makePipeline("lensCorrect")
        let packPipeline = try makePipeline("packForExport")
        let sampleLinearPipeline = try makePipeline("exportSampleLinear")
        let resampleRowsPipeline = try makePipeline("exportResampleRows")
        let resampleColumnsPipeline = try makePipeline("exportResampleColumns")
        let gainMapPipeline = try makePipeline("exportGainMap")
        let healStatsPipeline = try makePipeline("healStats")
        let healApplyPipeline = try makePipeline("healApply")
        let lcPrepare = try makePipeline("lcPrepare")
        let lcDownsample = try makePipeline("lcDownsample")
        let lcBlurH = try makePipeline("lcBlurH")
        let lcBlurV = try makePipeline("lcBlurV")
        let lcApply = try makePipeline("lcApply")
        let aiBlend = try makePipeline("aiDenoiseBlend")
        let vhPipeline = try makePipeline("rcdDirectionsVH")
        let lowPassPipeline = try makePipeline("rcdLowPass")
        let greenPipeline = try makePipeline("rcdGreen")
        let diagonalPipeline = try makePipeline("rcdDiagonalStats")
        let pqPipeline = try makePipeline("rcdDirectionsPQ")
        let oppositePipeline = try makePipeline("rcdRedBlueAtOpposite")
        let atGreenPipeline = try makePipeline("rcdRedBlueAtGreen")

        self.device = device
        self.commandQueue = queue
        self.library = library
        self.whiteBalanceBlackLevelPSO = whiteBalancePSO
        self.demosaicBilinearPSO = bilinearPSO
        self.demosaicBinnedPSO = binnedPSO
        self.colorAndTonePSO = colorPSO
        self.presentPSO = presentPipeline
        self.histogramPSO = histogramPipeline
        self.waveformPSO = waveformPipeline
        self.vectorscopePSO = vectorscopePipeline
        self.denoisePSO = denoisePipeline
        self.sharpenBlurHPSO = blurHPipeline
        self.sharpenBlurVPSO = blurVPipeline
        self.sharpenApplyPSO = sharpenPipeline
        self.lensCorrectPSO = lensPipeline
        self.packForExportPSO = packPipeline
        self.exportSampleLinearPSO = sampleLinearPipeline
        self.exportResampleRowsPSO = resampleRowsPipeline
        self.exportResampleColumnsPSO = resampleColumnsPipeline
        self.exportGainMapPSO = gainMapPipeline
        self.healStatsPSO = healStatsPipeline
        self.healApplyPSO = healApplyPipeline
        self.lcPreparePSO = lcPrepare
        self.lcDownsamplePSO = lcDownsample
        self.lcBlurHPSO = lcBlurH
        self.lcBlurVPSO = lcBlurV
        self.lcApplyPSO = lcApply
        self.aiDenoiseBlendPSO = aiBlend
        self.rcdDirectionsVHPSO = vhPipeline
        self.rcdLowPassPSO = lowPassPipeline
        self.rcdGreenPSO = greenPipeline
        self.rcdDiagonalStatsPSO = diagonalPipeline
        self.rcdDirectionsPQPSO = pqPipeline
        self.rcdRedBlueAtOppositePSO = oppositePipeline
        self.rcdRedBlueAtGreenPSO = atGreenPipeline
    }

    /// Loads the shader library, preferring the precompiled
    /// `default.metallib` and falling back to compiling the bundled `.metal`
    /// sources at runtime (which `swift build` on the command line needs).
    ///
    /// Runtime compilation can't resolve `#include "Common.h"` between
    /// separate source strings, so the fallback inlines Common.h once and
    /// strips the include lines from each kernel file.
    private static func loadShaderLibrary(device: MTLDevice) throws -> MTLLibrary {
        if let precompiled = try? device.makeDefaultLibrary(bundle: .latentResources) {
            return precompiled
        }

        let bundle = Bundle.latentResources
        func resourceURL(_ name: String, _ ext: String) -> URL? {
            bundle.url(forResource: name, withExtension: ext)
                ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "Shaders")
        }

        guard let headerURL = resourceURL("Common", "h") else {
            throw GPUContextError.shaderLibraryNotFound
        }
        // Every kernel source file must be listed here, or its functions
        // won't exist in the runtime-compiled library.
        let kernelNames = ["WhiteBalance", "Demosaic", "DemosaicBinned",
                            "ColorPipeline", "Present", "Histogram", "Scopes", "Detail", "LensCorrect", "Export", "RCD", "Heal", "LocalContrast", "AIDenoise"]
        let kernelURLs = try kernelNames.map { name -> URL in
            guard let url = resourceURL(name, "metal") else {
                throw GPUContextError.shaderLibraryNotFound
            }
            return url
        }

        let header = try String(contentsOf: headerURL, encoding: .utf8)
        let kernels = try kernelURLs.map { url in
            try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: "\n")
                .filter { !$0.contains("#include \"Common.h\"") }
                .joined(separator: "\n")
        }

        let combinedSource = ([header] + kernels).joined(separator: "\n\n")
        return try device.makeLibrary(source: combinedSource, options: nil)
    }

    /// Wraps the sensor plane as a shared-storage MTLBuffer without
    /// copying it (DESIGN.md §7.2: the raw input crosses the CPU/GPU
    /// boundary, so it stays shared). The plane's IOSurface is
    /// page-aligned and a whole number of pages, which is what
    /// `makeBuffer(bytesNoCopy:)` needs; the buffer keeps the plane alive.
    /// Falls back to a copy if Metal ever refuses the memory.
    func makeSharedBuffer(wrapping plane: SensorPlane) -> MTLBuffer? {
        if let buffer = device.makeBuffer(bytesNoCopy: plane.pointer, length: plane.allocationLength,
                                          options: .storageModeShared,
                                          deallocator: { _, _ in withExtendedLifetime(plane) {} }) {
            return buffer
        }
        let byteLength = plane.count * MemoryLayout<UInt16>.size
        guard let buffer = device.makeBuffer(length: byteLength, options: .storageModeShared) else {
            return nil
        }
        buffer.contents().copyMemory(from: plane.pointer, byteCount: byteLength)
        return buffer
    }

    /// Private-storage textures for GPU-only intermediates. Private mode
    /// gets lossless framebuffer compression, which is the point (§7.2).
    func makePrivateTexture(width: Int, height: Int, pixelFormat: MTLPixelFormat) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: descriptor)
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
        let name = "latent_PixelEngine.bundle"
        if let url = Bundle.main.resourceURL?.appendingPathComponent(name),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()
}
