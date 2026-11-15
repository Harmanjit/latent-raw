import Foundation
import Metal

/// How many photos an export may work on at once (Export › Photos at once;
/// docs/Performance-Plan.md #19).
///
/// Each photo in flight holds its raw, the full-resolution render and its
/// textures, and the encoded pixels: about 1.6 GB of memory footprint
/// (GPU memory included) for a 24 MP raw exported at full size, about
/// 0.3 GB at 2048 px (measured: `perPhotoBytes`). The limit keeps all of
/// them inside a share of the Mac's memory and of what the GPU says it can
/// keep resident, so a 16 GB Mac doesn't swap, and never goes past
/// `hardCap`.
/// It's worked out per batch, since bigger photos lower it.
public enum ExportConcurrency {
    /// Never more than this many at once, whatever the Mac: beyond it the
    /// GPU and the encoders are saturated and only memory grows.
    public static let hardCap = 6

    /// What Automatic picks when the Mac allows it. Measured on a 16 GB M4,
    /// 10 full-size D750 JPEGs (median of 5, load average about 6.5):
    /// 1 at once 95 photos a minute, 2 162, 3 207, 4 231, with peak memory
    /// 1.7, 3.3, 4.9 and 6.5 GB. 3 takes most of the gain while staying
    /// inside a third of a 16 GB Mac's memory; past it the decode, on the
    /// CPU, is the limit and memory keeps growing.
    public static let measuredBest = 3

    /// The share of the Mac's memory all photos in flight may take
    /// together. The rest is the app (catalog, previews, the editor's
    /// caches), other apps and the system.
    static let memoryShare = 1.0 / 3
    /// The share of the GPU's recommended working set they may take.
    static let gpuShare = 0.5

    /// What the limit is worked out from.
    public struct Machine: Sendable, Equatable {
        /// `ProcessInfo.physicalMemory`, in bytes.
        public var physicalMemory: UInt64
        /// `MTLDevice.recommendedMaxWorkingSetSize`, in bytes; 0 when unknown.
        public var gpuWorkingSet: UInt64
        /// `ProcessInfo.activeProcessorCount`.
        public var activeCores: Int

        public init(physicalMemory: UInt64, gpuWorkingSet: UInt64, activeCores: Int) {
            self.physicalMemory = physicalMemory
            self.gpuWorkingSet = gpuWorkingSet
            self.activeCores = activeCores
        }

        /// This Mac, with `device` (the export's GPU) for the working set.
        public static func current(device: MTLDevice?) -> Machine {
            Machine(physicalMemory: ProcessInfo.processInfo.physicalMemory,
                    gpuWorkingSet: device?.recommendedMaxWorkingSetSize ?? 0,
                    activeCores: ProcessInfo.processInfo.activeProcessorCount)
        }
    }

    /// The memory one photo holds at its peak while it exports: a part
    /// that grows with the raw (the sensor data, the demosaicked
    /// full-resolution textures the edit renders through) and a part that
    /// grows with the file (the resized texture, the read-back pixels, the
    /// encoder's copy), plus a fixed part. Calibrated from the peak memory
    /// footprint of `latent-cli export --jobs 1...4`: 1.6 GB more per photo
    /// for 24 MP raws at full size, 0.3 GB at 2048 px, 1.76 GB for a 41 MP
    /// linear DNG; the estimate errs high (1.75 GB, 0.42 GB, 2.9 GB).
    public static func perPhotoBytes(sourceMegapixels: Double, outputMegapixels: Double) -> UInt64 {
        let source = max(sourceMegapixels, 1)
        let output = min(max(outputMegapixels, 0), source * 4)
        let bytes = 100.0 * 1_000_000 + source * bytesPerSourcePixel * 1_000_000
            + output * bytesPerOutputPixel * 1_000_000
        return UInt64(bytes)
    }
    static let bytesPerSourcePixel = 6.0
    static let bytesPerOutputPixel = 62.0

    /// The most photos at once this Mac can take for photos this big: the
    /// biggest photo of the batch and the size it's exported at.
    public static func limit(machine: Machine, sourceMegapixels: Double, outputMegapixels: Double) -> Int {
        let perPhoto = Double(perPhotoBytes(sourceMegapixels: sourceMegapixels, outputMegapixels: outputMegapixels))
        var budget = Double(machine.physicalMemory) * memoryShare
        if machine.gpuWorkingSet > 0 { budget = min(budget, Double(machine.gpuWorkingSet) * gpuShare) }
        let byMemory = Int(budget / perPhoto)
        // Decode and encode are CPU work: one photo per two cores at most.
        let byCores = max(1, machine.activeCores / 2)
        return max(1, min(hardCap, byMemory, byCores))
    }

    /// What Automatic picks under `limit`.
    public static func automatic(limit: Int) -> Int {
        max(1, min(limit, measuredBest))
    }

    /// How many run for the saved choice (`automaticChoice` for Automatic,
    /// else a count): the count clamped to `limit`, and whether clamping
    /// lowered it.
    public static func resolve(choice: Int, limit: Int) -> (workers: Int, clamped: Bool) {
        let limit = max(1, limit)
        guard choice != automaticChoice else { return (automatic(limit: limit), false) }
        let wanted = max(1, choice)
        return (min(wanted, limit), wanted > limit)
    }

    /// The stored value meaning Automatic.
    public static let automaticChoice = 0

    /// The megapixels of a photo whose size the catalog doesn't know,
    /// guessed from its file: about a byte per pixel for a compressed raw,
    /// which overestimates an uncompressed one, the safe side for a limit.
    public static func estimatedMegapixels(width: Int?, height: Int?, fileBytes: Int64) -> Double {
        if let width, let height, width > 0, height > 0 { return Double(width) * Double(height) / 1_000_000 }
        return max(Double(fileBytes) / 1_000_000, 1)
    }
}
