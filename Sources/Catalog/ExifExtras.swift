import Foundation
import ImageIO

/// The EXIF the raw reader doesn't hand over (RawCore's summary has the
/// camera, lens and exposure triangle only): where the photo was taken,
/// whether the flash fired, the exposure compensation, and the metering and
/// white balance modes. Read through ImageIO's metadata pass, which opens
/// the file's header and decodes no pixels, so it costs about what reading
/// the summary does. Nothing here goes on the network: the position is
/// stored as the numbers the file holds and only ever shown or copied.
public struct ExifExtras: Equatable, Sendable {
    /// Bumped when a field is added, so rows read by an older version are
    /// read again at the next reconcile.
    public static let version = 1

    public var gpsLatitude: Double?
    public var gpsLongitude: Double?
    public var gpsAltitude: Double?
    public var flashFired: Bool?
    public var exposureBias: Double?
    public var meteringMode: Int?
    public var whiteBalanceMode: Int?

    public init(gpsLatitude: Double? = nil, gpsLongitude: Double? = nil, gpsAltitude: Double? = nil,
                flashFired: Bool? = nil, exposureBias: Double? = nil, meteringMode: Int? = nil,
                whiteBalanceMode: Int? = nil) {
        self.gpsLatitude = gpsLatitude; self.gpsLongitude = gpsLongitude; self.gpsAltitude = gpsAltitude
        self.flashFired = flashFired; self.exposureBias = exposureBias
        self.meteringMode = meteringMode; self.whiteBalanceMode = whiteBalanceMode
    }

    /// What the file at `url` says; every field nil when ImageIO can't read
    /// it (a format it doesn't know, a damaged header).
    public static func read(from url: URL) -> ExifExtras {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [String: Any]
        else { return ExifExtras() }
        return parse(properties)
    }

    /// The fields from an ImageIO properties dictionary (testable without a file).
    public static func parse(_ properties: [String: Any]) -> ExifExtras {
        var out = ExifExtras()
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        if let flash = number(exif[kCGImagePropertyExifFlash as String]) {
            // Bit 0 of the EXIF Flash tag: the flash fired.
            out.flashFired = (Int(flash) & 1) == 1
        }
        if let bias = number(exif[kCGImagePropertyExifExposureBiasValue as String]), bias.isFinite {
            out.exposureBias = (bias * 100).rounded() / 100
        }
        if let mode = number(exif[kCGImagePropertyExifMeteringMode as String]) { out.meteringMode = Int(mode) }
        if let mode = number(exif[kCGImagePropertyExifWhiteBalance as String]) { out.whiteBalanceMode = Int(mode) }

        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        if let lat = number(gps[kCGImagePropertyGPSLatitude as String]),
           let lon = number(gps[kCGImagePropertyGPSLongitude as String]),
           lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180 {
            let south = (gps[kCGImagePropertyGPSLatitudeRef as String] as? String)?.uppercased() == "S"
            let west = (gps[kCGImagePropertyGPSLongitudeRef as String] as? String)?.uppercased() == "W"
            out.gpsLatitude = south ? -abs(lat) : lat
            out.gpsLongitude = west ? -abs(lon) : lon
            if let altitude = number(gps[kCGImagePropertyGPSAltitude as String]), altitude.isFinite {
                // AltitudeRef 1: below sea level.
                let below = number(gps[kCGImagePropertyGPSAltitudeRef as String]) == 1
                out.gpsAltitude = below ? -abs(altitude) : altitude
            }
        }
        return out
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }
}

extension ImageRecord {
    /// Puts `extras` on the row and marks it read by this version.
    public mutating func apply(_ extras: ExifExtras) {
        gpsLatitude = extras.gpsLatitude
        gpsLongitude = extras.gpsLongitude
        gpsAltitude = extras.gpsAltitude
        flashFired = extras.flashFired
        exposureBias = extras.exposureBias
        meteringMode = extras.meteringMode
        whiteBalanceMode = extras.whiteBalanceMode
        exifExtrasVersion = ExifExtras.version
    }

    /// Whether the file recorded a position.
    public var hasGPS: Bool { gpsLatitude != nil && gpsLongitude != nil }
}

extension Catalog {
    /// How many rows one reconcile fills in, so the first pass after an
    /// update doesn't hold a big catalog's scan for minutes; the rest are
    /// read by the passes after it.
    static let exifExtrasBackfillLimit = 400

    /// Reads the extras for rows that have never had them (made before
    /// they existed, or by an older `ExifExtras.version`). A position the
    /// user geotagged (`gps_tagged`) is kept over the file's. A virtual copy
    /// reads its master's file. Files left in iCloud are skipped, since
    /// reading them would download them. Returns how many rows changed.
    @discardableResult
    func backfillExifExtras(limit: Int = Catalog.exifExtrasBackfillLimit) throws -> Int {
        let stale = try dbQueue.read { db in
            try ImageRecord.fetchAll(db, sql: """
                SELECT * FROM images WHERE exif_extras_version IS NULL OR exif_extras_version < ? LIMIT ?
                """, arguments: [ExifExtras.version, limit])
        }
        guard !stale.isEmpty else { return 0 }
        var read: [(Int64, ExifExtras)] = []
        let keys: Set<URLResourceKey> = [.ubiquitousItemDownloadingStatusKey]
        for record in stale {
            guard let id = record.id else { continue }
            let url = fileURL(forRelPath: record.fileRelPath)
            if let values = try? url.resourceValues(forKeys: keys), Self.isDataless(url, values) { continue }
            // A missing file still gets marked, with nothing, so it isn't
            // asked again every pass.
            read.append((id, ExifExtras.read(from: url)))
        }
        try dbQueue.write { db in
            for (id, extras) in read {
                try db.execute(sql: """
                    UPDATE images SET
                      gps_latitude = CASE WHEN gps_tagged = 1 THEN gps_latitude ELSE ? END,
                      gps_longitude = CASE WHEN gps_tagged = 1 THEN gps_longitude ELSE ? END,
                      gps_altitude = CASE WHEN gps_tagged = 1 THEN gps_altitude ELSE ? END, flash_fired = ?,
                      exposure_bias = ?, metering_mode = ?, white_balance_mode = ?, exif_extras_version = ?
                    WHERE id = ?
                    """, arguments: [extras.gpsLatitude, extras.gpsLongitude, extras.gpsAltitude, extras.flashFired,
                                     extras.exposureBias, extras.meteringMode, extras.whiteBalanceMode,
                                     ExifExtras.version, id])
            }
        }
        return read.count
    }
}
