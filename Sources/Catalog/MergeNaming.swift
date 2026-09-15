import Foundation

/// What a Photo Merge result is called and where it goes
/// (docs/PhotoMerge.md §5, DESIGN.md §5.7).
///
/// The result goes beside its reference photo, named after it:
/// "Day 2/DSC_0107.NEF" becomes "Day 2/DSC_0107-HDR.dng". When that name is
/// taken the next free one of "-HDR-2", "-HDR-3"… is used. A hyphen and a
/// number rather than Rename's " 2", so a merge of a merge still reads as
/// what it is and the name never looks like a Finder duplicate.
///
/// A name counts as taken when anything holds it: a file (or a link), a
/// sidecar a file left behind, or a catalog row whose file has gone. A stale
/// sidecar in particular must not be reused, or its ratings and edits would
/// be given to the new photo.
public enum MergeNaming {
    /// The extension every merge result has. Lowercase, as the DNG
    /// specification writes it and as Lightroom names its merges.
    public static let fileExtension = "dng"

    /// How many numbered names are tried before giving up; a folder with a
    /// thousand merges of one photo has something else wrong.
    public static let attemptLimit = 1000

    /// The catalog-relative path of the `number`th candidate (1 is the
    /// unnumbered name) for a merge of kind `suffix` ("HDR", "Pano") whose
    /// reference photo is at `referenceRelPath`.
    public static func candidate(forReference referenceRelPath: String, suffix: String, number: Int) -> String {
        let folder = (referenceRelPath as NSString).deletingLastPathComponent
        let base = ((referenceRelPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let name = "\(base)-\(suffix)" + (number > 1 ? "-\(number)" : "") + "." + fileExtension
        return folder.isEmpty ? name : (folder as NSString).appendingPathComponent(name)
    }

    /// The first candidate `isTaken` says is free, skipping names too long
    /// for the disk. Nil when none of `limit` candidates is.
    public static func resultRelPath(forReference referenceRelPath: String, suffix: String,
                                     limit: Int = attemptLimit,
                                     isTaken: (String) throws -> Bool) rethrows -> String? {
        for number in 1...max(limit, 1) {
            let relPath = candidate(forReference: referenceRelPath, suffix: suffix, number: number)
            guard FileOperations.problem(withName: (relPath as NSString).lastPathComponent) == nil else { continue }
            if try !isTaken(relPath) { return relPath }
        }
        return nil
    }
}

extension Catalog {
    /// Whether a new image can't be placed at `relPath`: a file or link
    /// holds the name, a sidecar a file left behind does, or a row whose
    /// file has gone does. `writeMergeSidecar` refuses the same names, so a
    /// name planned here is one it accepts, unless something appears in
    /// between.
    public func mergeResultNameIsTaken(_ relPath: String) throws -> Bool {
        if try image(forRelPath: relPath) != nil { return true }
        return FileOperations.itemExists(fileURL(forRelPath: relPath))
            || FileOperations.itemExists(sidecarURL(forRelPath: relPath))
    }

    /// Plans the name of a merge result whose reference photo is at
    /// `referenceRelPath`: the first free "-HDR", "-HDR-2"… (see
    /// `MergeNaming`). Throws `FileOperations.NameProblem.taken` when every
    /// candidate is taken.
    public func planMergeResult(forReference referenceRelPath: String, suffix: String) throws -> String {
        let planned = try MergeNaming.resultRelPath(forReference: referenceRelPath, suffix: suffix) {
            try mergeResultNameIsTaken($0)
        }
        guard let planned else {
            throw FileOperations.NameProblem.taken(
                (MergeNaming.candidate(forReference: referenceRelPath, suffix: suffix, number: 1) as NSString)
                    .lastPathComponent)
        }
        return planned
    }
}
