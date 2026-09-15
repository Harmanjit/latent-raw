import Testing
import Foundation
import Metal
@testable import PixelEngine

/// The shader library loader and the app's shared context.
@Suite struct GPUContextTests {
    /// Every pipeline's function, under the Metal 3.0 language that
    /// scripts/make_app.sh precompiles with (`-std=metal3.0`, the macOS 15
    /// baseline). Runtime compilation otherwise uses the newest language
    /// the system has, so a newer feature would slip in unnoticed until
    /// the app bundle failed to precompile.
    @Test func shadersCompileAsMetal3() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let options = MTLCompileOptions()
        options.languageVersion = .version3_0
        let (library, source) = try GPUContext.loadShaderLibrary(device: device, compileOptions: options)
        #expect(source == .compiledFromSource, "swift build bundles have no metallib")
        let names = Set(library.functionNames)
        for name in ["blackLevelAndWhiteBalance", "colorAndTone", "presentToScreen", "rcdRedBlueAtGreen", "aiDenoiseBlend"] {
            #expect(names.contains(name), "\(name) missing")
        }
        #expect(names.count >= 29)
    }

    /// A metallib the system refuses (a newer toolchain's, or a damaged
    /// file) must not stop the app: the sources ship beside it.
    @Test func unloadableMetallibFallsBackToSources() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-shaders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sources = try #require(Bundle.latentResources.resourceURL)
        for file in try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
        where ["metal", "h"].contains(file.pathExtension) {
            try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(file.lastPathComponent))
        }
        try Data("not a metallib".utf8).write(to: folder.appendingPathComponent("default.metallib"))

        let bundle = try #require(Bundle(url: folder))
        let (library, source) = try GPUContext.loadShaderLibrary(device: device, bundle: bundle)
        #expect(source == .compiledFromSource)
        #expect(library.makeFunction(name: "colorAndTone") != nil)
    }

    /// One context for the process, however many callers ask at once.
    @Test func sharedContextIsBuiltOnce() async throws {
        GPUContext.warmUp()
        async let first = GPUContext.shared()
        async let second = GPUContext.shared()
        let (a, b) = try await (first, second)
        #expect(a === b)
        let built = try #require(GPUContext.sharedIfBuilt)
        #expect(try built.get() === a)
    }
}
