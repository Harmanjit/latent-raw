import Foundation
import XCTest
import PixelEngine
import RawCore
@testable import MergeKit

/// What the HDR tests share: one GPU context, brackets written once per
/// run, and a merge that reads its DNG back.
enum HDRTestSupport {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sharedGPU: GPUContext?
    nonisolated(unsafe) private static var brackets: [String: [URL]] = [:]
    nonisolated(unsafe) private static var bracketFolder: URL?

    static func gpu() throws -> GPUContext {
        lock.lock(); defer { lock.unlock() }
        if let gpu = sharedGPU { return gpu }
        let gpu = try GPUContext()
        sharedGPU = gpu
        return gpu
    }

    /// A merger that sees plenty of disk and an unconstrained Mac.
    static func merger(memoryPolicy: MemoryPolicy = MemoryPolicy(physicalMemory: 16 << 30),
                       availableCapacity: @escaping @Sendable (URL) -> Int64? = { _ in nil },
                       gpuMemoryBudget: Int? = nil) throws -> HDRMerger {
        HDRMerger(gpu: try gpu(), memoryPolicy: memoryPolicy, availableCapacity: availableCapacity,
                  gpuMemoryBudget: gpuMemoryBudget)
    }

    /// The 1200 x 800 test scene, made once.
    static let scene = SyntheticBracket.scene()

    /// A bracket of the test scene, written once per test run under `key`.
    static func bracket(_ key: String, _ frames: [SyntheticBracket.Frame], noise: Bool) throws -> [URL] {
        lock.lock(); defer { lock.unlock() }
        if let urls = brackets[key] { return urls }
        let folder: URL
        if let existing = bracketFolder {
            folder = existing
        } else {
            folder = try sharedFolder()
            bracketFolder = folder
        }
        let urls = try SyntheticBracket.write(frames, of: scene, noise: noise, to: folder, name: key)
        brackets[key] = urls
        return urls
    }

    /// The brackets' folder, one per test process. Brackets outlive every
    /// test that uses them, so nothing removes the folder at the end; each
    /// run removes the folders of earlier test processes that have exited
    /// instead (never one still running, as parallel test workers are).
    private static func sharedFolder() throws -> URL {
        let temporary = FileManager.default.temporaryDirectory
        let prefix = "MergeKitTests-HDRBrackets-"
        let mine = prefix + "\(ProcessInfo.processInfo.processIdentifier)"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
        where name.hasPrefix(prefix) && name != mine {
            if let pid = Int32(name.dropFirst(prefix.count)), kill(pid, 0) == 0 { continue }
            try? FileManager.default.removeItem(at: temporary.appendingPathComponent(name))
        }
        let folder = temporary.appendingPathComponent(mine, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Exposures 4, 1 and 1/4: 2 stops apart.
    static let threeExposures = [4.0, 1, 0.25]

    /// The three-frame bracket, noiseless, EXIF true.
    static func cleanBracket() throws -> [URL] {
        try bracket("clean3", SyntheticBracket.frames(threeExposures), noise: false)
    }

    /// The three-frame bracket with noise, and the middle frame's EXIF
    /// saying 1/64 s where it was really exposed for 1/60 s (0.09 stops).
    static func noisyBracket() throws -> [URL] {
        var frames = SyntheticBracket.frames(threeExposures)
        frames[1] = SyntheticBracket.Frame(exposure: 1, exifShutter: 1.0 / 64)
        return try bracket("noisy3", frames, noise: true)
    }

    /// Recipe sources for `urls`, as the app would give them.
    static func sources(_ urls: [URL]) -> [MergeRecipe.Source] {
        urls.enumerated().map { i, url in
            MergeRecipe.Source(path: url.lastPathComponent, hash: String(format: "%016x", i + 1),
                               captureTime: 1_789_498_800 + Int64(i))
        }
    }

    /// A merge's DNG read back: the merged values (the stored ones times
    /// 2^shift), RGB per pixel.
    struct Merged {
        let width: Int
        let height: Int
        let rgb: [Float]
        let file: RawFile

        func pixel(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let i = (y * width + x) * 3
            return SIMD3(rgb[i], rgb[i + 1], rgb[i + 2])
        }
    }

    static func readBack(_ url: URL) throws -> Merged {
        let file = try RawFile(path: url.path)
        let plane = try XCTUnwrap(file.linearPlane)
        let scale = Float(1 << (file.summary.mergeInfo?.baselineShift ?? 0))
        let samples = plane.samples
        var rgb = [Float](repeating: 0, count: plane.width * plane.height * 3)
        for i in 0..<(plane.width * plane.height) {
            rgb[i * 3] = Float(samples[i * 4]) * scale
            rgb[i * 3 + 1] = Float(samples[i * 4 + 1]) * scale
            rgb[i * 3 + 2] = Float(samples[i * 4 + 2]) * scale
        }
        return Merged(width: plane.width, height: plane.height, rgb: rgb, file: file)
    }

    /// Analyses and merges `urls` into a new folder; returns everything a
    /// test may check. The caller removes `folder`.
    static func merge(_ urls: [URL], merger: HDRMerger? = nil, options: HDRMergeOptions = HDRMergeOptions())
    async throws -> (analysis: HDRMergeAnalysis, result: MergeDNGWriteResult, report: HDRMergeReport, folder: URL) {
        let merger = try merger ?? self.merger()
        let analysis = try await merger.analyse(urls)
        let folder = try Fixtures.temporaryFolder()
        let destination = folder.appendingPathComponent("merged-HDR.dng")
        let (result, report) = try await merger.mergeWithReport(
            analysis, options: options, sources: sources(analysis.frames.map(\.url)), to: destination,
            prepareSidecar: { _ in }, progress: { _ in })
        return (analysis, result, report, folder)
    }
}
