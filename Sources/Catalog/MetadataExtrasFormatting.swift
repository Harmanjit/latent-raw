import Foundation

/// The EXIF extras (ExifExtras) as the Metadata section shows them.
extension MetadataFormat {
    /// "+0.7 EV", "−1.3 EV", "0 EV".
    public static func exposureBias(_ stops: Double) -> String {
        let tenths = (abs(stops) * 10).rounded() / 10
        let number = tenths == tenths.rounded() ? String(Int(tenths)) : String(format: "%.1f", tenths)
        if number == "0" { return "0 EV" }
        return (stops < 0 ? "−" : "+") + number + " EV"
    }

    public static func flash(_ fired: Bool) -> String { fired ? "Fired" : "Did not fire" }

    /// The EXIF MeteringMode code's name.
    public static func meteringMode(_ code: Int) -> String {
        switch code {
        case 1: "Average"
        case 2: "Centre-weighted"
        case 3: "Spot"
        case 4: "Multi-spot"
        case 5: "Pattern"
        case 6: "Partial"
        case 255: "Other"
        default: "Unknown"
        }
    }

    /// The EXIF WhiteBalance code's name.
    public static func whiteBalanceMode(_ code: Int) -> String {
        switch code {
        case 0: "Auto"
        case 1: "Manual"
        default: "Unknown"
        }
    }

    /// "51.50135° N, 0.14189° W".
    public static func coordinates(latitude: Double, longitude: Double) -> String {
        let lat = String(format: "%.5f° %@", abs(latitude), latitude < 0 ? "S" : "N")
        let lon = String(format: "%.5f° %@", abs(longitude), longitude < 0 ? "W" : "E")
        return lat + ", " + lon
    }

    /// What Copy Coordinates puts on the clipboard: decimal degrees, the
    /// form maps and spreadsheets read, "51.501350, -0.141890".
    public static func coordinatesForCopying(latitude: Double, longitude: Double) -> String {
        String(format: "%.6f, %.6f", latitude, longitude)
    }

    /// "35 m", "−12 m"; "—" for a value that isn't a real altitude.
    public static func altitude(_ metres: Double) -> String {
        guard GeoPosition.isValidAltitude(metres), let rounded = Int(exactly: metres.rounded()) else { return "—" }
        return rounded < 0 ? "−\(-rounded) m" : "\(rounded) m"
    }
}

/// The Metadata section's rows by label, for Settings › Library's list of
/// which to show.
public enum MetadataRow {
    /// What a row shows when the selected photos differ.
    public static let various = "Various"

    public static let standardLabels = ["Camera", "Lens", "Shutter", "Aperture", "ISO", "Focal length",
                                        "Captured", "Size", "File"]
    public static let extraLabels = ["Exposure bias", "Flash", "Metering", "White balance", "GPS", "Altitude"]
    public static var allLabels: [String] { standardLabels + extraLabels }

    /// The UserDefaults key of the hidden labels, joined by newlines; empty
    /// shows every row.
    public static let hiddenKey = "latent.metadata.hiddenRows"

    public static func hidden(from stored: String) -> Set<String> {
        Set(stored.split(separator: "\n").map(String.init))
    }

    public static func stored(_ hidden: Set<String>) -> String {
        hidden.sorted().joined(separator: "\n")
    }
}

public extension ImageRecord {
    /// The extras' rows for one photo, unknown values left out.
    var extraMetadataRows: [(label: String, value: String)] {
        var rows: [(String, String)] = []
        if let exposureBias { rows.append(("Exposure bias", MetadataFormat.exposureBias(exposureBias))) }
        if let flashFired { rows.append(("Flash", MetadataFormat.flash(flashFired))) }
        if let meteringMode { rows.append(("Metering", MetadataFormat.meteringMode(meteringMode))) }
        if let whiteBalanceMode { rows.append(("White balance", MetadataFormat.whiteBalanceMode(whiteBalanceMode))) }
        if let gpsLatitude, let gpsLongitude {
            rows.append(("GPS", MetadataFormat.coordinates(latitude: gpsLatitude, longitude: gpsLongitude)))
        }
        if let gpsAltitude, GeoPosition.isValidAltitude(gpsAltitude) { rows.append(("Altitude", MetadataFormat.altitude(gpsAltitude))) }
        return rows.map { (label: $0.0, value: $0.1) }
    }

    /// The extras' rows for several photos: a row's value when they all
    /// share it, "Various" when they differ (one with none counts as
    /// differing), left out when none has it.
    static func extraMetadataRows(for records: [ImageRecord]) -> [(label: String, value: String)] {
        guard let first = records.first else { return [] }
        if records.count == 1 { return first.extraMetadataRows }
        let perRecord = records.map { Dictionary($0.extraMetadataRows.map { ($0.label, $0.value) },
                                                 uniquingKeysWith: { a, _ in a }) }
        return MetadataRow.extraLabels.compactMap { label in
            let values = perRecord.map { $0[label] }
            guard values.contains(where: { $0 != nil }) else { return nil }
            let distinct = Set(values.map { $0 ?? "" })
            return (label: label, value: distinct.count == 1 ? values[0] ?? "" : MetadataRow.various)
        }
    }
}
