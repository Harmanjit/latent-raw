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
    /// The latent:Merge recipe JSON when this image is a Photo Merge result,
    /// nil otherwise. Mirrors the sidecar, which holds the truth; kept on
    /// the row so every sidecar written from the row carries it.
    public var mergeJSON: String? = nil
    /// What the photographer says about the photo (DescriptiveField): kept
    /// on the row as typed, mirrored to dc:title, dc:description,
    /// dc:creator and dc:rights in the sidecar, nil for none.
    public var title: String? = nil
    public var caption: String? = nil
    public var creator: String? = nil
    public var copyright: String? = nil
    /// The IPTC fields beyond those four (DescriptiveField's "More"):
    /// photoshop:Headline, Iptc4xmpCore:Location, photoshop:City, State and
    /// Country, Iptc4xmpCore:CountryCode, the creator's job title
    /// (photoshop:AuthorsPosition), email and web address
    /// (Iptc4xmpCore:CreatorContactInfo) and photoshop:Instructions.
    public var headline: String? = nil
    public var sublocation: String? = nil
    public var city: String? = nil
    public var state: String? = nil
    public var country: String? = nil
    public var countryCode: String? = nil
    public var creatorJobTitle: String? = nil
    public var creatorEmail: String? = nil
    public var creatorURL: String? = nil
    public var instructions: String? = nil
    /// EXIF the raw reader doesn't give, read through ImageIO (ExifExtras):
    /// position in degrees (south and west negative) and metres, whether
    /// the flash fired, exposure compensation in stops, and the EXIF
    /// metering mode and white balance mode codes. Nil for unknown.
    public var gpsLatitude: Double? = nil
    public var gpsLongitude: Double? = nil
    public var gpsAltitude: Double? = nil
    public var flashFired: Bool? = nil
    public var exposureBias: Double? = nil
    public var meteringMode: Int? = nil
    public var whiteBalanceMode: Int? = nil
    /// Which version of `ExifExtras` read the fields above; nil for a row
    /// made before they existed, which the next reconcile fills in.
    public var exifExtrasVersion: Int? = nil
    /// Edit Capture Time's correction (GeoTime.swift): seconds already
    /// added to the file's own time in `captureTime`, nil for none. The
    /// file is never rewritten; the sidecar holds the truth
    /// (latent:CaptureTimeOffset) and this mirrors it, so a file changed
    /// on disk is read afresh and corrected again.
    public var captureTimeOffset: Int64? = nil
    /// True when the GPS fields above came from Geotag from GPX Track
    /// rather than the file (mirrored to the sidecar's exif:GPS* names);
    /// nil when they are the file's own. Reading the file's EXIF again
    /// leaves a geotag alone.
    public var gpsTagged: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id, size, mtime, xxhash, camera, lens, iso, shutter, aperture, focal
        case width, height, orientation, rating, label, flag
        case userRotation = "user_rotation"
        case finderTags = "finder_tags"
        case mergeJSON = "merge_json"
        case title, caption, creator, copyright
        case headline, sublocation, city, state, country
        case countryCode = "country_code"
        case creatorJobTitle = "creator_job_title"
        case creatorEmail = "creator_email"
        case creatorURL = "creator_url"
        case instructions
        case gpsLatitude = "gps_latitude"
        case gpsLongitude = "gps_longitude"
        case gpsAltitude = "gps_altitude"
        case flashFired = "flash_fired"
        case exposureBias = "exposure_bias"
        case meteringMode = "metering_mode"
        case whiteBalanceMode = "white_balance_mode"
        case exifExtrasVersion = "exif_extras_version"
        case captureTimeOffset = "capture_time_offset"
        case gpsTagged = "gps_tagged"
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

    /// The name shown for the image: the file's, or for a virtual copy the
    /// file's with its copy number, "DSC_0107 (Copy 2).NEF" (VirtualCopy).
    public var fileName: String {
        if let copy = VirtualCopy.parse(relPath) {
            return VirtualCopy.displayName(fileName: (copy.masterRelPath as NSString).lastPathComponent,
                                           number: copy.key.number)
        }
        return (relPath as NSString).lastPathComponent
    }

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
