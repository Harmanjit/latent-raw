import Foundation
import Metal

// Prepared panorama frames on disk. Harman's 17 photos at 24 MP would be
// 17 x 6016 x 4016 x 8 bytes = 3.3 GB as full-resolution half floats, too
// much to keep in memory or on the GPU, so each frame lives in its own
// memory-mapped scratch file and the stitcher copies it to the GPU only
// while the tiles near it are blended (`PanoramaFrameCache`).

/// A memory-mapped scratch file: `byteCount` bytes readable and writable
/// through `pointer`, backed by a file the system can page to and from
/// instead of holding the bytes in memory. The file is deleted when the
/// object goes away (or earlier with `remove()`), unless `keepOnDisk`.
final class PanoramaScratchFile {
    let url: URL
    let byteCount: Int
    /// Set when something else (a store's folder) now owns the file.
    var keepOnDisk = false
    private(set) var pointer: UnsafeMutableRawPointer?
    private var mappedLength = 0

    /// Creates (it must not exist) and maps a file of `byteCount` bytes.
    init(url: URL, byteCount: Int) throws {
        guard byteCount > 0 else { throw PanoramaBlendError.scratchFile("empty file \(url.lastPathComponent)") }
        self.url = url
        self.byteCount = byteCount
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Self.error("create", url) }
        defer { close(descriptor) }
        guard ftruncate(descriptor, off_t(byteCount)) == 0 else {
            let error = Self.error("size", url)
            unlink(url.path)
            throw error
        }
        guard let mapped = mmap(nil, byteCount, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0),
              mapped != MAP_FAILED else {
            let error = Self.error("map", url)
            unlink(url.path)
            throw error
        }
        pointer = mapped
        mappedLength = byteCount
    }

    /// Maps an existing file read-only for the length of `body`.
    static func withMapping<Result>(of url: URL, byteCount: Int,
                                    _ body: (UnsafeRawBufferPointer) throws -> Result) throws -> Result {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw error("open", url) }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, Int(status.st_size) >= byteCount else {
            throw PanoramaBlendError.scratchFile("\(url.lastPathComponent) is shorter than \(byteCount) bytes")
        }
        guard let mapped = mmap(nil, byteCount, PROT_READ, MAP_SHARED, descriptor, 0), mapped != MAP_FAILED else {
            throw error("map", url)
        }
        defer { munmap(mapped, byteCount) }
        return try body(UnsafeRawBufferPointer(start: mapped, count: byteCount))
    }

    /// Unmaps without deleting (the bytes stay in the file).
    func unmap() {
        if let pointer { munmap(pointer, mappedLength) }
        pointer = nil
    }

    func remove() {
        unmap()
        unlink(url.path)
    }

    deinit {
        if keepOnDisk { unmap() } else { remove() }
    }

    private static func error(_ action: String, _ url: URL) -> PanoramaBlendError {
        .scratchFile("\(action) \(url.lastPathComponent): \(String(cString: strerror(errno)))")
    }
}

/// Prepared frames in scratch files, one per frame, in a folder of its own
/// under the app's temporary directory.
///
/// **Cleaning up.** The folder is deleted by `removeScratch()` (the
/// stitcher calls it when a stitch completes, fails or is cancelled, unless
/// told not to), when the store is released, and at quit by
/// `removeScratchOfThisProcess()`. A crash leaves the folder behind:
/// `removeAbandonedScratch()` at launch deletes folders whose process is
/// gone. Folder names start with the process ID for that reason.
///
/// Safe to use from several threads: the list of frames is locked, and each
/// frame's file is written once, before anything reads it.
public final class PanoramaFrameStore: PanoramaBlendFrameSource, @unchecked Sendable {
    /// The folder holding this store's files.
    public let directory: URL
    private let lock = NSLock()
    private var frames: [Int: PanoramaPreparedFrame] = [:]
    private var removed = false

    /// Where every store's folder goes: `LatentPanorama` in the temporary directory.
    public static var scratchParent: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LatentPanorama", isDirectory: true)
    }

    /// Makes an empty store in a new folder under `parent`.
    public init(parent: URL = PanoramaFrameStore.scratchParent) throws {
        let name = "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)"
        directory = parent.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw PanoramaBlendError.scratchFile("make \(directory.path): \(error.localizedDescription)")
        }
    }

    deinit { removeScratch() }

    /// Adds photo `frameIndex`'s prepared frame: makes its file and lets
    /// `fill` write `width x height x 4` half floats (rgba, row by row) into
    /// it. Replaces a frame already stored under that index.
    public func add(frameIndex: Int, width: Int, height: Int, sampleScale: Double,
                    fill: (UnsafeMutableBufferPointer<Float16>) throws -> Void) throws {
        let frame = PanoramaPreparedFrame(frameIndex: frameIndex, width: width, height: height, sampleScale: sampleScale)
        try Self.validate(frame)
        let url = try fileURL(frameIndex)
        try? FileManager.default.removeItem(at: url)
        let file = try PanoramaScratchFile(url: url, byteCount: frame.byteCount)
        do {
            guard let pointer = file.pointer else { throw PanoramaBlendError.scratchFile("unmapped") }
            let halves = pointer.bindMemory(to: Float16.self, capacity: width * height * 4)
            try fill(UnsafeMutableBufferPointer(start: halves, count: width * height * 4))
        } catch {
            file.remove()
            throw error
        }
        // The store's folder owns the file from here on; unmapping leaves
        // the bytes in it.
        file.keepOnDisk = true
        file.unmap()
        lock.withLock { frames[frameIndex] = frame }
    }

    /// Adds a prepared frame straight from the GPU: an rgba16Float texture
    /// (private or shared) copied into the frame's file a band of rows at a
    /// time, so no second full-size copy is ever made. Waits for the GPU.
    public func add(frameIndex: Int, texture: MTLTexture, sampleScale: Double, commandQueue: MTLCommandQueue,
                    bandHeight: Int = 512) throws {
        guard texture.pixelFormat == .rgba16Float, texture.textureType == .type2D else {
            throw PanoramaBlendError.invalidFrame(frameIndex: frameIndex, reason: "expected a 2D rgba16Float texture")
        }
        let width = texture.width, height = texture.height
        let rows = max(1, min(bandHeight, height))
        var band: MTLTexture? = nil
        if texture.storageMode != .shared {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width,
                                                                      height: rows, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead]
            band = commandQueue.device.makeTexture(descriptor: descriptor)
            guard band != nil else { throw PanoramaBlendError.scratchFile("no memory for a readback band") }
        }
        try add(frameIndex: frameIndex, width: width, height: height, sampleScale: sampleScale) { pixels in
            guard let base = pixels.baseAddress else { return }
            var y = 0
            while y < height {
                let count = min(rows, height - y)
                let destination = UnsafeMutableRawPointer(base + y * width * 4)
                if let band {
                    guard let commands = commandQueue.makeCommandBuffer(),
                          let blit = commands.makeBlitCommandEncoder() else {
                        throw PanoramaBlendError.scratchFile("GPU readback failed")
                    }
                    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: y, z: 0),
                              sourceSize: MTLSize(width: width, height: count, depth: 1), to: band,
                              destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                    blit.endEncoding()
                    commands.commit()
                    commands.waitUntilCompleted()
                    guard commands.status == .completed else { throw PanoramaBlendError.scratchFile("GPU readback failed") }
                    band.getBytes(destination, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, count),
                                  mipmapLevel: 0)
                } else {
                    texture.getBytes(destination, bytesPerRow: width * 8, from: MTLRegionMake2D(0, y, width, count),
                                     mipmapLevel: 0)
                }
                y += count
            }
        }
    }

    public func preparedFrame(_ frameIndex: Int) -> PanoramaPreparedFrame? {
        lock.withLock { removed ? nil : frames[frameIndex] }
    }

    public func withPixels<Result>(of frameIndex: Int, _ body: (UnsafeRawBufferPointer) throws -> Result) throws -> Result {
        guard let frame = preparedFrame(frameIndex) else { throw PanoramaBlendError.missingFrame(frameIndex: frameIndex) }
        return try PanoramaScratchFile.withMapping(of: try fileURL(frameIndex), byteCount: frame.byteCount, body)
    }

    /// Bytes of all the frames' files.
    public var byteCount: Int { lock.withLock { frames.values.reduce(0) { $0 + $1.byteCount } } }

    /// Deletes the store's folder and forgets its frames. Safe to call more than once.
    public func removeScratch() {
        let first = lock.withLock { () -> Bool in
            defer { removed = true; frames = [:] }
            return !removed
        }
        if first { try? FileManager.default.removeItem(at: directory) }
    }

    /// Deletes every store folder this process made (for quitting, when a
    /// stitch may still be running).
    @discardableResult
    public static func removeScratchOfThisProcess(parent: URL = scratchParent) -> Int {
        let mine = "\(ProcessInfo.processInfo.processIdentifier)-"
        return removeFolders(in: parent) { $0.hasPrefix(mine) }
    }

    /// How long a folder whose process id is in use again has to sit
    /// untouched before it counts as abandoned anyway.
    ///
    /// macOS hands process ids out again within a day or two. A folder left
    /// by a crash at pid 4821 that some launchd job now holds would
    /// otherwise be skipped at every launch for ever, and a crashed
    /// 17-photo panorama's folder is over 3 GB of the boot volume with
    /// nothing in the app to explain it. Nothing live can look this old:
    /// this process's own folders are excluded by their name, and any other
    /// Latent's would still be writing frames into theirs.
    public static let abandonedAfter: TimeInterval = 24 * 60 * 60

    /// Deletes store folders left by processes that are no longer running
    /// (a crash, or a quit that couldn't clean up), and folders old enough
    /// that their process id has plainly been handed on since. Call at
    /// launch.
    @discardableResult
    public static func removeAbandonedScratch(parent: URL = scratchParent, now: Date = Date()) -> Int {
        let mine = "\(ProcessInfo.processInfo.processIdentifier)-"
        return removeFolders(in: parent) { name in
            guard !name.hasPrefix(mine) else { return false }
            guard let dash = name.firstIndex(of: "-"), let pid = Int32(name[..<dash]) else { return false }
            // kill with signal 0 only asks whether the process exists; EPERM
            // means it does but belongs to someone else.
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            let attributes = try? FileManager.default
                .attributesOfItem(atPath: parent.appendingPathComponent(name).path)
            guard let modified = attributes?[.modificationDate] as? Date else { return false }
            return now.timeIntervalSince(modified) > abandonedAfter
        }
    }

    // MARK: - Helpers

    private func fileURL(_ frameIndex: Int) throws -> URL {
        guard !lock.withLock({ removed }) else { throw PanoramaBlendError.scratchFile("the store was removed") }
        return directory.appendingPathComponent("frame-\(frameIndex).rgba16f")
    }

    private static func validate(_ frame: PanoramaPreparedFrame) throws {
        guard frame.width > 0, frame.height > 0, frame.width <= 1 << 16, frame.height <= 1 << 16 else {
            throw PanoramaBlendError.invalidFrame(frameIndex: frame.frameIndex, reason: "size \(frame.width)x\(frame.height)")
        }
        guard frame.sampleScale.isFinite, frame.sampleScale > 0 else {
            throw PanoramaBlendError.invalidFrame(frameIndex: frame.frameIndex, reason: "sample scale \(frame.sampleScale)")
        }
    }

    private static func removeFolders(in parent: URL, where matches: (String) -> Bool) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        var removedCount = 0
        for name in names where matches(name) {
            if (try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))) != nil { removedCount += 1 }
        }
        return removedCount
    }
}
