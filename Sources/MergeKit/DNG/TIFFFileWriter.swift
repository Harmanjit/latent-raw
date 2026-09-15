// Lays out a tree of TIFF directories and writes it, with its image chunks,
// to an open file.
//
// How a file is produced:
//   1. `TIFFLayout` walks the directory tree and gives every directory and
//      every value too big to sit inside its entry a file offset. That works
//      before any pixel exists because references (child directory offsets,
//      chunk offsets and byte counts) are always 4-byte LONGs whose count is
//      known, so no size depends on an offset.
//   2. The image chunks are written after that metadata region, one at a
//      time, recording where each one landed and how long it was.
//   3. Only then is the metadata serialised, with every reference resolved,
//      and written into the space left for it at the start of the file.
//
// Writing the metadata last is what lets a compressed tile be written the
// moment it's compressed: its size is needed in the directory, and the
// directory isn't written until the end. The file is a temporary one until
// `SafeFileWriter` commits it, so its unfinished state is never seen.
//
// TIFF 6.0 rules followed: little-endian ("II"); entries sorted by tag; a
// value of 4 bytes or less sits in the entry, left-justified; anything
// longer is written elsewhere and the entry holds its offset; every offset
// is even ("on a word boundary"). Classic TIFF offsets are 32-bit, so a file
// can't reach 4 GB (a 45 MP merge is about 270 MB).

import Foundation

/// Where every directory and out-of-line value goes.
struct TIFFLayout {
    struct Node {
        var directory: TIFFDirectory
        /// File offset of the directory.
        var offset = 0
        /// File offset of each entry whose value doesn't fit in 4 bytes.
        var valueOffsets: [UInt16: Int] = [:]
        /// For entries holding child directories: the children's node indices.
        var childNodes: [UInt16: [Int]] = [:]
        /// The next directory in the top-level chain (IFD0 -> IFD1 ...).
        var nextInChain: Int?
        /// Filled while the chunks are written.
        var chunkOffsets: [Int] = []
        var chunkByteCounts: [Int] = []
    }

    /// Every directory, depth first: a parent before its children, so
    /// offsets grow as a reader walks down the tree.
    private(set) var nodes: [Node] = []
    /// Header, directories and out-of-line values: the bytes before the first chunk.
    let metadataSize: Int
    /// The file's size if every chunk takes its maximum.
    let maximumFileSize: Int

    init(topLevel: [TIFFDirectory]) throws {
        var nodes: [Node] = []
        func visit(_ directory: TIFFDirectory) -> Int {
            let index = nodes.count
            nodes.append(Node(directory: directory))
            for tag in directory.sortedTags {
                guard case .directories(let children)? = directory.entries[tag] else { continue }
                nodes[index].childNodes[tag] = children.map(visit)
            }
            return index
        }
        let roots = topLevel.map(visit)
        for (position, root) in roots.enumerated() where position + 1 < roots.count {
            nodes[root].nextInChain = roots[position + 1]
        }

        var cursor = 8 // the header
        for index in nodes.indices {
            cursor = Self.wordAligned(cursor)
            nodes[index].offset = cursor
            let directory = nodes[index].directory
            cursor += directory.directorySize
            for tag in directory.sortedTags {
                // Always found: the tag came from the dictionary's own keys.
                guard let value = directory.entries[tag] else { continue }
                let length = directory.byteLength(of: value)
                if length > 4 {
                    cursor = Self.wordAligned(cursor)
                    nodes[index].valueOffsets[tag] = cursor
                    cursor += length
                }
            }
        }
        metadataSize = Self.wordAligned(cursor)
        // Each chunk may need one padding byte to start on an even offset.
        maximumFileSize = nodes.reduce(metadataSize) { total, node in
            guard let data = node.directory.imageData else { return total }
            return total + data.maximumByteCount + data.chunkCount
        }
        guard maximumFileSize <= Int(UInt32.max) else { throw MergeDNGError.fileTooLarge(bytes: maximumFileSize) }
        self.nodes = nodes
    }

    static func wordAligned(_ offset: Int) -> Int { (offset + 1) & ~1 }

    /// Writes the chunks, then the metadata, to `sink`. Returns the file size.
    mutating func write(to sink: inout FileSink) throws -> Int {
        try sink.seek(to: metadataSize)
        for index in nodes.indices {
            guard let data = nodes[index].directory.imageData else { continue }
            var offsets: [Int] = [], counts: [Int] = []
            offsets.reserveCapacity(data.chunkCount)
            counts.reserveCapacity(data.chunkCount)
            try data.produce { chunk in
                guard offsets.count < data.chunkCount else {
                    throw MergeDNGError.internalInconsistency("more image chunks than the directory lists")
                }
                if sink.position % 2 == 1 { try sink.write([0]) }
                guard sink.position + chunk.count <= Int(UInt32.max) else {
                    throw MergeDNGError.fileTooLarge(bytes: sink.position + chunk.count)
                }
                offsets.append(sink.position)
                counts.append(chunk.count)
                try sink.write(chunk)
            }
            guard offsets.count == data.chunkCount else {
                throw MergeDNGError.internalInconsistency("fewer image chunks than the directory lists")
            }
            nodes[index].chunkOffsets = offsets
            nodes[index].chunkByteCounts = counts
        }
        let fileSize = sink.position
        try sink.write(metadataBytes(), at: 0)
        return fileSize
    }

    /// The header and every directory, references resolved. Call after the
    /// chunks are written, when their offsets and sizes are known.
    func metadataBytes() throws -> [UInt8] {
        var out = ByteWriter(capacity: metadataSize)
        out.append([0x49, 0x49])        // "II": little-endian byte order
        out.append(UInt16(42))          // the TIFF magic number
        out.append(UInt32(nodes.first?.offset ?? 0))

        for node in nodes {
            try out.pad(to: node.offset)
            let directory = node.directory
            let tags = directory.sortedTags
            out.append(UInt16(tags.count))
            for tag in tags {
                guard let value = directory.entries[tag] else { continue }
                out.append(tag)
                out.append(value.type.rawValue)
                out.append(UInt32(directory.count(of: value)))
                if let valueOffset = node.valueOffsets[tag] {
                    out.append(UInt32(valueOffset))
                } else {
                    // Fits in the entry: left-justified, zero padded to 4 bytes.
                    var inline = ByteWriter(capacity: 4)
                    try serialize(value, tag: tag, of: node, to: &inline)
                    out.append(inline.bytes)
                    out.append([UInt8](repeating: 0, count: 4 - inline.bytes.count))
                }
            }
            // Child directories end their own chain: only top-level ones link on.
            out.append(UInt32(node.nextInChain.map { nodes[$0].offset } ?? 0))

            for tag in tags {
                guard let valueOffset = node.valueOffsets[tag], let value = directory.entries[tag] else { continue }
                try out.pad(to: valueOffset)
                try serialize(value, tag: tag, of: node, to: &out)
            }
        }
        try out.pad(to: metadataSize)
        return out.bytes
    }

    private func serialize(_ value: TIFFValue, tag: UInt16, of node: Node, to out: inout ByteWriter) throws {
        switch value {
        case .bytes(let v), .undefined(let v): out.append(v)
        case .ascii(let s): out.append(Array(s.utf8) + [0])
        case .shorts(let v): v.forEach { out.append($0) }
        case .longs(let v): v.forEach { out.append($0) }
        case .rationals(let v): v.forEach { out.append($0.numerator); out.append($0.denominator) }
        case .slongs(let v): v.forEach { out.append(UInt32(bitPattern: $0)) }
        case .srationals(let v):
            v.forEach { out.append(UInt32(bitPattern: $0.numerator)); out.append(UInt32(bitPattern: $0.denominator)) }
        case .floats(let v): v.forEach { out.append($0.bitPattern) }
        case .doubles(let v): v.forEach { out.append($0.bitPattern) }
        case .directories:
            (node.childNodes[tag] ?? []).forEach { out.append(UInt32(nodes[$0].offset)) }
        case .imageChunkOffsets, .imageChunkByteCounts:
            let list: [Int]
            if case .imageChunkOffsets = value { list = node.chunkOffsets } else { list = node.chunkByteCounts }
            guard list.count == node.directory.imageData?.chunkCount else {
                throw MergeDNGError.internalInconsistency("chunk list for tag \(tag) written before its chunks")
            }
            list.forEach { out.append(UInt32($0)) }
        }
    }
}

/// Appends little-endian values to a byte array.
struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    init(capacity: Int) { bytes.reserveCapacity(capacity) }

    mutating func append(_ b: [UInt8]) { bytes.append(contentsOf: b) }
    mutating func append<T: FixedWidthInteger>(_ v: T) {
        withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) }
    }

    /// Zero-fills up to `offset`. Going backwards would mean the layout and
    /// the serialiser disagree about a size, which must not produce a file.
    mutating func pad(to offset: Int) throws {
        guard offset >= bytes.count else {
            throw MergeDNGError.internalInconsistency("layout expected offset \(offset), serialiser is at \(bytes.count)")
        }
        bytes.append(contentsOf: repeatElement(0, count: offset - bytes.count))
    }
}

/// A file descriptor opened for writing, with POSIX errors turned into
/// thrown ones. `write(2)` may write fewer bytes than asked (a signal, a
/// pipe), so both writes loop until everything is out.
struct FileSink {
    let descriptor: Int32
    private(set) var position = 0

    init(descriptor: Int32) { self.descriptor = descriptor }

    mutating func seek(to offset: Int) throws {
        guard lseek(descriptor, off_t(offset), SEEK_SET) >= 0 else { throw Self.posixError() }
        position = offset
    }

    mutating func write(_ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { try write($0) }
    }

    mutating func write(_ buffer: UnsafeRawBufferPointer) throws {
        guard let base = buffer.baseAddress else { return }
        var done = 0
        while done < buffer.count {
            let n = Darwin.write(descriptor, base + done, buffer.count - done)
            if n < 0 {
                if errno == EINTR { continue }
                throw Self.posixError()
            }
            done += n
        }
        position += buffer.count
    }

    /// Writes at an absolute offset without moving `position`.
    func write(_ bytes: [UInt8], at offset: Int) throws {
        try bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var done = 0
            while done < buffer.count {
                let n = pwrite(descriptor, base + done, buffer.count - done, off_t(offset + done))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw Self.posixError()
                }
                done += n
            }
        }
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
