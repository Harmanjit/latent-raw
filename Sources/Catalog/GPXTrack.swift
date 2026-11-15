import Foundation

/// One timed point of a GPX file: a track point, route point or waypoint.
public struct GPXPoint: Equatable, Sendable {
    public var time: Date
    public var latitude: Double
    public var longitude: Double
    /// Metres (`<ele>`), nil when the point has none.
    public var elevation: Double?

    public init(time: Date, latitude: Double, longitude: Double, elevation: Double? = nil) {
        self.time = time
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = elevation
    }
}

/// A GPX file's timed points in time order, for Geotag from GPX Track.
///
/// Read from a local file the user chose; nothing is ever fetched. Points
/// without a time (most waypoints, planned routes) can't be matched to a
/// photo and are counted, not kept.
public struct GPXTrack: Equatable, Sendable {
    public var points: [GPXPoint]
    /// Points the file had that carried no usable time.
    public var untimedPoints: Int

    public init(points: [GPXPoint], untimedPoints: Int = 0) {
        self.points = points.sorted { $0.time < $1.time }
        self.untimedPoints = untimedPoints
    }

    public enum ReadError: Error, CustomStringConvertible, Equatable {
        case tooLarge(Int)
        case notGPX(String)
        case noTimedPoints

        public var description: String {
            switch self {
            case .tooLarge(let n): "The file is \(n / 1_000_000) MB; a GPX track over \(GPXTrack.maximumBytes / 1_000_000) MB isn’t read."
            case .notGPX(let why): "The file isn’t a GPX track: \(why)"
            case .noTimedPoints: "The track has no points with a time, so photos can’t be matched to it."
            }
        }
    }

    /// A day's walk logged every second is a few MB; past this it isn't a
    /// track anyone meant to open.
    public static let maximumBytes = 200 * 1024 * 1024

    /// Reads the GPX file at `url`.
    public static func read(from url: URL) throws -> GPXTrack {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = (attributes[.size] as? NSNumber)?.intValue, size > maximumBytes { throw ReadError.tooLarge(size) }
        return try parse(Data(contentsOf: url))
    }

    /// Parses GPX 1.0 or 1.1: every `trkpt`, `rtept` and `wpt` with a
    /// `lat`, `lon` and `time`. Element names are matched without their
    /// namespace prefix. External entities are never resolved.
    public static func parse(_ data: Data) throws -> GPXTrack {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw ReadError.notGPX(parser.parserError.map { $0.localizedDescription } ?? "unreadable XML")
        }
        guard delegate.sawGPX else { throw ReadError.notGPX("no <gpx> element") }
        guard !delegate.points.isEmpty else { throw ReadError.noTimedPoints }
        return GPXTrack(points: delegate.points, untimedPoints: delegate.untimed)
    }

    /// GPX times are ISO 8601, in UTC by the spec. Fractional seconds and
    /// an explicit offset are accepted; a time with no zone is UTC.
    static func parseTime(_ text: String) -> Date? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        // "…T10:00:00" with no Z or ±hh:mm after the time.
        if let t = s.firstIndex(of: "T") {
            let afterT = s[s.index(after: t)...]
            if !afterT.contains("Z") && !afterT.contains("z") && !afterT.contains("+") && !afterT.contains("-") {
                s += "Z"
            }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: s) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: s)
    }

    /// XMLParser's delegate: collects points as their elements close.
    private final class Delegate: NSObject, XMLParserDelegate {
        var points: [GPXPoint] = []
        var untimed = 0
        var sawGPX = false

        private var current: (lat: Double, lon: Double)?
        private var time: Date?
        private var elevation: Double?
        private var text = ""
        private var collecting = false

        private static let pointNames: Set<String> = ["trkpt", "rtept", "wpt"]

        private static func local(_ name: String) -> String {
            name.split(separator: ":").last.map(String.init) ?? name
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            let name = Self.local(elementName)
            if name == "gpx" { sawGPX = true }
            if Self.pointNames.contains(name) {
                if let lat = attributes["lat"].flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
                   let lon = attributes["lon"].flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
                   GeoPosition(latitude: lat, longitude: lon).isValid {
                    current = (lat, lon)
                } else {
                    current = nil
                }
                time = nil
                elevation = nil
            } else if current != nil, name == "time" || name == "ele" {
                text = ""
                collecting = true
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if collecting { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            let name = Self.local(elementName)
            if collecting, name == "time" || name == "ele" {
                collecting = false
                if name == "time" { time = GPXTrack.parseTime(text) }
                if name == "ele", let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                   value.isFinite { elevation = value }
            } else if Self.pointNames.contains(name) {
                if let point = current, let time {
                    points.append(GPXPoint(time: time, latitude: point.lat, longitude: point.lon, elevation: elevation))
                } else {
                    untimed += 1
                }
                current = nil
            }
        }
    }

    // MARK: Matching

    /// The first and last times of the track.
    public var timeRange: ClosedRange<Date>? {
        guard let first = points.first, let last = points.last else { return nil }
        return first.time...last.time
    }

    /// Where the track was at `date`.
    ///
    /// Between two points no more than `maxGap` seconds apart the position
    /// is interpolated linearly in time (longitude the short way round the
    /// antimeridian; elevation only when both points have one). Across a
    /// longer gap (the logger was off) the nearer point is used if it is
    /// within `maxGap`. Before the first point or after the last, that
    /// point is used within `maxGap`. Nil otherwise.
    public func position(at date: Date, maxGap: TimeInterval) -> GeoPosition? {
        guard let first = points.first, let last = points.last else { return nil }
        let gap = max(0, maxGap)
        if date <= first.time {
            return first.time.timeIntervalSince(date) <= gap ? Self.position(of: first) : nil
        }
        if date >= last.time {
            return date.timeIntervalSince(last.time) <= gap ? Self.position(of: last) : nil
        }
        // The first point at or after `date`; 1...count-1 here.
        var low = 0, high = points.count - 1
        while low < high {
            let mid = (low + high) / 2
            if points[mid].time < date { low = mid + 1 } else { high = mid }
        }
        let after = points[low], before = points[low - 1]
        if after.time == date { return Self.position(of: after) }
        let span = after.time.timeIntervalSince(before.time)
        if span <= gap, span > 0 {
            let f = date.timeIntervalSince(before.time) / span
            return Self.interpolate(before, after, f)
        }
        let toBefore = date.timeIntervalSince(before.time), toAfter = after.time.timeIntervalSince(date)
        if min(toBefore, toAfter) > gap { return nil }
        return Self.position(of: toBefore <= toAfter ? before : after)
    }

    static func position(of point: GPXPoint) -> GeoPosition {
        GeoPosition(latitude: point.latitude, longitude: point.longitude, altitude: point.elevation)
    }

    static func interpolate(_ a: GPXPoint, _ b: GPXPoint, _ f: Double) -> GeoPosition {
        var dLon = b.longitude - a.longitude
        if dLon > 180 { dLon -= 360 } else if dLon < -180 { dLon += 360 }
        var lon = a.longitude + f * dLon
        if lon > 180 { lon -= 360 } else if lon < -180 { lon += 360 }
        let lat = a.latitude + f * (b.latitude - a.latitude)
        var altitude: Double?
        if let ea = a.elevation, let eb = b.elevation { altitude = ea + f * (eb - ea) }
        return GeoPosition(latitude: lat, longitude: lon, altitude: altitude)
    }
}

/// What Geotag from GPX Track would do to each photo, worked out before
/// anything is written so the sheet can show it.
public struct GeotagPlan: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The track places the photo here; it will be written.
        case matched(GeoPosition)
        /// The track places it, but it has a position and Replace is off.
        case keepsExisting(GeoPosition)
        /// No capture time to match by.
        case noCaptureTime
        /// Outside the track, or in a gap longer than the tolerance.
        case unmatched
    }

    /// Image id → outcome, for every photo planned with an id.
    public var outcomes: [Int64: Outcome]

    /// Matches every record by its (corrected) capture time plus
    /// `clockOffset` seconds (how far to move the camera's times to reach
    /// the logger's UTC). A capture time is the moment the camera's clock
    /// read in this Mac's time zone; a camera set to another zone, or
    /// running fast or slow, is put right with the offset.
    public static func make(records: [ImageRecord], track: GPXTrack, clockOffset: TimeInterval,
                            maxGap: TimeInterval, replaceExisting: Bool) -> GeotagPlan {
        var outcomes: [Int64: Outcome] = [:]
        for record in records {
            guard let id = record.id else { continue }
            guard let time = record.captureTime else { outcomes[id] = .noCaptureTime; continue }
            let moment = Date(timeIntervalSince1970: TimeInterval(time) + clockOffset)
            guard let position = track.position(at: moment, maxGap: maxGap) else { outcomes[id] = .unmatched; continue }
            outcomes[id] = record.hasGPS && !replaceExisting ? .keepsExisting(position) : .matched(position)
        }
        return GeotagPlan(outcomes: outcomes)
    }

    public init(outcomes: [Int64: Outcome]) {
        self.outcomes = outcomes
    }

    /// The positions to write, by image id.
    public var positionsToWrite: [Int64: GeoPosition] {
        outcomes.compactMapValues { if case .matched(let p) = $0 { p } else { nil } }
    }

    public var matchedCount: Int { positionsToWrite.count }
    public var keptCount: Int { outcomes.values.filter { if case .keepsExisting = $0 { true } else { false } }.count }
    public var unmatchedCount: Int { outcomes.values.filter { $0 == .unmatched }.count }
    public var noCaptureTimeCount: Int { outcomes.values.filter { $0 == .noCaptureTime }.count }
}
