import Foundation
import simd

/// One spot of a dust map: where a reference photo showed dust, so the
/// same spot can be looked for in other photos from that camera.
public struct DustMapSpot: Codable, Equatable, Sendable {
    /// Active-area normalised.
    public var centre: SIMD2<Float>
    /// Fraction of the short side.
    public var radius: Float
    /// Stops.
    public var contrast: Float

    public init(centre: SIMD2<Float>, radius: Float, contrast: Float) {
        self.centre = centre
        self.radius = radius
        self.contrast = contrast
    }

    /// The largest radius a spot may have, as a fraction of the short
    /// side: five times the widest dust band (40 px on a 4000 px side is
    /// 0.01), so nothing the detector saves is lost. It bounds the window
    /// `DustDetector.verify` cuts around a spot, which grows with the
    /// radius: an absurd one would take gigabytes or overflow an Int.
    public static let maximumRadius: Float = 0.05

    /// The spot as `verify` can trust it, whatever wrote the file: a
    /// centre on the sensor and a radius of at most `maximumRadius`. Nil
    /// when a number isn't finite. A spot the app saved comes back
    /// unchanged.
    public var sanitized: DustMapSpot? {
        guard centre.x.isFinite, centre.y.isFinite, radius.isFinite, contrast.isFinite else { return nil }
        var s = self
        s.centre = simd_clamp(centre, SIMD2(repeating: 0), SIMD2(repeating: 1))
        s.radius = min(max(radius, 0), Self.maximumRadius)
        return s
    }
}

/// A camera's dust, found once on a reference photo (docs/Retouch.md §6)
/// and applied to others with `DustDetector.verify`. Keyed by the camera
/// string and the sensor size, since a map from another body or a
/// cropped mode would put every spot in the wrong place.
public struct DustMap: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// `ImageRecord.camera` ("Make Model").
    public var camera: String
    /// rawWidth, rawHeight.
    public var sensorSize: SIMD2<Int>
    public var created: Date
    public var referenceName: String
    public var referenceCaptureDate: Date?
    public var aperture: Double?
    public var options: DustDetector.Options
    public var spots: [DustMapSpot]

    public init(id: UUID = UUID(), camera: String, sensorSize: SIMD2<Int>, created: Date = Date(),
                referenceName: String, referenceCaptureDate: Date? = nil, aperture: Double? = nil,
                options: DustDetector.Options = DustDetector.Options(), spots: [DustMapSpot]) {
        self.id = id
        self.camera = camera
        self.sensorSize = sensorSize
        self.created = created
        self.referenceName = referenceName
        self.referenceCaptureDate = referenceCaptureDate
        self.aperture = aperture
        self.options = options
        self.spots = spots
    }

    /// "Nikon D750 · 12 Sep 2026 · 41 spots": the date and reference tell
    /// two maps of the same camera apart (the camera string can't tell two
    /// bodies apart).
    public var title: String {
        let date = Self.dateFormatter.string(from: referenceCaptureDate ?? created)
        let count = spots.count == 1 ? "1 spot" : "\(spots.count) spots"
        return "\(camera) · \(date) · \(count)"
    }

    /// The map as the detector can trust it: a sensor with a size, at
    /// most `HealPatch.maximumDustCount` spots (the detector never saves
    /// more, and `verify` runs once per spot per photo), each spot
    /// `sanitized`. Nil when the sensor size is not positive. A map the
    /// app saved comes back unchanged.
    public var sanitized: DustMap? {
        guard sensorSize.x > 0, sensorSize.y > 0 else { return nil }
        var m = self
        m.spots = Array(spots.compactMap(\.sanitized).prefix(HealPatch.maximumDustCount))
        return m
    }

    /// Day, short month, year, the same in every locale so tests and
    /// titles agree.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "d MMM yyyy"
        return f
    }()
}

/// The dust maps on disk: one JSON file in Application Support, shared
/// by every catalog like presets, written atomically and versioned so
/// a later build can change the shape. A file that can't be read (or
/// isn't there yet) reads as no maps, and one that decodes is still
/// `sanitized` map by map: a corrupt file must never stop the app, and
/// the maps are cheap to make again.
public struct DustMapStore: Sendable {
    /// ~/Library/Application Support/latent/dust-maps.json
    public static let defaultURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("latent", isDirectory: true).appendingPathComponent("dust-maps.json")
    }()

    public let url: URL

    public init(url: URL = DustMapStore.defaultURL) {
        self.url = url
    }

    /// The file's shape: `{"version":1,"maps":[…]}`.
    struct File: Codable {
        var version: Int
        var maps: [DustMap]
    }
    static let version = 1

    /// Every map, or none when the file is missing or unreadable. Each
    /// map comes back `sanitized`, since what the file says goes straight
    /// to the detector.
    public func load() -> [DustMap] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(File.self, from: data) else { return [] }
        return file.maps.compactMap(\.sanitized)
    }

    /// Writes every map, atomically: the file is complete or unchanged.
    public func save(_ maps: [DustMap]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(File(version: Self.version, maps: maps))
        try SafeFileWriter.write(data, to: url)
    }

    /// The maps for one camera, newest first.
    public func maps(forCamera camera: String) -> [DustMap] {
        load().filter { $0.camera == camera }.sorted { $0.created > $1.created }
    }

    /// Adds a map (replacing one with the same id).
    public func add(_ map: DustMap) throws {
        var maps = load().filter { $0.id != map.id }
        maps.append(map)
        try save(maps)
    }

    public func delete(id: UUID) throws {
        try save(load().filter { $0.id != id })
    }
}
