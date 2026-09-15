// One IFD, as a value: its entries and, optionally, the image chunks whose
// offsets it lists.

import Foundation

/// Where a directory's pixels come from.
///
/// A TIFF image is cut into *chunks*: horizontal strips, or square tiles.
/// Each is written as one contiguous run of bytes, and the directory lists
/// every chunk's offset and byte count. `produce` is called once, while the
/// file is written, and hands the chunks to `emit` in order; nothing is
/// asked for before then, so a 45 MP image never has to be in memory as a
/// whole, and a compressed chunk's size doesn't have to be known in advance.
struct TIFFImageData {
    /// How many chunks `produce` emits. Fixed up front because it decides
    /// the size of the offset and byte-count entries, and so the layout.
    let chunkCount: Int
    /// The most bytes all chunks together can take, for the free-space
    /// check and the 4 GB limit before writing starts. Exact when the
    /// chunks are uncompressed.
    let maximumByteCount: Int
    /// Emits exactly `chunkCount` chunks, in order.
    let produce: (_ emit: (UnsafeRawBufferPointer) throws -> Void) throws -> Void
}

/// One Image File Directory.
///
/// Not Sendable: the image data's closure may capture a texture. A file is
/// built and written on one thread, so it never needs to be.
struct TIFFDirectory {
    /// Entries by tag. TIFF requires them sorted by tag in the file, which
    /// the serialiser does; a dictionary makes "set replaces" natural.
    private(set) var entries: [UInt16: TIFFValue] = [:]

    /// The pixels, if this directory has any.
    var imageData: TIFFImageData?

    mutating func set(_ tag: UInt16, _ value: TIFFValue) { entries[tag] = value }
    mutating func set(_ tag: UInt16, short value: UInt16) { set(tag, .shorts([value])) }
    mutating func set(_ tag: UInt16, long value: UInt32) { set(tag, .longs([value])) }
    mutating func set(_ tag: UInt16, ascii value: String) { set(tag, .ascii(value)) }

    var sortedTags: [UInt16] { entries.keys.sorted() }

    /// Child directories, in tag order.
    var children: [TIFFDirectory] {
        sortedTags.flatMap { tag -> [TIFFDirectory] in
            if case .directories(let children)? = entries[tag] { return children }
            return []
        }
    }

    /// The count written in an entry: elements, not bytes. ASCII counts
    /// its NUL; references count the chunks they describe.
    func count(of value: TIFFValue) -> Int {
        switch value {
        case .bytes(let v), .undefined(let v): return v.count
        case .ascii(let s): return s.utf8.count + 1
        case .shorts(let v): return v.count
        case .longs(let v): return v.count
        case .rationals(let v): return v.count
        case .slongs(let v): return v.count
        case .srationals(let v): return v.count
        case .floats(let v): return v.count
        case .doubles(let v): return v.count
        case .directories(let v): return v.count
        case .imageChunkOffsets, .imageChunkByteCounts: return imageData?.chunkCount ?? 0
        }
    }

    func byteLength(of value: TIFFValue) -> Int { count(of: value) * value.type.elementSize }

    /// Size of the directory itself: a 2-byte entry count, 12 bytes per
    /// entry, and the 4-byte offset of the next directory in the chain.
    var directorySize: Int { 2 + 12 * entries.count + 4 }
}
