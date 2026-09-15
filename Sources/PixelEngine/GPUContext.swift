import Foundation
import Metal
import os
import RawCore
import Synchronization

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
/// thread-safe. The one piece of mutable state, the lazily built pipelines
/// (`lazyPipeline(_:)`), sits inside a `Mutex`, which is itself Sendable.
/// This is the one place in the codebase asserting something the compiler
/// can't check, so it stays narrow — if GPUContext ever gains mutable
/// state outside a lock, this conformance has to go.
public final class GPUContext: @unchecked Sendable {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    let library: MTLLibrary
    /// Whether the shaders came precompiled or were compiled at launch.
    public let shaderLibrarySource: ShaderLibrarySource

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
    let healGatherPSO: MTLComputePipelineState
    let healBlurPSO: MTLComputePipelineState
    let exportSampleLinearPSO: MTLComputePipelineState
    let exportResampleRowsPSO: MTLComputePipelineState
    let exportResampleColumnsPSO: MTLComputePipelineState
    let exportGainMapPSO: MTLComputePipelineState
    let healApplyPSO: MTLComputePipelineState
    let healPastePSO: MTLComputePipelineState
    let redEyeApplyPSO: MTLComputePipelineState
    let redEyePastePSO: MTLComputePipelineState
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

    // MARK: Lazily built pipelines

    /// Kernels whose pipelines are built the first time something asks for
    /// them, not at launch. Everything above is on the path of every image
    /// and is built eagerly; these serve rarer work (linear sources today,
    /// Photo Merge's kernels next), so an app that never opens such a file
    /// never pays for them. Each costs a millisecond or two with the
    /// precompiled library, but compiling a pipeline the first time a build's
    /// shaders are seen takes far longer, and that cost grows with every
    /// kernel added to launch.
    enum LazyKernel: String, CaseIterable, Sendable {
        case linearUpload
        case linearBinned
        // Photo Merge's HDR merge (MergeHDR.metal, HDRMergeKernels.swift).
        case mergeHDRBinnedAnalysis
        case mergeHDRRawPrepare
        case mergeHDRAccumulate
        case mergeHDRResolve
        case mergeHDRDownsample
    }

    /// Built pipelines, by kernel. A Mutex because renders run on several
    /// threads (the viewport, exports, thumbnails) and two could ask for the
    /// same pipeline at once.
    private let lazyPipelines = Mutex<[LazyKernel: MTLComputePipelineState]>([:])

    /// The pipeline for `kernel`, built on first use and kept for the life
    /// of the context. Building happens inside the lock, so a second caller
    /// waits for the first rather than compiling the same kernel twice.
    func lazyPipeline(_ kernel: LazyKernel) throws -> MTLComputePipelineState {
        try lazyPipelines.withLock { built in
            if let existing = built[kernel] { return existing }
            guard let function = library.makeFunction(name: kernel.rawValue) else {
                throw GPUContextError.missingShaderFunction(kernel.rawValue)
            }
            let pipeline = try device.makeComputePipelineState(function: function)
            built[kernel] = pipeline
            return pipeline
        }
    }

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw GPUContextError.noMetalDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw GPUContextError.commandQueueCreationFailed
        }
        let (library, librarySource) = try GPUContext.loadShaderLibrary(device: device)

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
        let healGatherPipeline = try makePipeline("healGather")
        let healBlurPipeline = try makePipeline("healBlur")
        let sampleLinearPipeline = try makePipeline("exportSampleLinear")
        let resampleRowsPipeline = try makePipeline("exportResampleRows")
        let resampleColumnsPipeline = try makePipeline("exportResampleColumns")
        let gainMapPipeline = try makePipeline("exportGainMap")
        let healApplyPipeline = try makePipeline("healApply")
        let healPastePipeline = try makePipeline("healPaste")
        let redEyeApplyPipeline = try makePipeline("redEyeApply")
        let redEyePastePipeline = try makePipeline("redEyePaste")
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
        self.shaderLibrarySource = librarySource
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
        self.healGatherPSO = healGatherPipeline
        self.healBlurPSO = healBlurPipeline
        self.exportSampleLinearPSO = sampleLinearPipeline
        self.exportResampleRowsPSO = resampleRowsPipeline
        self.exportResampleColumnsPSO = resampleColumnsPipeline
        self.exportGainMapPSO = gainMapPipeline
        self.healApplyPSO = healApplyPipeline
        self.healPastePSO = healPastePipeline
        self.redEyeApplyPSO = redEyeApplyPipeline
        self.redEyePastePSO = redEyePastePipeline
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
    /// scripts/make_app.sh writes the metallib when the Metal toolchain is
    /// installed. Loading it takes milliseconds; compiling the sources takes
    /// about 0.4 s the first time this machine sees them (Metal caches the
    /// result, so later launches are quick either way). A metallib that
    /// won't load, say one built by a toolchain newer than this system, is
    /// logged and the sources are used instead: they ship beside it.
    ///
    /// Runtime compilation can't resolve `#include "Common.h"` between
    /// separate source strings, so the fallback inlines Common.h once and
    /// strips the include lines from each kernel file.
    static func loadShaderLibrary(device: MTLDevice, bundle: Bundle = .latentResources,
                                  compileOptions: MTLCompileOptions? = nil) throws -> (MTLLibrary, ShaderLibrarySource) {
        func resourceURL(_ name: String, _ ext: String) -> URL? {
            bundle.url(forResource: name, withExtension: ext)
                ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "Shaders")
        }

        if let metallib = resourceURL("default", "metallib") {
            do {
                return (try device.makeLibrary(URL: metallib), .precompiled)
            } catch {
                gpuLog.error("Precompiled shaders failed to load, compiling the sources instead: \(String(describing: error), privacy: .public)")
            }
        }

        guard let headerURL = resourceURL("Common", "h") else {
            throw GPUContextError.shaderLibraryNotFound
        }
        // Every kernel source file must be listed here, or its functions
        // won't exist in the runtime-compiled library.
        let kernelNames = ["WhiteBalance", "Demosaic", "DemosaicBinned",
                            "ColorPipeline", "Present", "Histogram", "Scopes", "Detail", "LensCorrect", "Export", "RCD", "Heal", "LocalContrast", "AIDenoise", "RedEye", "Slideshow",
                            "LinearSource", "MergeHDR"]
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
        return (try device.makeLibrary(source: combinedSource, options: compileOptions), .compiledFromSource)
    }

    /// Wraps the sensor plane as a shared-storage MTLBuffer without
    /// copying it (DESIGN.md §7.2: the raw input crosses the CPU/GPU
    /// boundary, so it stays shared). The plane's IOSurface is
    /// page-aligned and a whole number of pages, which is what
    /// `makeBuffer(bytesNoCopy:)` needs; the buffer keeps the plane alive.
    /// Falls back to a copy if Metal ever refuses the memory.
    func makeSharedBuffer(wrapping plane: SensorPlane) -> MTLBuffer? {
        makeSharedBuffer(pointer: plane.pointer, allocationLength: plane.allocationLength,
                         byteCount: plane.count * MemoryLayout<UInt16>.size, owner: plane)
    }

    /// The same for a linear source's pixels (`LinearPlane`): its IOSurface
    /// is page-aligned and whole pages too.
    func makeSharedBuffer(wrapping plane: LinearPlane) -> MTLBuffer? {
        makeSharedBuffer(pointer: plane.pointer, allocationLength: plane.allocationLength,
                         byteCount: plane.byteCount, owner: plane)
    }

    /// Wraps `allocationLength` bytes at `pointer` without copying, keeping
    /// `owner` (the plane whose surface holds them) alive for as long as
    /// the buffer is; or copies `byteCount` of them if Metal refuses.
    private func makeSharedBuffer(pointer: UnsafeMutableRawPointer, allocationLength: Int, byteCount: Int,
                                  owner: AnyObject & Sendable) -> MTLBuffer? {
        if let buffer = device.makeBuffer(bytesNoCopy: pointer, length: allocationLength,
                                          options: .storageModeShared,
                                          deallocator: { _, _ in withExtendedLifetime(owner) {} }) {
            return buffer
        }
        guard let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
            return nil
        }
        buffer.contents().copyMemory(from: pointer, byteCount: byteCount)
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

/// Where a context's shader library came from.
public enum ShaderLibrarySource: String, Sendable {
    /// default.metallib, written by scripts/make_app.sh.
    case precompiled
    /// The bundled .metal sources, compiled at launch.
    case compiledFromSource
}

let gpuLog = Logger(subsystem: "com.latent.app", category: "gpu")

// MARK: - Shared context

extension GPUContext {
    /// Starts building the app's shared context on a background thread, if
    /// nothing has started it yet. The app calls this as it launches, so
    /// the first window never waits for shader loading and pipeline
    /// creation (a few milliseconds on a warm launch, over half a second
    /// the first time a build's shaders are compiled).
    ///
    /// Tests and the CLI keep calling `GPUContext()` directly: the shared
    /// context is only for code that wants one context for the process.
    public static func warmUp() {
        SharedContextBuild.instance.start()
    }

    /// The shared context once built, or the error that stopped it; nil
    /// while the build is still running or before `warmUp()`.
    public static var sharedIfBuilt: Result<GPUContext, any Error>? {
        SharedContextBuild.instance.result
    }

    /// The shared context, waiting for the build (and starting it if
    /// nothing has).
    public static func shared() async throws -> GPUContext {
        try await SharedContextBuild.instance.value()
    }
}

/// Builds the shared context once, on a GCD thread rather than in a task:
/// compiling shaders blocks, and a blocked cooperative thread is one the
/// app's other async work can't use.
private final class SharedContextBuild: @unchecked Sendable {
    static let instance = SharedContextBuild()

    // Everything below is guarded by `lock`.
    private let lock = NSLock()
    private var started = false
    private var built: Result<GPUContext, any Error>?
    private var waiters: [CheckedContinuation<GPUContext, any Error>] = []

    var result: Result<GPUContext, any Error>? {
        lock.withLock { built }
    }

    func start() {
        let isFirst = lock.withLock {
            defer { started = true }
            return !started
        }
        guard isFirst else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let clock = ContinuousClock()
            let start = clock.now
            let result = Result { try GPUContext() }
            let elapsed = clock.now - start
            switch result {
            case .success(let gpu):
                gpuLog.info("GPU context built in \(elapsed, privacy: .public) (shaders \(gpu.shaderLibrarySource.rawValue, privacy: .public))")
            case .failure(let error):
                gpuLog.error("GPU context failed after \(elapsed, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            self.finish(result)
        }
    }

    func value() async throws -> GPUContext {
        start()
        return try await withCheckedThrowingContinuation { continuation in
            let ready: Result<GPUContext, any Error>? = lock.withLock {
                if built == nil { waiters.append(continuation) }
                return built
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    private func finish(_ result: Result<GPUContext, any Error>) {
        let waiting = lock.withLock {
            built = result
            defer { waiters = [] }
            return waiters
        }
        for continuation in waiting { continuation.resume(with: result) }
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
