// The HDR dialog's live preview, part 1: the bracket's frames kept small in
// memory, so that changing an option merges them again without reading the
// raw files (docs/PhotoMerge.md, Phase 7). HDRMerger+Preview.swift merges them.

import Foundation
import PixelEngine
import RawCore

/// One frame of a bracket as the preview keeps it: a small Bayer mosaic
/// (`RawFile.bayerSource`) and the levels measured on the full-size frame.
///
/// **How a frame is reduced.** Every reduced Bayer quad stands for a
/// `2 x factor` square of the sensor, and each of its four photosites for
/// the `factor x factor` photosites of the same colour in that square. So
/// the mosaic keeps the sensor's Bayer order and its units (black and white
/// levels, clip level), and the merge's own steps (RCD, clip mask, feathering,
/// deghosting, weights) run on it unchanged, only on fewer pixels.
///
/// Each reduced photosite is the mean of its photosites, except where any
/// of them is clipped: then it is their largest value, so it counts as
/// clipped too. A mean would dip below the clip level and hand the merge a
/// highlight that is really part clipped, which the full-size merge never
/// uses (it widens clipping, it doesn't average it away).
final class HDRPreviewFrame: @unchecked Sendable {
    let url: URL
    /// The reduced mosaic; its summary is the full frame's, at the reduced size.
    let file: RawFile
    /// `HDRMerger.levels` of the full-size frame.
    let levels: HDRFrameLevels
    /// Sensor photosites per reduced photosite, along each side.
    let factor: Int

    init(url: URL, file: RawFile, levels: HDRFrameLevels, factor: Int) {
        self.url = url
        self.file = file
        self.levels = levels
        self.factor = factor
    }

    /// Memory the mosaic holds.
    var byteCount: Int { file.summary.rawWidth * file.summary.rawHeight * MemoryLayout<UInt16>.size }

    /// The reduced size of a `width x height` frame: whole reduced quads
    /// only, so a strip under `2 x factor` photosites wide may be dropped
    /// along the right and bottom edges.
    static func size(width: Int, height: Int, factor: Int) -> (width: Int, height: Int) {
        let quad = 2 * max(1, factor)
        return (max(1, width / quad) * 2, max(1, height / quad) * 2)
    }

    /// `file` (a full open of a Bayer raw) reduced by `factor`.
    static func reduce(_ file: RawFile, url: URL, levels: HDRFrameLevels, factor: Int) -> HDRPreviewFrame? {
        guard let plane = file.sensorPlane else { return nil }
        return reduce(plane.samples, summary: file.summary, cameraToXYZ: file.cameraToXYZMatrixRaw, url: url,
                      levels: levels, factor: factor)
    }

    /// A reduced frame reduced further, by `by` (a whole number), from its
    /// own mosaic: the preview keeps one size and makes smaller ones from it.
    func reduced(by: Int) -> HDRPreviewFrame? {
        guard by > 1, let plane = file.sensorPlane else { return by == 1 ? self : nil }
        return Self.reduce(plane.samples, summary: file.summary, cameraToXYZ: file.cameraToXYZMatrixRaw, url: url,
                           levels: levels, factor: by, keepingFactor: factor * by)
    }

    private static func reduce(_ samples: UnsafeBufferPointer<UInt16>, summary: RawSummary, cameraToXYZ: [Float]?,
                               url: URL, levels: HDRFrameLevels, factor: Int,
                               keepingFactor: Int? = nil) -> HDRPreviewFrame? {
        let factor = max(1, factor)
        let fullWidth = summary.rawWidth, fullHeight = summary.rawHeight
        let (w, h) = size(width: fullWidth, height: fullHeight, factor: factor)
        guard samples.count >= fullWidth * fullHeight, fullWidth >= 2, fullHeight >= 2 else { return nil }
        // At or above this a photosite is clipped (see `HDRFrameLevels.clipRaw`).
        let clip = UInt32(max(0, levels.clipRaw.rounded(.up)))
        var reduced = [UInt16](repeating: 0, count: w * h)
        // Each row's largest value, gathered once the rows are done.
        var rowLargest = [UInt16](repeating: 0, count: h)
        reduced.withUnsafeMutableBufferPointer { output in rowLargest.withUnsafeMutableBufferPointer { rows in
            nonisolated(unsafe) let out = output
            nonisolated(unsafe) let largestInRow = rows
            nonisolated(unsafe) let source = samples
            DispatchQueue.concurrentPerform(iterations: h) { y in
                // This row's photosites: the same colour sits every second
                // row and column, so the block's `factor` rows of that colour
                // start at the quad's top row plus this photosite's offset.
                let top = (y / 2) * 2 * factor + (y % 2)
                var largest: UInt16 = 0
                for x in 0..<w {
                    let left = (x / 2) * 2 * factor + (x % 2)
                    var sum: UInt32 = 0, maximum: UInt16 = 0
                    for dy in 0..<factor {
                        let row = (top + 2 * dy) * fullWidth
                        for dx in 0..<factor {
                            let value = source[row + left + 2 * dx]
                            sum += UInt32(value)
                            maximum = max(maximum, value)
                        }
                    }
                    let count = UInt32(factor * factor)
                    let value = UInt32(maximum) >= clip ? maximum : UInt16((sum + count / 2) / count)
                    out[y * w + x] = value
                    largest = max(largest, value)
                }
                largestInRow[y] = largest
            }
        } }
        let largest = rowLargest.max() ?? 0
        let file = reduced.withUnsafeBufferPointer { buffer in
            RawFile.bayerSource(width: w, height: h, like: summary, cameraToXYZ: cameraToXYZ,
                                dataMaximum: Float(largest), samples: buffer)
        }
        return file.map { HDRPreviewFrame(url: url, file: $0, levels: levels, factor: keepingFactor ?? factor) }
    }
}

/// A whole bracket's reduced frames at one size, as a preview merges them.
///
/// **How the merge finds them.** The merge's steps open each frame by its
/// URL and work out its levels themselves (`HDRMerger.open`, `levels`, and
/// the deghosting pass in MergeKit/Deghost, which calls them). Rather than
/// giving every step a second way in, a preview sets `current` for as long
/// as it runs (a task-local value: seen only by code running inside that
/// task), and those two functions hand back the reduced frames instead.
/// So the preview runs the very code the merge runs, including whatever
/// the deghosting pass learns later.
final class HDRPreviewFrameSet: @unchecked Sendable {
    /// Sensor photosites per reduced photosite, along each side.
    let factor: Int
    /// The reduced frames' size.
    let width: Int
    let height: Int
    private let frames: [String: HDRPreviewFrame]

    init?(_ frames: [HDRPreviewFrame]) {
        guard let first = frames.first,
              frames.allSatisfy({ $0.factor == first.factor
                                  && $0.file.summary.rawWidth == first.file.summary.rawWidth
                                  && $0.file.summary.rawHeight == first.file.summary.rawHeight }) else { return nil }
        factor = first.factor
        width = first.file.summary.rawWidth
        height = first.file.summary.rawHeight
        self.frames = Dictionary(frames.map { (Self.key($0.url), $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// The preview under way in this task, if any.
    @TaskLocal static var current: HDRPreviewFrameSet?

    func file(for url: URL) -> RawFile? { frames[Self.key(url)]?.file }

    func levels(for file: RawFile) -> HDRFrameLevels? {
        frames.values.first { $0.file === file }?.levels
    }

    /// One key per file however its URL is spelled.
    static func key(_ url: URL) -> String { url.standardizedFileURL.path }
}

/// The reduced frames of the bracket most recently analysed or previewed,
/// kept by an `HDRMerger` between previews.
///
/// **Bounded.** It holds one bracket: analysing or previewing another one
/// lets the first go. Frames are kept at `HDRMerger.previewFactor`, whose
/// long edge is at most `HDRMerger.previewCacheLongEdge` photosites (a
/// 21 MP frame: 2,808 x 1,872, 10.5 MB), plus one smaller size made from
/// those, for the merge the picture needs (a quarter as much, or less).
/// Nine frames, the most a merge takes, stay under 160 MB for any camera
/// of 4:3 or wider; a 6-frame 21 MP bracket holds 79 MB. `release()` (the dialog
/// closing) frees everything.
final class HDRPreviewCache: @unchecked Sendable {
    private let lock = NSLock()
    /// The bracket's files, by `HDRPreviewFrameSet.key`, in any order.
    private var bracket: Set<String> = []
    private var frames: [String: HDRPreviewFrame] = [:]
    /// Frames reduced further for a smaller preview, and by how much.
    private var smaller: (by: Int, set: HDRPreviewFrameSet)?

    /// Forgets everything unless it is `urls`' bracket.
    func prepare(for urls: [URL]) {
        let keys = Set(urls.map(HDRPreviewFrameSet.key))
        lock.withLock {
            guard keys != bracket else { return }
            bracket = keys
            frames = [:]
            smaller = nil
        }
    }

    func store(_ frame: HDRPreviewFrame) {
        let key = HDRPreviewFrameSet.key(frame.url)
        lock.withLock {
            guard bracket.contains(key) else { return }
            frames[key] = frame
        }
    }

    func frame(for url: URL) -> HDRPreviewFrame? {
        lock.withLock { frames[HDRPreviewFrameSet.key(url)] }
    }

    /// The bracket at its kept size reduced further `by` times (1: as kept),
    /// or nil while any of `urls` is missing.
    func frameSet(for urls: [URL], reducedBy by: Int) -> HDRPreviewFrameSet? {
        let keys = urls.map(HDRPreviewFrameSet.key)
        return lock.withLock { () -> HDRPreviewFrameSet? in
            guard Set(keys) == bracket else { return nil }
            let kept = keys.compactMap { frames[$0] }
            guard kept.count == keys.count else { return nil }
            if by <= 1 { return HDRPreviewFrameSet(kept) }
            if let smaller, smaller.by == by { return smaller.set }
            guard let set = HDRPreviewFrameSet(kept.compactMap { $0.reduced(by: by) }) else { return nil }
            smaller = (by, set)
            return set
        }
    }

    func release() {
        lock.withLock {
            bracket = []
            frames = [:]
            smaller = nil
        }
    }

    /// Memory the kept mosaics hold, for tests.
    var byteCount: Int {
        lock.withLock {
            frames.values.reduce(0) { $0 + $1.byteCount }
                + (smaller.map { set in set.set.width * set.set.height * 2 * frames.count } ?? 0)
        }
    }
}
