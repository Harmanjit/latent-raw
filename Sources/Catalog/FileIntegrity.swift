import Foundation
import GRDB

/// Library › Verify Files: every file read again and its content hash
/// compared with the one the catalog took when it last saw the file
/// change, as Lightroom's Validate DNG Files does for DNGs, but for every
/// file Latent catalogues.
///
/// The catalog already keeps a whole-file XXH64 for every image (FileHash),
/// with the file's size and modification time beside it. Reconcile trusts
/// size and time and never reads a file it thinks it knows, so a file whose
/// bytes changed with neither (a failing disk, a bad copy, a bit flipped in
/// a backup restored with its dates) goes unnoticed until it no longer
/// opens. Verifying reads the bytes and tells three cases apart:
///
/// - **verified**: the hash matches;
/// - **changed**: the size or time differs, so the file was changed on
///   purpose (saved by another app, replaced). Not verification's business:
///   Refresh Folder takes the new hash;
/// - **damaged**: same size, same time, different bytes. Nothing writes a
///   file that way on purpose, so this is silent corruption.
///
/// A missing file and one that can't be read are reported as such.
public enum FileIntegrity {
    public enum Status: String, Sendable, Equatable {
        case verified, changed, damaged, missing, unreadable
    }

    /// One image's result.
    public struct Check: Sendable, Equatable {
        public var imageID: Int64
        public var relPath: String
        public var fileName: String
        public var status: Status
        /// What went wrong for `.unreadable`; nil otherwise.
        public var detail: String?
        /// The row's size and time, recorded with the result so a later
        /// change to the file voids it.
        public var size: Int64
        public var mtime: Int64

        public init(imageID: Int64, relPath: String, fileName: String, status: Status, detail: String? = nil,
                    size: Int64, mtime: Int64) {
            self.imageID = imageID
            self.relPath = relPath
            self.fileName = fileName
            self.status = status
            self.detail = detail
            self.size = size
            self.mtime = mtime
        }
    }

    /// The decision, given what the catalog holds and what the disk says.
    /// `hash` is only called when size and time agree, so a changed file is
    /// never read.
    public static func classify(storedSize: Int64, storedMtime: Int64, storedHash: Data,
                                fileSize: Int64, fileMtime: Int64,
                                hash: () throws -> Data) rethrows -> Status {
        guard fileSize == storedSize, fileMtime == storedMtime else { return .changed }
        return try hash() == storedHash ? .verified : .damaged
    }

    /// Checks one image's file. Virtual copies share their master's file and
    /// are checked through it, so callers pass masters only.
    public static func check(_ record: ImageRecord, fileURL: URL) -> Check {
        func result(_ status: Status, _ detail: String? = nil) -> Check {
            Check(imageID: record.id ?? 0, relPath: record.relPath, fileName: record.fileName, status: status,
                  detail: detail, size: record.size, mtime: record.mtime)
        }
        // A fresh URL: resource values are cached on the URL object.
        let url = URL(fileURLWithPath: fileURL.path)
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        } catch {
            return FileManager.default.fileExists(atPath: url.path) ? result(.unreadable, error.localizedDescription)
                : result(.missing)
        }
        // As reconcile reads them (Reconcile.swift), or every file would
        // count as changed.
        let size = Int64(values.fileSize ?? 0)
        let mtime = ImageRecord.milliseconds(values.contentModificationDate ?? .distantPast)
        do {
            let status = try classify(storedSize: record.size, storedMtime: record.mtime, storedHash: record.xxhash,
                                      fileSize: size, fileMtime: mtime) {
                ImageRecord.hashData(try uncachedXXH64(ofFileAt: url))
            }
            return result(status)
        } catch {
            return result(.unreadable, error.localizedDescription)
        }
    }

    /// The file's XXH64, read from the disk rather than the page cache
    /// (`F_NOCACHE`): a file opened a minute ago would otherwise be hashed
    /// from memory, which proves nothing about the copy on disk. The same
    /// value `FileHash.xxh64(ofFileAt:)` gives.
    public static func uncachedXXH64(ofFileAt url: URL) throws -> UInt64 {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let length = Int(info.st_size)
        var data = Data(count: length)
        let total = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            var done = 0
            while done < length {
                let got = Darwin.read(fd, base + done, length - done)
                if got < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                if got == 0 { break }
                done += got
            }
            return done
        }
        guard total == length else { throw POSIXError(total < 0 ? (POSIXErrorCode(rawValue: errno) ?? .EIO) : .EIO) }
        return FileHash.xxh64(data)
    }

    /// The images a verify run reads for `records`: virtual copies stand
    /// for their master's file, so each file is read once.
    public static func filesToVerify(_ records: [ImageRecord], in all: [ImageRecord]) -> [ImageRecord] {
        var seen = Set<String>()
        var out: [ImageRecord] = []
        let byPath = Dictionary(all.map { ($0.relPath, $0) }, uniquingKeysWith: { first, _ in first })
        for record in records {
            let master = VirtualCopy.parse(record.relPath).flatMap { byPath[$0.masterRelPath] } ?? record
            guard !master.isVirtualCopy, seen.insert(master.relPath).inserted else { continue }
            out.append(master)
        }
        return out
    }
}

/// What a verify run found, for its summary sheet and the library panel.
public struct FileVerificationReport: Sendable, Equatable {
    public var checks: [FileIntegrity.Check] = []
    public var cancelled = false
    public var elapsed: TimeInterval = 0
    /// How many files the run set out to read.
    public var planned = 0

    public init(checks: [FileIntegrity.Check] = [], cancelled: Bool = false, elapsed: TimeInterval = 0, planned: Int = 0) {
        self.checks = checks
        self.cancelled = cancelled
        self.elapsed = elapsed
        self.planned = planned
    }

    public func with(_ status: FileIntegrity.Status) -> [FileIntegrity.Check] {
        checks.filter { $0.status == status }
    }

    /// "Verified 120 files in 14 s · 1 damaged · 2 changed since the last scan".
    public var summary: String {
        let verified = with(.verified).count
        var parts = [(cancelled ? "Verification cancelled · " : "")
                     + "Verified \(verified) file\(verified == 1 ? "" : "s")"
                     + (cancelled ? " of \(planned)" : "") + " in \(Self.duration(elapsed))"]
        let damaged = with(.damaged).count
        if damaged > 0 { parts.append("\(damaged) damaged") }
        let changed = with(.changed).count
        if changed > 0 { parts.append("\(changed) changed since the last scan") }
        let missing = with(.missing).count
        if missing > 0 { parts.append("\(missing) missing") }
        let unreadable = with(.unreadable).count
        if unreadable > 0 { parts.append("\(unreadable) unreadable") }
        return parts.joined(separator: " · ")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(max(1, Int(seconds.rounded()))) s"
            : "\(Int(seconds) / 60) min \(Int(seconds) % 60) s"
    }
}

// MARK: - Duplicates

/// Library › Find Duplicates: photos whose files are byte for byte the same
/// (the catalog's content hash), and, as a looser second tier, photos taken
/// at the same moment with the same camera and pixel size whose files
/// differ (a JPEG re-saved, a raw with rewritten metadata, a copy from
/// another card reader).
///
/// Virtual copies share their master's file on purpose and are never
/// duplicates; they are left out.
public enum DuplicateFinder {
    public struct Group: Sendable, Equatable, Identifiable {
        /// The first record's id.
        public var id: Int64 { records.first?.id ?? 0 }
        /// The one to keep first: edited, then the higher rating, then the
        /// path that sorts first.
        public var records: [ImageRecord]
    }

    /// Groups of identical files, each ordered keep-first, groups ordered by
    /// their first path.
    public static func exactGroups(_ records: [ImageRecord], edited: Set<Int64> = []) -> [Group] {
        var byHash: [Data: [ImageRecord]] = [:]
        for record in records where !record.isVirtualCopy && !record.xxhash.isEmpty {
            byHash[record.xxhash, default: []].append(record)
        }
        return byHash.values.filter { $0.count > 1 }
            .map { Group(records: ordered($0, edited: edited)) }
            .sorted { $0.records[0].relPath < $1.records[0].relPath }
    }

    /// Groups of different files sharing capture time, camera and pixel
    /// size. Of each exact group only the first takes part, so a file and
    /// its byte-identical copy count once here.
    public static func nearGroups(_ records: [ImageRecord], edited: Set<Int64> = []) -> [Group] {
        let exact = exactGroups(records, edited: edited)
        let dropped = Set(exact.flatMap { $0.records.dropFirst().compactMap(\.id) })
        struct Key: Hashable {
            var time: Int64
            var camera: String?
            var width: Int
            var height: Int
        }
        var byKey: [Key: [ImageRecord]] = [:]
        for record in records where !record.isVirtualCopy {
            guard let id = record.id, !dropped.contains(id), let time = record.captureTime,
                  let width = record.width, let height = record.height else { continue }
            byKey[Key(time: time, camera: record.camera, width: width, height: height), default: []].append(record)
        }
        return byKey.values.filter { $0.count > 1 }
            .map { Group(records: ordered($0, edited: edited)) }
            .sorted { $0.records[0].relPath < $1.records[0].relPath }
    }

    /// Every record in `groups` but the first of each: what Select All but
    /// First selects.
    public static func allButFirst(_ groups: [Group]) -> [Int64] {
        groups.flatMap { $0.records.dropFirst().compactMap(\.id) }
    }

    static func ordered(_ records: [ImageRecord], edited: Set<Int64>) -> [ImageRecord] {
        records.sorted { a, b in
            let aEdited = a.id.map(edited.contains) ?? false
            let bEdited = b.id.map(edited.contains) ?? false
            if aEdited != bEdited { return aEdited }
            if a.rating != b.rating { return a.rating > b.rating }
            return a.relPath < b.relPath
        }
    }
}

// MARK: - Schema

/// The last verify result per image. A table of its own rather than
/// columns on `images`, so nothing that writes rows has to know about it;
/// the row's size and time are recorded with the result, and a result
/// whose file has changed since (reconcile updated the row) no longer
/// counts. Not in the sidecar: a database rebuilt from the sidecars starts
/// with nothing verified.
enum FileIntegritySchema {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("integrity_v1_file_verification") { db in
            try db.create(table: "file_verification") { t in
                t.column("image_id", .integer).notNull().primaryKey()
                    .references("images", onDelete: .cascade)
                t.column("status", .text).notNull()
                t.column("verified_at", .integer).notNull()
                t.column("size", .integer).notNull()
                t.column("mtime", .integer).notNull()
            }
        }
    }
}

extension Catalog {
    /// Records verify results. Only verified and damaged files are stored:
    /// a changed, missing or unreadable file says nothing about its bytes.
    /// A verified result replaces an earlier damaged one.
    public func recordVerification(_ checks: [FileIntegrity.Check], at date: Date = Date()) throws {
        let stamp = ImageRecord.milliseconds(date)
        try dbQueue.write { db in
            for check in checks where check.status == .verified || check.status == .damaged {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO file_verification (image_id, status, verified_at, size, mtime)
                    SELECT id, ?, ?, ?, ? FROM images WHERE id = ?
                    """, arguments: [check.status.rawValue, stamp, check.size, check.mtime, check.imageID])
            }
        }
    }

    /// Images whose file was last found damaged and hasn't changed since,
    /// with their virtual copies, which share the file.
    public func damagedImageIDs() throws -> Set<Int64> {
        try dbQueue.read { db in
            let masters = try Int64.fetchAll(db, sql: """
                SELECT v.image_id FROM file_verification v JOIN images i ON i.id = v.image_id
                WHERE v.status = 'damaged' AND v.size = i.size AND v.mtime = i.mtime
                """)
            guard !masters.isEmpty else { return [] }
            let list = masters.map(String.init).joined(separator: ",")
            let copies = try Int64.fetchAll(db, sql: "SELECT id FROM images WHERE master_id IN (\(list))")
            return Set(masters).union(copies)
        }
    }

    /// When the image's file was last verified or found damaged, while the
    /// file is unchanged since; nil otherwise.
    public func lastVerified(imageID: Int64) throws -> Date? {
        try dbQueue.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT v.verified_at FROM file_verification v JOIN images i ON i.id = v.image_id
                WHERE v.image_id = ? AND v.size = i.size AND v.mtime = i.mtime
                """, arguments: [imageID])
                .map { Date(timeIntervalSince1970: Double($0) / 1000) }
        }
    }
}
