import Foundation

/// What a lens is *sold as*: its focal range and widest apertures, the
/// "17-55mm f/2.8" printed on the barrel.
///
/// The matcher needs this to rule candidates out. A raw file rarely names
/// its lens, but the camera does report the lens's range and maximum
/// apertures, and a profile for a lens with a different range or a
/// different maximum aperture is a different lens, however closely its
/// calibration data happens to fit the shot.
///
/// Lensfun doesn't store these as data for most lenses (64 of ~1,600
/// entries carry `<focal>`/`<aperture>` elements), so they're read from
/// the model name, the way Lensfun's own `lfLens::GuessParameters` does.
public struct LensSpec: Sendable, Equatable {
    /// Shortest and longest focal length, in mm. A prime has lo == hi.
    public var focal: ClosedRange<Float>?
    /// Widest aperture (smallest f-number) at the short end.
    public var apertureAtShortEnd: Float?
    /// Widest aperture at the long end. Equal to the short end for
    /// constant-aperture zooms and primes ("f/2.8", not "f/2.8-4").
    public var apertureAtLongEnd: Float?

    public init(focal: ClosedRange<Float>? = nil, apertureAtShortEnd: Float? = nil,
                apertureAtLongEnd: Float? = nil) {
        self.focal = focal
        self.apertureAtShortEnd = apertureAtShortEnd
        self.apertureAtLongEnd = apertureAtLongEnd
    }

    /// Reads the spec out of a Lensfun model name. Handles the spellings
    /// the database actually uses:
    ///
    /// - "Nikon AF-S DX Nikkor 16-80mm f/2.8-4E ED VR"   (mm, then f/)
    /// - "200-500mm F5.6 174", "Samyang 35mm T1.5 Cine"  (F or T, no slash)
    /// - "Minolta MD 35mm 1/2.8", "Summicron-M 1:2/50"   (1/ and 1: ratios)
    /// - "LUMIX G VARIO 100-300/F4.0-5.6II"              (focal/F aperture)
    /// - "Zeiss Touit 1.8/32", "Viltrox AF 56/1.4 XF"    (Zeiss-style pairs)
    ///
    /// Anything it can't read stays nil; the matcher then treats that part
    /// of the spec as unknown rather than guessing.
    public static func parse(modelName name: String) -> LensSpec {
        var spec = LensSpec()
        // "XF100-400mm… + 1.4x converter": the numbers are the bare lens's,
        // not the combination's, so this entry's spec is unknown.
        let lower = name.lowercased()
        if lower.contains("converter") || lower.contains(" + ") { return spec }

        // Focal length with a unit: "16-80mm", "10.5mm", "29 mm".
        if let m = firstMatch(focalWithUnit, in: name), let lo = m[0] {
            spec.focal = range(lo, m[1])
        }

        // Aperture with a marker: f/2.8, F5.6, f2, T1.5, 1:2.8, 1/2.8.
        // The marker must not follow a letter or digit, or "AF 100mm" would
        // read as f/100 and "11CA 10/1000" as 1:0, except straight after
        // "mm" as Fujifilm writes it ("XF18-55mmF2.8-4"). A leading zero is
        // refused so Tamron's "F012" model code isn't taken for f/12.
        if let m = firstMatch(apertureWithMarker, in: name), let wide = m[0] {
            spec.apertureAtShortEnd = wide
            spec.apertureAtLongEnd = m[1] ?? wide
        }

        // Panasonic's "focal/F aperture" (no mm): "12-60/F2.8-4.0".
        if spec.focal == nil, let m = firstMatch(focalSlashF, in: name), let lo = m[0] {
            spec.focal = range(lo, m[1])
        }

        // Zeiss, Leica and Soviet names pair the two without markers:
        // "2.8/21", "1:2.8-4/24-90", "56/1.4". The aperture is always the
        // smaller number of the pair (no lens is faster than f/1 at 1mm).
        if spec.focal == nil || spec.apertureAtShortEnd == nil,
           let m = firstMatch(slashPair, in: name), let a0 = m[0], let b0 = m[2] {
            let left = (a0, m[1] ?? a0), right = (b0, m[3] ?? b0)
            let (aperture, focal) = left.0 <= right.0 ? (left, right) : (right, left)
            if spec.focal == nil { spec.focal = min(focal.0, focal.1)...max(focal.0, focal.1) }
            if spec.apertureAtShortEnd == nil {
                spec.apertureAtShortEnd = aperture.0
                spec.apertureAtLongEnd = aperture.1
            }
        }

        // Sanity: an f-number outside f/0.7...f/64 is a misread.
        if let a = spec.apertureAtShortEnd, !(0.7...64).contains(a) {
            spec.apertureAtShortEnd = nil
            spec.apertureAtLongEnd = nil
        }
        return spec
    }

    /// The name's spec, falling back to the database's explicit elements
    /// where the name doesn't say. Names are preferred because they carry
    /// both ends of a variable aperture; `<aperture min=…>` holds only the
    /// short end's.
    static func resolve(names: [String], focalElement: ClosedRange<Float>?,
                        apertureElement: Float?) -> LensSpec {
        // The first name that states a focal length (the default English
        // name, normally; a language variant only when that one doesn't).
        let parsed = names.map { parse(modelName: $0) }
        var spec = parsed.first { $0.focal != nil } ?? parsed.first ?? LensSpec()
        if spec.focal == nil { spec.focal = focalElement }
        if spec.apertureAtShortEnd == nil, let apertureElement, (0.7...64).contains(apertureElement) {
            spec.apertureAtShortEnd = apertureElement
            // The long end of a variable-aperture zoom isn't recorded, so a
            // zoom gets no long-end value rather than a guessed one.
            if let focal = spec.focal, focal.lowerBound == focal.upperBound {
                spec.apertureAtLongEnd = apertureElement
            }
        }
        return spec
    }

    // MARK: - Patterns

    private static let number = #"([0-9]+(?:\.[0-9]+)?)"#
    private static let noLeadingZero = #"((?:[1-9][0-9]*|0)(?:\.[0-9]+)?)(?![0-9])"#

    nonisolated(unsafe) private static let focalWithUnit = try! NSRegularExpression(
        pattern: #"(?<![0-9.])"# + number + "(?:-" + number + #")?\s?mm"#, options: [.caseInsensitive])
    nonisolated(unsafe) private static let apertureWithMarker = try! NSRegularExpression(
        pattern: #"(?:(?<![A-Za-z0-9.])|(?<=mm))(?:[fFT]/?|1[:/])"# + noLeadingZero + "(?:-" + number + ")?")
    nonisolated(unsafe) private static let focalSlashF = try! NSRegularExpression(
        pattern: #"(?<![0-9.])"# + number + "(?:-" + number + ")?/[fF]")
    nonisolated(unsafe) private static let slashPair = try! NSRegularExpression(
        pattern: #"(?<![0-9.])"# + number + "(?:-" + number + ")?/" + number + "(?:-" + number + #")?(?![0-9])"#)

    /// The capture groups of the first match, as numbers (nil where a
    /// group didn't take part).
    private static func firstMatch(_ regex: NSRegularExpression, in s: String) -> [Float?]? {
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : Float(ns.substring(with: r))
        }
    }

    private static func range(_ a: Float, _ b: Float?) -> ClosedRange<Float> {
        let b = b ?? a
        return min(a, b)...max(a, b)
    }
}
