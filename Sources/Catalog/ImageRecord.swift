import Foundation
import GRDB

/// One row of the `images` table (DESIGN.md §5.4).
///
/// Paths are relative to the catalog root, never absolute, so a catalog
/// folder can be moved or copied and everything still resolves.
public struct ImageRecord: Codable, FetchableRecord, MutablePersistableRecord,
                           Identifiable, Sendable, Equatable {
    public static let databaseTableName = "images"

    public var id: Int64?
    public var relPath: String
    public var preservedName: String?
    public var size: Int64
    /// Modification time in milliseconds since 1970. Milliseconds rather
    /// than seconds so two saves within one second still register.
    public var mtime: Int64
    /// XXH64 of the file contents, 8 bytes big-endian.
    public var xxhash: Data
    public var captureTime: Int64?
    public var camera: String?
    public var lens: String?
    public var lensId: String?
    public var iso: Int?
    public var shutter: Double?
    public var aperture: Double?
    public var focal: Double?
    public var width: Int?
    public var height: Int?
    public var orientation: Int?
    public var rating: Int
    public var label: String?
    public var flag: Int
    public var sidecarMtime: Int64?
    public var thumbKey: Data?
    /// Manual rotation in quarter turns clockwise, on top of `orientation`.
    public var userRotation: Int = 0
    /// The file's Finder tags in their stored form (see `FinderTag.encode`),
    /// nil for none. Read from the file during reconcile, never written to it.
    public var finderTags: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, size, mtime, xxhash, camera, lens, iso, shutter, aperture, focal
        case width, height, orientation, rating, label, flag
        case userRotation = "user_rotation"
        case finderTags = "finder_tags"
        case relPath = "rel_path"
        case preservedName = "preserved_name"
        case captureTime = "capture_time"
        case lensId = "lens_id"
        case sidecarMtime = "sidecar_mtime"
        case thumbKey = "thumb_key"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// The hash as written in sidecars: "xxh64:" + 16 hex digits.
    public var hashString: String {
        FileHash.prefix + ":" + xxhash.map { String(format: "%02x", $0) }.joined()
    }

    public var fileName: String { (relPath as NSString).lastPathComponent }

    static func hashData(_ hash: UInt64) -> Data {
        var big = hash.bigEndian
        return Data(bytes: &big, count: 8)
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

/// Pick / reject flag values stored in `images.flag`.
public enum ImageFlag: Int, Sendable, CaseIterable {
    case rejected = -1
    case none = 0
    case picked = 1
}

/// How a subfolder relates to its parent catalog (DESIGN.md §5.2).
public enum SubfolderMode: String, Sendable, CaseIterable {
    case included, independent, ask
}
