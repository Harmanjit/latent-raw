import Foundation

/// Turns the numbers LibRaw gives us into the strings photographers read.
///
/// Pure functions, kept out of the view so they can be unit tested and
/// reused (the status bar, tooltips and export file naming all want the
/// same "1/250 s · ƒ/2.8 · ISO 400" vocabulary).
public enum MetadataFormat {
    /// Exposure time as photographers write it: "1/250 s" below a second,
    /// "2.5 s" above, "1/3 s" for the awkward middle. Camera shutters step
    /// in thirds, so 0.3333 must become 1/3, not 1/3.0003.
    public static func shutter(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        if seconds >= 1 {
            // Whole seconds print as integers, otherwise one decimal.
            let rounded = (seconds * 10).rounded() / 10
            return rounded == rounded.rounded()
                ? "\(Int(rounded)) s"
                : String(format: "%.1f s", rounded)
        }
        let denominator = 1 / seconds
        // Nearest integer reciprocal; 0.004 → 250, 0.3333 → 3.
        let d = Int(denominator.rounded())
        if d >= 1, abs(denominator - Double(d)) / denominator < 0.02 {
            return "1/\(d) s"
        }
        return String(format: "1/%.1f s", denominator)
    }

    /// "ƒ/2.8", or "ƒ/8" when the decimal is zero. The ƒ (U+0192) is the
    /// conventional glyph; it reads as a lens marking, not a variable.
    public static func aperture(_ f: Double) -> String {
        guard f > 0 else { return "—" }
        let tenths = (f * 10).rounded() / 10
        return tenths == tenths.rounded()
            ? "ƒ/\(Int(tenths))"
            : String(format: "ƒ/%.1f", tenths)
    }

    public static func iso(_ iso: Int) -> String {
        iso > 0 ? "ISO \(iso)" : "—"
    }

    /// "50 mm" or "24.5 mm". Zooms report fractional focal lengths.
    public static func focalLength(_ mm: Double) -> String {
        guard mm > 0 else { return "—" }
        let tenths = (mm * 10).rounded() / 10
        return tenths == tenths.rounded()
            ? "\(Int(tenths)) mm"
            : String(format: "%.1f mm", tenths)
    }

    /// "6016 × 4016 (24.2 MP)". Megapixels to one decimal, the way camera
    /// makers quote them.
    public static func dimensions(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "—" }
        let mp = Double(width * height) / 1_000_000
        return String(format: "%d × %d (%.1f MP)", width, height, mp)
    }

    /// "24.3 MB" using decimal units, matching what Finder shows.
    public static func fileSize(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f.string(fromByteCount: bytes)
    }

    /// Capture time in the user's locale, medium date and short time:
    /// "13 Sep 2026 at 10:41".
    public static func captureTime(_ unixSeconds: Int64, timeZone: TimeZone = .current) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.timeZone = timeZone
        return f.string(from: date)
    }

    /// The one-line exposure summary shown under a photo everywhere:
    /// "1/250 s · ƒ/2.8 · ISO 400 · 50 mm". Missing values are skipped
    /// rather than shown as dashes, so a file with no lens data still
    /// reads cleanly.
    public static func exposureLine(shutter: Double?, aperture: Double?,
                                    iso: Int?, focal: Double?) -> String {
        var parts: [String] = []
        if let s = shutter, s > 0 { parts.append(Self.shutter(s)) }
        if let a = aperture, a > 0 { parts.append(Self.aperture(a)) }
        if let i = iso, i > 0 { parts.append(Self.iso(i)) }
        if let f = focal, f > 0 { parts.append(focalLength(f)) }
        return parts.joined(separator: " · ")
    }
}

public extension ImageRecord {
    /// Label/value rows for a metadata panel, in the order photographers
    /// expect (camera, lens, exposure, then the file). Rows whose value is
    /// unknown are omitted, so the panel never shows a column of dashes.
    var metadataRows: [(label: String, value: String)] {
        var rows: [(String, String)] = []
        if let camera { rows.append(("Camera", camera)) }
        if let lens { rows.append(("Lens", lens)) }
        if let shutter, shutter > 0 { rows.append(("Shutter", MetadataFormat.shutter(shutter))) }
        if let aperture, aperture > 0 { rows.append(("Aperture", MetadataFormat.aperture(aperture))) }
        if let iso, iso > 0 { rows.append(("ISO", "\(iso)")) }
        if let focal, focal > 0 { rows.append(("Focal length", MetadataFormat.focalLength(focal))) }
        if let captureTime { rows.append(("Captured", MetadataFormat.captureTime(captureTime))) }
        if let width, let height, width > 0, height > 0 {
            rows.append(("Size", MetadataFormat.dimensions(width: width, height: height)))
        }
        rows.append(("File", MetadataFormat.fileSize(size)))
        return rows.map { (label: $0.0, value: $0.1) }
    }

    var exposureLine: String {
        MetadataFormat.exposureLine(shutter: shutter, aperture: aperture, iso: iso, focal: focal)
    }
}
