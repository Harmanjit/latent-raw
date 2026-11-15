import Foundation

/// One directory's entries with what reconcile needs of each, in one
/// `getattrlistbulk` pass: name, kind, size, modification and status-change
/// times, and the file flags (hidden, dataless).
///
/// `FileManager.contentsOfDirectory(at:includingPropertiesForKeys:)` gets
/// most of this in bulk too, but asking it for the iCloud download status
/// costs about 70 µs a file, most of a 2,000-file folder refresh. The
/// dataless flag says the same for every file provider of today's macOS.
struct DirectoryListing {
    enum Kind: Equatable { case file, directory, symbolicLink, other }

    struct Entry: Equatable {
        var name: String
        var kind: Kind
        var size: Int64
        /// `st_mtimespec` and `st_ctimespec`.
        var modified: timespec
        var changed: timespec
        var flags: UInt32

        /// Finder's notion, as `.skipsHiddenFiles` applies it: a dot name
        /// or the hidden flag.
        var isHidden: Bool { name.hasPrefix(".") || flags & UInt32(UF_HIDDEN) != 0 }
        var isDataless: Bool { flags & UInt32(SF_DATALESS) != 0 }

        static func == (a: Entry, b: Entry) -> Bool {
            a.name == b.name && a.kind == b.kind && a.size == b.size && a.flags == b.flags
                && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
                && a.changed.tv_sec == b.changed.tv_sec && a.changed.tv_nsec == b.changed.tv_nsec
        }
    }

    /// The entries of `directory`, in no particular order, `.` and `..` not
    /// among them. Throws when the directory can't be read.
    static func entries(of directory: URL) throws -> [Entry] {
        let fd = directory.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_DIRECTORY) } ?? -1
        }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR)
            | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME)
            | attrgroup_t(ATTR_CMN_CHGTIME) | attrgroup_t(ATTR_CMN_FLAGS)
        request.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)

        let capacity = 128 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }
        var entries: [Entry] = []
        while true {
            let count = getattrlistbulk(fd, &request, buffer, capacity, 0)
            if count < 0 {
                if errno == EINTR { continue }
                // A file system that can't list in bulk is listed name by
                // name instead.
                if entries.isEmpty, errno == ENOTSUP || errno == EINVAL { return try slowEntries(of: directory) }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            var record = buffer
            for _ in 0..<count {
                let length = Int(record.loadUnaligned(as: UInt32.self))
                if let (entry, complete) = parse(record) {
                    entries.append(complete ? entry : stat(entry, in: directory))
                }
                record += length
            }
        }
        return entries
    }

    /// One packed record, laid out in the order the attributes' bits come
    /// (getattrlist(2)): length, returned set, error, name, type, times,
    /// flags, then the data length for files. `complete` is false when the
    /// file system couldn't describe the entry fully.
    private static func parse(_ record: UnsafeMutableRawPointer) -> (Entry, complete: Bool)? {
        var at = record + MemoryLayout<UInt32>.size
        let returned = at.loadUnaligned(as: attribute_set_t.self)
        at += MemoryLayout<attribute_set_t>.size
        func has(_ bit: Int32) -> Bool { returned.commonattr & attrgroup_t(bit) != 0 }

        var error: UInt32 = 0
        if has(ATTR_CMN_ERROR) {
            error = at.loadUnaligned(as: UInt32.self)
            at += MemoryLayout<UInt32>.size
        }
        guard has(ATTR_CMN_NAME) else { return nil }
        let nameRef = at.loadUnaligned(as: attrreference_t.self)
        let namePointer = (at + Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
        let name = String(cString: namePointer)
        at += MemoryLayout<attrreference_t>.size
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        var kind = Kind.other
        if has(ATTR_CMN_OBJTYPE) {
            switch Int(at.loadUnaligned(as: fsobj_type_t.self)) {
            case Int(VREG.rawValue): kind = .file
            case Int(VDIR.rawValue): kind = .directory
            case Int(VLNK.rawValue): kind = .symbolicLink
            default: kind = .other
            }
            at += MemoryLayout<fsobj_type_t>.size
        }
        var modified = timespec()
        if has(ATTR_CMN_MODTIME) {
            modified = at.loadUnaligned(as: timespec.self)
            at += MemoryLayout<timespec>.size
        }
        var changed = timespec()
        if has(ATTR_CMN_CHGTIME) {
            changed = at.loadUnaligned(as: timespec.self)
            at += MemoryLayout<timespec>.size
        }
        var flags: UInt32 = 0
        if has(ATTR_CMN_FLAGS) {
            flags = at.loadUnaligned(as: UInt32.self)
            at += MemoryLayout<UInt32>.size
        }
        var size: Int64 = 0
        if returned.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 {
            size = at.loadUnaligned(as: off_t.self)
        }
        let entry = Entry(name: name, kind: kind, size: size, modified: modified, changed: changed, flags: flags)
        let complete = error == 0 && has(ATTR_CMN_OBJTYPE) && has(ATTR_CMN_MODTIME) && has(ATTR_CMN_CHGTIME)
            && has(ATTR_CMN_FLAGS) && (kind != .file || returned.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0)
        return (entry, complete)
    }

    /// The same from a plain listing and an `lstat` per entry.
    static func slowEntries(of directory: URL) throws -> [Entry] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).map {
            stat(Entry(name: $0, kind: .other, size: 0, modified: timespec(), changed: timespec(), flags: 0),
                 in: directory)
        }
    }

    /// An entry described again by `lstat`; one that can't be is `.other`,
    /// which reconcile skips.
    private static func stat(_ entry: Entry, in directory: URL) -> Entry {
        var info = Darwin.stat()
        let path = directory.appendingPathComponent(entry.name).path
        guard lstat(path, &info) == 0 else {
            var skipped = entry
            skipped.kind = .other
            return skipped
        }
        let kind: Kind = switch info.st_mode & S_IFMT {
        case S_IFREG: .file
        case S_IFDIR: .directory
        case S_IFLNK: .symbolicLink
        default: .other
        }
        return Entry(name: entry.name, kind: kind, size: kind == .file ? Int64(info.st_size) : 0,
                     modified: info.st_mtimespec,
                     changed: info.st_ctimespec, flags: info.st_flags)
    }

    /// The date Foundation gives for `ts` (as `URLResourceValues` and
    /// `FileManager.attributesOfItem` compute it, to the bit), so a time
    /// read here and one read through Foundation compare equal.
    static func date(_ ts: timespec) -> Date {
        Date(timeIntervalSinceReferenceDate: Double(ts.tv_sec) - Date.timeIntervalBetween1970AndReferenceDate
             + 1.0e-9 * Double(ts.tv_nsec))
    }
}
