import Foundation
import Metal
import RawCore
import ColorKit

/// Runs full-resolution exports off the main thread.
///
/// An actor rather than a detached task, because export and the viewport
/// would otherwise share an `ImageSession` — and that session owns a
/// mutable texture pool. Two threads mutating that dictionary, and reusing
/// the same textures, is a real data race, not a theoretical one: an export
/// re-rendering at full resolution into pooled textures would overwrite the
/// preview the viewport is drawing from.
///
/// The isolation here is total rather than lock-based. This actor opens its
/// **own** RawFile and ImageSession from the URL, so nothing mutable is
/// shared with the editor at all. The cost is re-decoding the raw file
/// (~190ms for a 24MP NEF) inside an operation that already takes about a
/// second, which is a fair price for not having to reason about locking
/// every time the pipeline grows a new intermediate buffer.
///
/// Only `GPUContext` crosses the boundary, and it's safe to share: every
/// stored property is a `let`, and Metal's device, command queue and
/// pipeline states are documented thread-safe.
public actor ExportService {
    private let gpu: GPUContext
    private let pipeline: RenderPipeline
    private let exporter: Exporter

    public init(gpu: GPUContext) {
        self.gpu = gpu
        self.pipeline = RenderPipeline(gpu: gpu)
        self.exporter = Exporter(gpu: gpu)
    }

    /// Renders `sourceURL` at full resolution with `parameters` and writes
    /// the result to `destinationURL`. Returns how long it took.
    ///
    /// Full resolution deliberately, not the viewport texture: exporting
    /// the preview would silently produce a smaller, softer file than the
    /// raw data supports. It also means the chosen demosaic algorithm
    /// actually applies, since the viewport path bins Bayer quads instead
    /// of interpolating.
    @discardableResult
    public func export(from sourceURL: URL,
                        to destinationURL: URL,
                        parameters: EditParameters,
                        settings: ExportSettings,
                        userRotation: Int = 0) throws -> TimeInterval {
        let start = Date()

        let file = try RawFile(path: sourceURL.path)
        let session = try ImageSession(file: file, gpu: gpu)
        let rendered = try pipeline.render(session, scale: .full, parameters: parameters)
        let rotation = ImageRotation(libRawFlip: file.summary.orientation).rotated(by: userRotation)
        try exporter.write(rendered, to: destinationURL,
                            settings: settings, colorSpace: parameters.outputSpace,
                            rotation: rotation, crop: parameters.crop)

        // The session goes out of scope here, taking its textures with it —
        // the RCD intermediates alone run to several hundred megabytes at
        // full resolution, so letting them die with the session is the
        // whole point of building a throwaway one.
        return Date().timeIntervalSince(start)
    }
}
