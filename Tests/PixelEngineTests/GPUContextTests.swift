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
        // The sources sit under Shaders/ in the resource bundle (Package.swift
        // copies the folder as it is) or, in an older bundle, at its root;
        // the loader looks in both places, so does this. The copy goes flat.
        let root = try #require(Bundle.latentResources.resourceURL)
        var copied = 0
        for dir in [root.appendingPathComponent("Shaders", isDirectory: true), root] {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for file in files where ["metal", "h"].contains(file.pathExtension) {
                let target = folder.appendingPathComponent(file.lastPathComponent)
                guard !FileManager.default.fileExists(atPath: target.path) else { continue }
                try FileManager.default.copyItem(at: file, to: target)
                copied += 1
            }
        }
        #expect(copied >= 24, "only \(copied) shader sources found in the resource bundle")
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
