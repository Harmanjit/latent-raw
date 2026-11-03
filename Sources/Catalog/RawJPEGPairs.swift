import Foundation
import RawCore

/// RAW+JPEG pairs: a camera set to record both writes `DSC_0107.NEF` and
/// `DSC_0107.JPG` side by side. Lightroom treats the JPEG as a sidecar of
/// the raw by default, and so does Latent: the library shows the raw
/// alone, and the JPEG goes wherever the raw is moved, copied or renamed.
/// Library › Settings can show the JPEGs as photos of their own instead.
///
/// A pair is a raw and a JPEG or HEIF (`RenderedImageFormat.pairCompanionExtensions`)
/// in the same folder with the same name apart from the extension,
/// compared without regard to case, since cameras write `.JPG` and
/// copying tools sometimes lower it. Nothing is stored: the pairing is
/// read from the names whenever the list changes, so a file renamed or
/// deleted in Finder simply stops being paired.
public enum RawJPEGPairs {
    /// The key two files of a pair share: folder and name without
    /// extension, case folded.
    static func key(forRelPath relPath: String) -> String {
        (relPath as NSString).deletingPathExtension.lowercased()
    }

    static func isRaw(_ relPath: String) -> Bool {
        Catalog.rawExtensions.contains((relPath as NSString).pathExtension.lowercased())
    }

    static func isCompanion(_ relPath: String) -> Bool {
        RenderedImageFormat.pairCompanionExtensions.contains((relPath as NSString).pathExtension.lowercased())
    }

    /// Companion path → the raw path it belongs to. When two raws share a
    /// name (a NEF and a DNG made from it) the companion goes with the first
    /// in path order, so the answer never depends on the list's order.
    public static func companions(in relPaths: [String]) -> [String: String] {
        var raws: [String: String] = [:]
        for path in relPaths where isRaw(path) {
            let key = key(forRelPath: path)
            if let existing = raws[key], existing < path { continue }
            raws[key] = path
        }
        guard !raws.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for path in relPaths where isCompanion(path) {
            if let raw = raws[key(forRelPath: path)] { result[path] = raw }
        }
        return result
    }

    /// Raw image id → its companions' records, from the records themselves.
    public static func companionsByRaw(in records: [ImageRecord]) -> [Int64: [ImageRecord]] {
        let pairs = companions(in: records.map(\.relPath))
        guard !pairs.isEmpty else { return [:] }
        var idByPath: [String: Int64] = [:]
        for record in records { if let id = record.id { idByPath[record.relPath] = id } }
        var result: [Int64: [ImageRecord]] = [:]
        for record in records {
            guard let raw = pairs[record.relPath], let rawID = idByPath[raw] else { continue }
            result[rawID, default: []].append(record)
        }
        return result
    }

    /// The name a companion takes when its raw is renamed or numbered to
    /// `rawName`: the raw's new name with the companion's own extension,
    /// as it was spelled (`DSC_0107.JPG` follows `Trip 001.NEF` to
    /// `Trip 001.JPG`).
    public static func companionName(forRawName rawName: String, companion: String) -> String {
        let ext = (companion as NSString).pathExtension
        let stem = (rawName as NSString).deletingPathExtension
        return ext.isEmpty ? stem : stem + "." + ext
    }
}
