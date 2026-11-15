import Foundation
import GRDB

// Edit Capture Time and Geotag from GPX Track (Wave 4).
//
// Neither touches the raw file. A corrected capture time is kept as an
// offset from the file's own time and a geotag as a position marked as the
// user's, both in the sidecar (the truth, DESIGN.md §5.5) and mirrored on
// the row, where sorting, the date filters, the Has GPS rule and the
// metadata panel read them. When the file changes on disk its row is read
// afresh and the correction and geotag are carried over (`carryGeoTime`);
// when the sidecar changes they come back from it (`applyGeoTime`).

/// A position on the Earth: degrees, south and west negative, and metres
/// above sea level (negative below), nil when unknown.
public struct GeoPosition: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?

    public init(latitude: Double, longitude: Double, altitude: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }

    /// Whether the numbers are a place: finite and in range.
    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180
            && (altitude?.isFinite ?? true)
    }

    // MARK: XMP

    /// XMP's GPSCoordinate form, "DDD,MM.mmmmmmK" (Adobe XMP spec part 2):
    /// whole degrees, decimal minutes and the hemisphere letter.
    static func xmpCoordinate(_ value: Double, positive: String, negative: String) -> String {
        let magnitude = abs(value)
        var degrees = Int(magnitude)
        var minutes = (magnitude - Double(degrees)) * 60
        // 59.9999999 minutes would print as 60.000000.
        if (minutes * 1_000_000).rounded() >= 60_000_000 { degrees += 1; minutes = 0 }
        return String(format: "%d,%.6f%@", degrees, minutes, value < 0 ? negative : positive)
    }

    /// Reads one XMP GPSCoordinate: "DDD,MM.mmK", "DDD,MM,SSK", or a plain
    /// signed decimal some writers use. Nil when it isn't one.
    static func parseXMPCoordinate(_ text: String?) -> Double? {
        guard var s = text?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        var sign = 1.0
        if let last = s.last, "NSEW".contains(last.uppercased()) {
            if "SW".contains(last.uppercased()) { sign = -1 }
            s.removeLast()
        }
        let parts = s.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        let numbers = parts.compactMap { $0 }
        var value: Double
        switch numbers.count {
        case 1: value = numbers[0]
        case 2: value = abs(numbers[0]) + numbers[1] / 60
        case 3: value = abs(numbers[0]) + numbers[1] / 60 + numbers[2] / 3600
        default: return nil
        }
        if numbers.count > 1, numbers[0] < 0 { sign = -1 }
        if numbers.count == 1, sign < 0 { value = abs(value) }
        return value.isFinite ? sign * value : nil
    }

    /// A rational ("12345/100") or decimal number.
    static func parseRational(_ text: String?) -> Double? {
        guard let s = text?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        let parts = s.split(separator: "/")
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d != 0 { return n / d }
        return Double(s)
    }

    /// The position a sidecar's exif:GPS* properties give, nil without
    /// both a latitude and a longitude.
    init?(xmpLatitude latitude: String?, longitude: String?, altitude: String?, altitudeRef: String?) {
        guard let lat = Self.parseXMPCoordinate(latitude), let lon = Self.parseXMPCoordinate(longitude) else { return nil }
        var alt = Self.parseRational(altitude)
        if let a = alt, altitudeRef?.trimmingCharacters(in: .whitespaces) == "1" { alt = -abs(a) }
        self.init(latitude: lat, longitude: lon, altitude: alt)
        guard isValid else { return nil }
    }
}

extension XMPSidecar {
    static let exifNamespace = "http://ns.adobe.com/exif/1.0/"

    /// The exif namespace, declared only when a sidecar has a corrected
    /// time or a geotag to write under it.
    static func geoTimeNamespace(_ f: Fields) -> String {
        f.captureTimeOffset != nil || f.geotag != nil ? "\n    xmlns:exif=\"\(exifNamespace)\"" : ""
    }

    /// The capture-time correction and the geotag, one element each after
    /// the descriptive ones; nothing when there are neither, so every other
    /// sidecar stays exactly as it was.
    static func geoTimeElements(_ f: Fields) -> String {
        var lines: [String] = []
        if let offset = f.captureTimeOffset {
            lines.append("   <latent:CaptureTimeOffset>\(offset)</latent:CaptureTimeOffset>")
            if let time = f.correctedCaptureTime {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                formatter.timeZone = .current
                let text = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(time)))
                lines.append("   <exif:DateTimeOriginal>\(text)</exif:DateTimeOriginal>")
            }
        }
        if let tag = f.geotag {
            lines.append("   <exif:GPSLatitude>\(GeoPosition.xmpCoordinate(tag.latitude, positive: "N", negative: "S"))</exif:GPSLatitude>")
            lines.append("   <exif:GPSLongitude>\(GeoPosition.xmpCoordinate(tag.longitude, positive: "E", negative: "W"))</exif:GPSLongitude>")
            if let altitude = tag.altitude {
                let centimetres = Int64((abs(altitude) * 100).rounded())
                lines.append("   <exif:GPSAltitude>\(centimetres)/100</exif:GPSAltitude>")
                lines.append("   <exif:GPSAltitudeRef>\(altitude < 0 ? 1 : 0)</exif:GPSAltitudeRef>")
            }
        }
        return lines.isEmpty ? "" : "\n" + lines.joined(separator: "\n")
    }
}

extension XMPSidecar.Fields {
    /// Takes the row's correction and geotag for writing.
    mutating func setGeoTime(from row: ImageRecord) {
        captureTimeOffset = row.captureTimeOffset
        correctedCaptureTime = row.captureTimeOffset == nil ? nil : row.captureTime
        geotag = row.geoTag
    }
}

extension ImageRecord {
    /// The capture time the file itself records, before any correction.
    public var fileCaptureTime: Int64? {
        captureTime.map { $0 - (captureTimeOffset ?? 0) }
    }

    /// The geotag, when the row's position is the user's.
    var geoTag: GeoPosition? {
        guard gpsTagged == true, let lat = gpsLatitude, let lon = gpsLongitude else { return nil }
        return GeoPosition(latitude: lat, longitude: lon, altitude: gpsAltitude)
    }

    /// The row's position, the file's or a geotag, nil without one.
    public var gpsPosition: GeoPosition? {
        guard let lat = gpsLatitude, let lon = gpsLongitude else { return nil }
        return GeoPosition(latitude: lat, longitude: lon, altitude: gpsAltitude)
    }

    /// What a sidecar read by reconcile says: the correction applied to
    /// the file's time and the geotag put on, or both taken off when the
    /// sidecar (or `fields`, nil for none) no longer has them. A geotag
    /// taken off leaves the row to read the file's own GPS again.
    mutating func applyGeoTime(from fields: XMPSidecar.Fields?) {
        let offset = fields?.captureTimeOffset
        if let original = fileCaptureTime {
            captureTime = original + (offset ?? 0)
            captureTimeOffset = offset
        } else {
            captureTimeOffset = nil
        }
        if let tag = fields?.geotag {
            gpsLatitude = tag.latitude
            gpsLongitude = tag.longitude
            gpsAltitude = tag.altitude
            gpsTagged = true
        } else if gpsTagged == true {
            gpsLatitude = nil
            gpsLongitude = nil
            gpsAltitude = nil
            gpsTagged = nil
            exifExtrasVersion = nil
        }
    }

    /// A row read afresh from a changed file keeps the user's correction
    /// and geotag from the row it replaces.
    mutating func carryGeoTime(from previous: ImageRecord) {
        if let offset = previous.captureTimeOffset, let time = captureTime {
            captureTime = time + offset
            captureTimeOffset = offset
        }
        if previous.gpsTagged == true {
            gpsLatitude = previous.gpsLatitude
            gpsLongitude = previous.gpsLongitude
            gpsAltitude = previous.gpsAltitude
            gpsTagged = true
        }
    }
}

/// The parts of a row Edit Capture Time and Geotag change, as one value
/// for undo: what an image had before is put back whole.
public struct GeoTimeState: Equatable, Sendable {
    public var captureTime: Int64?
    public var captureTimeOffset: Int64?
    public var gpsLatitude: Double?
    public var gpsLongitude: Double?
    public var gpsAltitude: Double?
    public var gpsTagged: Bool?

    public init(_ record: ImageRecord) {
        captureTime = record.captureTime
        captureTimeOffset = record.captureTimeOffset
        gpsLatitude = record.gpsLatitude
        gpsLongitude = record.gpsLongitude
        gpsAltitude = record.gpsAltitude
        gpsTagged = record.gpsTagged
    }

    func apply(to record: inout ImageRecord) {
        record.captureTime = captureTime
        record.captureTimeOffset = captureTimeOffset
        record.gpsLatitude = gpsLatitude
        record.gpsLongitude = gpsLongitude
        record.gpsAltitude = gpsAltitude
        record.gpsTagged = gpsTagged
    }

    /// Moves the capture time by `delta` seconds, adding to any earlier
    /// correction; a photo without a capture time is left alone. A total
    /// correction of zero is none at all.
    public mutating func shiftCaptureTime(by delta: Int64) {
        guard let time = captureTime, delta != 0 else { return }
        captureTime = time + delta
        let total = (captureTimeOffset ?? 0) + delta
        captureTimeOffset = total == 0 ? nil : total
    }

    /// Puts `position` on as the user's geotag.
    public mutating func setGeotag(_ position: GeoPosition) {
        gpsLatitude = position.latitude
        gpsLongitude = position.longitude
        gpsAltitude = position.altitude
        gpsTagged = true
    }
}

/// What Edit Capture Time… does to the selection: one shift for every
/// photo, so their order and spacing are kept.
public struct CaptureTimeEdit: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// Every photo moved by this many seconds (negative: earlier).
        case shift(seconds: Int64)
        /// The earliest photo set to this time (seconds since 1970) and the
        /// rest moved by as much.
        case setFirst(to: Int64)
    }

    public var mode: Mode
    /// A time-zone change in seconds, added to a `shift` (see
    /// `timeZoneShift(from:to:at:)`). Ignored by `setFirst`, which names
    /// the exact time wanted.
    public var timeZoneShift: Int64

    public init(mode: Mode, timeZoneShift: Int64 = 0) {
        self.mode = mode
        self.timeZoneShift = timeZoneShift
    }

    /// The seconds every photo moves by, given their current capture times;
    /// nil when none has one.
    public func delta(forCaptureTimes times: [Int64]) -> Int64? {
        guard let first = times.min() else { return nil }
        switch mode {
        case .shift(let seconds): return seconds + timeZoneShift
        case .setFirst(let target): return target - first
        }
    }

    /// Days, hours, minutes and seconds as seconds.
    public static func seconds(days: Int, hours: Int, minutes: Int, seconds: Int) -> Int64 {
        Int64(days) * 86_400 + Int64(hours) * 3_600 + Int64(minutes) * 60 + Int64(seconds)
    }

    /// The shift that moves clock times read in `from` to the same moment's
    /// clock times in `to`: a photo shot at 10:00 by a camera left on
    /// London time (UTC+1 in summer), moved to New York (UTC−4), shows
    /// 05:00. Each zone's offset is taken at `date`, for daylight saving.
    public static func timeZoneShift(from: TimeZone, to: TimeZone, at date: Date) -> Int64 {
        Int64(to.secondsFromGMT(for: date) - from.secondsFromGMT(for: date))
    }
}

extension Catalog {
    /// Changes one image's capture time and position with `mutate`, row
    /// then sidecar like every metadata change, and returns what it had
    /// and has now (nil if there is no such image). An unchanged state
    /// writes nothing.
    @discardableResult
    public func exchangeGeoTime(forImageID id: Int64,
                                _ mutate: @Sendable (inout GeoTimeState) -> Void)
        throws -> (before: GeoTimeState, after: GeoTimeState)? {
        let outcome: (before: GeoTimeState, after: GeoTimeState, changed: Bool)? = try dbQueue.write { db in
            guard var row = try ImageRecord.fetchOne(db, key: id) else { return nil }
            let before = GeoTimeState(row)
            var after = before
            mutate(&after)
            guard after != before else { return (before, after, false) }
            after.apply(to: &row)
            try row.update(db)
            return (before, after, true)
        }
        guard let outcome else { return nil }
        if outcome.changed { try writeSidecar(forImageID: id) }
        return (outcome.before, outcome.after)
    }
}
