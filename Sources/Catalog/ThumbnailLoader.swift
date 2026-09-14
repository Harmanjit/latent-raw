import Foundation
import CoreGraphics
import ImageIO

/// A handle to one thumbnail request. Cancel it when the cell showing the
/// thumbnail scrolls away or is reused.
public final class ThumbnailRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    init() {}

    /// Once this returns, the completion will not be called. (Guaranteed
    /// when called on the main actor, where completions run.)
    public func cancel() {
        lock.withLock { cancelled = true }
    }

    public var isCancelled: Bool {
        lock.withLock { cancelled }
    }
}

/// Decodes the catalog's HEIC thumbnails for display: a byte-bounded
/// memory cache in front of `_latent/thumbnails`, which stays the disk
/// tier (DESIGN.md §10). Ported from minivu's ThumbnailService.
///
/// **Order.** Requests run last-in, first-out. While the user scrolls, the
/// grid asks for every row that flies past; the row they stopped on was
/// asked for last and should be decoded first, not after everything they
/// skipped. A request cancelled before its decode starts (the cell
/// scrolled away) is dropped without decoding, so a fling through twenty
/// thousand images decodes only where it lands.
///
/// **Workers.** Decoding is CPU-bound, so running more decodes than cores
/// only adds contention. Two cores are left for the main thread and the
/// window server, so scrolling stays smooth while thumbnails come in.
///
/// **Sizes.** Files are 512 px; small cells get a 256 px decode, a quarter
/// of the memory. A cached larger tier also satisfies a smaller request,
/// so dragging the size slider reuses what is cached.
///
/// **Display-ready pixels.** Core Animation converts a layer's image to the
/// display's format and colour space on the main thread as the layer
/// commits, and an ImageIO image isn't even decoded until then. So each
/// thumbnail is drawn on the worker, turned by the user's rotation, into
/// exactly what the display wants (`displayColorSpace`, 8-bit BGRA,
/// premultiplied). minivu measured 48 new thumbnails committing in 0.3 ms
/// this way against 33 ms straight from the decoder.
public final class ThumbnailLoader: @unchecked Sendable {
    public static let tiers = [256, Thumbnailer.size]

    /// The smallest tier at least `pixelSize`, else the largest.
    public static func tier(forPixelSize pixelSize: Int) -> Int {
        tiers.first { $0 >= pixelSize } ?? tiers[tiers.count - 1]
    }

    /// A 3:2 thumbnail is about 0.7 MB at 512 px and 0.18 MB at 256 px, so
    /// 256 MB holds a few hundred large ones or well over a thousand small
    /// ones: more than any screen shows. Smaller Macs get less.
    public static var defaultMemoryBytes: Int {
        let physical = Int(clamping: ProcessInfo.processInfo.physicalMemory)
        return min(256 << 20, max(64 << 20, physical / 32))
    }

    /// Reads a file at no more than the given long edge. Replaceable so
    /// tests can count decodes without real files.
    typealias Decoder = @Sendable (URL, Int) -> CGImage?

    private let decode: Decoder
    private let workerLimit: Int
    private let workQueue = DispatchQueue(label: "latent.thumbnails", qos: .userInitiated, attributes: .concurrent)
    private let pressureSource: any DispatchSourceMemoryPressure

    // Everything below is guarded by `lock`.
    private let lock = NSLock()
    private let memory: ByteBoundedCache<CacheKey, CGImage>
    /// Pending work, newest last. A job can appear more than once (it is
    /// pushed again when requested again); `sequence` tells which entry is
    /// current, and stale entries are skipped when popped.
    private var stack: [(job: Job, sequence: UInt64)] = []
    /// Every job not yet finished, so a second request for the same
    /// thumbnail joins the first instead of decoding twice.
    private var jobs: [JobKey: Job] = [:]
    private var runningWorkers = 0
    private var nextSequence: UInt64 = 0
    /// Tests set this to queue several requests before any work starts.
    private var suspended = false
    private var colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    /// Bumped when the colour space changes or everything is dropped, so a
    /// decode that started before can't cache what it drew.
    private var cacheGeneration = 0
    /// Bumped per image by `invalidate`, for the same reason.
    private var generations: [Int64: Int] = [:]
    /// Thumbnails whose file exists but wouldn't decode. Without this the
    /// doomed decode would run again every time the cell scrolled back. A
    /// missing file isn't remembered: generation may still be writing it.
    private var failures: Set<FailureKey> = []
    private var decodes = 0
    private var skippedCancelled = 0

    public convenience init(memoryCacheBytes: Int = ThumbnailLoader.defaultMemoryBytes) {
        self.init(memoryCacheBytes: memoryCacheBytes,
                  workerLimit: max(2, ProcessInfo.processInfo.activeProcessorCount - 2),
                  decode: ThumbnailLoader.decodeFile)
    }

    /// `workerLimit` and `decode` are adjustable for tests, which use one
    /// worker to check the order work runs in.
    init(memoryCacheBytes: Int, workerLimit: Int, decode: @escaping Decoder) {
        memory = ByteBoundedCache(budget: memoryCacheBytes)
        self.workerLimit = max(1, workerLimit)
        self.decode = decode
        // The cache isn't an NSCache, so it gives memory back itself when
        // the system asks: half on a warning, everything when critical.
        pressureSource = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: workQueue)
        pressureSource.setEventHandler { [weak self] in self?.memoryPressureChanged() }
        pressureSource.activate()
    }

    deinit {
        pressureSource.cancel()
    }

    // MARK: - Public API

    /// The colour space thumbnails are drawn in: the grid's screen's. Setting
    /// a different one empties the memory cache; setting the same one again
    /// does nothing, which matters because screens "change" often.
    public var displayColorSpace: CGColorSpace {
        get { lock.withLock { colorSpace } }
        set {
            lock.withLock {
                guard newValue != colorSpace else { return }
                colorSpace = newValue
                cacheGeneration += 1
                memory.removeAll()
            }
        }
    }

    /// A thumbnail already in memory, for drawing a cell synchronously
    /// without a placeholder flash. A larger tier also satisfies the
    /// request (the layer scales it down).
    public func cachedImage(id: Int64, quarterTurns: Int, pixelSize: Int) -> CGImage? {
        let wanted = Self.tier(forPixelSize: pixelSize)
        let turns = Self.normalized(quarterTurns)
        return lock.withLock { cachedLocked(id: id, tier: wanted, turns: turns) }
    }

    private func cachedLocked(id: Int64, tier wanted: Int, turns: Int) -> CGImage? {
        for tier in Self.tiers where tier >= wanted {
            if let image = memory.value(forKey: CacheKey(id: id, tier: tier, turns: turns)) { return image }
        }
        return nil
    }

    /// Asks for the thumbnail at `url`, at least `pixelSize` on its long
    /// edge and turned clockwise by `quarterTurns`.
    ///
    /// `completion` runs on the main actor, with nil if the file is missing
    /// or can't be decoded, and never after the request is cancelled.
    @discardableResult
    public func request(id: Int64, url: URL, quarterTurns: Int, pixelSize: Int,
                        completion: @escaping @MainActor @Sendable (CGImage?) -> Void) -> ThumbnailRequest {
        let request = ThumbnailRequest()
        let waiter = Waiter(request: request, completion: completion)
        let tier = Self.tier(forPixelSize: pixelSize)
        let key = JobKey(id: id, tier: tier, turns: Self.normalized(quarterTurns))

        lock.lock()
        if let image = cachedLocked(id: id, tier: tier, turns: key.turns) {
            lock.unlock()
            Self.deliver(image, to: [waiter])
            return request
        }
        let generation = generations[id] ?? 0
        if failures.contains(FailureKey(id: id, tier: tier, generation: generation)) {
            lock.unlock()
            Self.deliver(nil, to: [waiter])
            return request
        }
        let job: Job
        if let existing = jobs[key], existing.generation == generation, existing.cacheGeneration == cacheGeneration {
            // Join the job already queued or running. If it's still queued,
            // the push below moves it to the top of the stack.
            job = existing
        } else {
            job = Job(key: key, url: url, generation: generation, cacheGeneration: cacheGeneration)
            jobs[key] = job
        }
        job.waiters.append(waiter)
        var startWorker = false
        if !job.started {
            nextSequence += 1
            job.sequence = nextSequence
            stack.append((job, nextSequence))
            startWorker = !suspended && runningWorkers < workerLimit
            if startWorker { runningWorkers += 1 }
        }
        lock.unlock()

        if startWorker { workQueue.async { self.workerLoop() } }
        return request
    }

    /// Forgets images' thumbnails after their files were regenerated. A
    /// request made after this always decodes the file again. One pass for
    /// the whole set, so a big regeneration doesn't walk the cache per image.
    public func invalidate(ids: Set<Int64>) {
        guard !ids.isEmpty else { return }
        lock.withLock {
            for id in ids { generations[id, default: 0] += 1 }
            memory.removeAll { ids.contains($0.id) }
            failures = failures.filter { !ids.contains($0.id) }
            for (key, job) in jobs where ids.contains(key.id) {
                // A decode already running read the old file: new requests
                // start afresh. One still queued hasn't read anything yet,
                // so it simply counts as new.
                if job.started { jobs[key] = nil } else { job.generation = generations[key.id] ?? 0 }
            }
        }
    }

    /// Drops everything, for a catalog switch: image ids now name other
    /// images. Queued requests complete with nil; running decodes finish
    /// but aren't cached.
    public func removeAll() {
        let orphans: [Waiter] = lock.withLock {
            cacheGeneration += 1
            memory.removeAll()
            failures.removeAll()
            generations.removeAll()
            let queued = jobs.values.filter { !$0.started }
            let waiters = queued.flatMap(\.waiters)
            for job in queued { job.waiters.removeAll() }
            jobs.removeAll()
            stack.removeAll()
            return waiters
        }
        Self.deliver(nil, to: orphans)
    }

    // MARK: - Test hooks

    /// While suspended, requests queue up but no decode starts. Only for
    /// tests, which need several requests queued at once to check ordering.
    func setSuspended(_ value: Bool) {
        let toStart: Int = lock.withLock {
            suspended = value
            let count = value ? 0 : max(0, min(workerLimit - runningWorkers, stack.count))
            runningWorkers += count
            return count
        }
        for _ in 0..<toStart { workQueue.async { self.workerLoop() } }
    }

    /// Files decoded, and queued requests dropped undecoded because every
    /// waiter had cancelled.
    var statistics: (decodes: Int, skippedCancelled: Int) {
        lock.withLock { (decodes, skippedCancelled) }
    }

    var cachedBytes: Int { lock.withLock { memory.totalCost } }

    // MARK: - Work

    /// Runs jobs until the stack is empty. Each worker is one block on the
    /// concurrent queue; there are never more than `workerLimit` of them,
    /// and none exist while there is nothing to do.
    private func workerLoop() {
        while let job = nextJob() {
            let image = produce(job)
            let waiters: [Waiter] = lock.withLock {
                if jobs[job.key] === job { jobs[job.key] = nil }
                return job.waiters
            }
            Self.deliver(image, to: waiters)
        }
    }

    /// Pops the newest job that still has someone waiting for it. Stops the
    /// worker (inside the lock, so no request can slip in unseen) when the
    /// stack is empty.
    private func nextJob() -> Job? {
        lock.lock(); defer { lock.unlock() }
        while let top = stack.popLast() {
            let job = top.job
            guard !job.started, job.sequence == top.sequence else { continue }   // a stale duplicate
            job.waiters.removeAll { $0.request.isCancelled }
            if job.waiters.isEmpty {
                if jobs[job.key] === job { jobs[job.key] = nil }
                skippedCancelled += 1
                continue
            }
            job.started = true
            return job
        }
        runningWorkers -= 1
        return nil
    }

    /// Memory, then another rotation of the same thumbnail already in
    /// memory (a turn is far cheaper than a HEIC decode), then the file.
    private func produce(_ job: Job) -> CGImage? {
        let key = job.key
        let (space, generation, cacheGeneration, cached, other): (CGColorSpace, Int, Int, CGImage?, (CGImage, Int)?) = lock.withLock {
            let cached = memory.value(forKey: CacheKey(id: key.id, tier: key.tier, turns: key.turns))
            var other: (CGImage, Int)?
            if cached == nil {
                for turns in 0..<4 where turns != key.turns {
                    if let image = memory.value(forKey: CacheKey(id: key.id, tier: key.tier, turns: turns)) {
                        other = (image, turns)
                        break
                    }
                }
            }
            return (colorSpace, job.generation, self.cacheGeneration, cached, other)
        }
        if let cached { return cached }

        let image: CGImage
        if let (base, baseTurns) = other {
            image = Self.displayReady(base, quarterTurns: key.turns - baseTurns, in: space)
        } else {
            lock.withLock { decodes += 1 }
            guard let decoded = decode(job.url, key.tier) else {
                if FileManager.default.fileExists(atPath: job.url.path) {
                    lock.withLock {
                        if generation == (generations[key.id] ?? 0) {
                            _ = failures.insert(FailureKey(id: key.id, tier: key.tier, generation: generation))
                        }
                    }
                }
                return nil
            }
            image = Self.displayReady(decoded, quarterTurns: key.turns, in: space)
        }

        lock.withLock {
            // Invalidated, recoloured or dropped while drawing: this picture
            // may be of the old file, in the old space, or of another image.
            guard cacheGeneration == self.cacheGeneration, generation == (generations[key.id] ?? 0) else { return }
            memory.insert(image, forKey: CacheKey(id: key.id, tier: key.tier, turns: key.turns),
                          cost: image.bytesPerRow * image.height)
        }
        return image
    }

    private func memoryPressureChanged() {
        let critical = pressureSource.data.contains(.critical)
        lock.withLock {
            if critical { memory.removeAll() } else { memory.evict(downTo: memory.totalCost / 2) }
        }
    }

    /// Calls completions on the main actor, skipping cancelled requests.
    /// The cancel check happens on the main actor, right before the call,
    /// which is what makes "never after cancel()" hold for main-actor callers.
    private static func deliver(_ image: CGImage?, to waiters: [Waiter]) {
        guard !waiters.isEmpty else { return }
        let boxed = image.map(ThumbnailImage.init)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for waiter in waiters where !waiter.request.isCancelled {
                    waiter.completion(boxed?.cgImage)
                }
            }
        }
    }

    // MARK: - Pixels

    /// Reads a thumbnail file, decoded now rather than lazily at first draw.
    static let decodeFile: Decoder = { url, maxPixelSize in
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Bitmap layout Core Animation composites without converting.
    static let displayBitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    /// `image` turned clockwise by `quarterTurns` and redrawn as 8-bit BGRA,
    /// premultiplied, in `space`; ColorSync converts from the image's own
    /// profile. Returns `image` itself when it already is exactly that.
    static func displayReady(_ image: CGImage, quarterTurns: Int, in space: CGColorSpace) -> CGImage {
        let turns = normalized(quarterTurns)
        if turns == 0, image.bitsPerComponent == 8, image.bitsPerPixel == 32,
           image.bitmapInfo.rawValue == displayBitmapInfo, image.colorSpace == space {
            return image
        }
        let w = image.width, h = image.height
        let swap = turns % 2 == 1
        let outW = swap ? h : w, outH = swap ? w : h
        guard let context = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: displayBitmapInfo)
            ?? CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: displayBitmapInfo)
        else { return Thumbnailer.rotated(image, quarterTurns: turns) }
        // Whole quarter turns land every pixel on a pixel: nothing to filter.
        context.interpolationQuality = .none
        context.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        // CGContext's y axis points up, so a visual clockwise turn is a
        // negative rotation.
        context.rotate(by: -CGFloat(turns) * .pi / 2)
        context.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return context.makeImage() ?? image
    }

    static func normalized(_ quarterTurns: Int) -> Int {
        ((quarterTurns % 4) + 4) % 4
    }

    // MARK: - Types

    private struct CacheKey: Hashable {
        let id: Int64
        let tier: Int
        let turns: Int
    }

    private struct JobKey: Hashable {
        let id: Int64
        let tier: Int
        let turns: Int
    }

    private struct FailureKey: Hashable {
        let id: Int64
        let tier: Int
        let generation: Int
    }

    private struct Waiter: Sendable {
        let request: ThumbnailRequest
        let completion: @MainActor @Sendable (CGImage?) -> Void
    }

    /// Mutable, but only touched while holding the loader's lock.
    private final class Job: @unchecked Sendable {
        let key: JobKey
        let url: URL
        var generation: Int
        let cacheGeneration: Int
        var waiters: [Waiter] = []
        var started = false
        var sequence: UInt64 = 0

        init(key: JobKey, url: URL, generation: Int, cacheGeneration: Int) {
            self.key = key
            self.url = url
            self.generation = generation
            self.cacheGeneration = cacheGeneration
        }
    }
}
