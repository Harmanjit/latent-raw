import Foundation
import CoreGraphics

/// Pictures the thumbnail pass would otherwise have to make again, handed
/// over by whoever already had them (docs/Performance-Plan.md #28, #29):
///
/// - the camera's embedded JPEG, which a reconcile pass already carried
///   across XPC to read the file's metadata. Without it the thumbnail pass
///   opens the file over XPC a second time just to fetch the same JPEG.
/// - an edited image rendered from the editor's live session when its
///   edit settled, so the pass needn't decode the raw again (268 ms).
///
/// Both are a cache the pass may use or ignore: an entry only counts when
/// it matches what the pass would make (the file's content hash, the
/// edit's thumbnail key), and every miss falls back to the normal path.
///
/// Memory is bounded. Previews are kept up to `previewBudget` bytes; once
/// that's full new ones are refused rather than older ones evicted, so
/// the pass, which works through files in the order they were catalogued,
/// meets the held ones first and frees them early. Rendered images are a
/// handful of 512 px pictures. Everything is dropped on memory pressure.
public final class ThumbnailHandoff: @unchecked Sendable {
    /// About 190 typical 24 MP previews.
    public static let defaultPreviewBudget = 192 << 20
    /// Settled edits waiting for the pass; one per image.
    static let renderedLimit = 8

    private struct Preview {
        let hash: Data
        let jpeg: Data
        let orientation: Int
    }
    private struct Rendered {
        let key: Data
        let image: CGImage
    }

    private let lock = NSLock()
    private let previewBudget: Int
    private var previews: [String: Preview] = [:]
    private var previewBytes = 0
    private var rendered: [Int64: Rendered] = [:]
    /// Oldest first, for the limit.
    private var renderedOrder: [Int64] = []
    private let pressureSource: any DispatchSourceMemoryPressure

    public init(previewBudget: Int = ThumbnailHandoff.defaultPreviewBudget) {
        self.previewBudget = max(0, previewBudget)
        pressureSource = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                                 queue: .global(qos: .utility))
        pressureSource.setEventHandler { [weak self] in self?.discardAll() }
        pressureSource.activate()
    }

    deinit { pressureSource.cancel() }

    // MARK: - Embedded previews

    /// Holds `jpeg` for the thumbnail of the file at `relPath`, whose
    /// content hash is `hash` and LibRaw orientation (`flip`) is
    /// `orientation`. Returns false when it isn't kept (the budget is
    /// full); the pass then reads the file itself, as it always did.
    @discardableResult
    public func offerPreview(_ jpeg: Data, orientation: Int, relPath: String, hash: Data) -> Bool {
        lock.withLock {
            let previous = previews[relPath]?.jpeg.count ?? 0
            guard previewBytes - previous + jpeg.count <= previewBudget else {
                // A stale one for an older version of the file mustn't stay.
                if previews.removeValue(forKey: relPath) != nil { previewBytes -= previous }
                return false
            }
            previews[relPath] = Preview(hash: hash, jpeg: jpeg, orientation: orientation)
            previewBytes += jpeg.count - previous
            return true
        }
    }

    /// The preview held for `relPath` and its orientation, removed from
    /// the handoff. Nil when there's none, or the one there is for other
    /// content.
    public func takePreview(relPath: String, hash: Data) -> (jpeg: Data, orientation: Int)? {
        lock.withLock {
            guard let entry = previews.removeValue(forKey: relPath) else { return nil }
            previewBytes -= entry.jpeg.count
            return entry.hash == hash ? (entry.jpeg, entry.orientation) : nil
        }
    }

    /// Drops the previews held for these images: a pass went through them
    /// and didn't take them (they have an edit, or failed).
    public func discardPreviews<S: Sequence>(forRelPaths relPaths: S) where S.Element == String {
        lock.withLock {
            for relPath in relPaths {
                if let entry = previews.removeValue(forKey: relPath) { previewBytes -= entry.jpeg.count }
            }
        }
    }

    /// Bytes of previews held now.
    public var previewBytesHeld: Int { lock.withLock { previewBytes } }

    // MARK: - Rendered edits

    /// Holds an edited image's thumbnail, rendered for the edit whose
    /// thumbnail key is `key` (`Thumbnailer.key(forEditStack:)`). Replaces
    /// any held for the same image.
    public func offerRendered(_ image: CGImage, imageID: Int64, key: Data) {
        lock.withLock {
            if rendered.updateValue(Rendered(key: key, image: image), forKey: imageID) != nil {
                renderedOrder.removeAll { $0 == imageID }
            }
            renderedOrder.append(imageID)
            while renderedOrder.count > Self.renderedLimit {
                rendered.removeValue(forKey: renderedOrder.removeFirst())
            }
        }
    }

    /// The image held for `imageID`, removed from the handoff, if it was
    /// rendered for the edit keyed `key`; a stale one is dropped.
    public func takeRendered(imageID: Int64, key: Data) -> CGImage? {
        lock.withLock {
            guard let entry = rendered.removeValue(forKey: imageID) else { return nil }
            renderedOrder.removeAll { $0 == imageID }
            return entry.key == key ? entry.image : nil
        }
    }

    public func discardAll() {
        lock.withLock {
            previews.removeAll()
            previewBytes = 0
            rendered.removeAll()
            renderedOrder.removeAll()
        }
    }
}
