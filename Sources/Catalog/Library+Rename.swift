import Foundation

extension Library {
    /// Plans renaming `records` (in this order, for the sequence numbers)
    /// with a filename template, checking each new name against the files
    /// in the folder and the photos in the catalog. See `RenamePlan`.
    public func renamePlan(for records: [ImageRecord], template: String, customText: String,
                           start: Int = 1, padding: Int = 3,
                           letterCase: ExportNaming.LetterCase = .unchanged) -> RenamePlan {
        let root = catalog?.rootPath
        let catalogued = Set(images.map { $0.relPath.lowercased() })
        let xmp = catalog?.containerPath.appendingPathComponent("xmp", isDirectory: true)
        return RenamePlan.make(records, template: template, customText: customText, start: start, padding: padding,
                               catalogName: folderURL?.lastPathComponent ?? "", letterCase: letterCase) { relPath in
            if catalogued.contains(relPath.lowercased()) { return true }
            guard let root else { return false }
            // A file the catalog doesn't index (a JPEG beside the raws), or
            // a sidecar a deleted photo left, which would be given to this one.
            if FileOperations.itemExists(root.appendingPathComponent(relPath)) { return true }
            if let xmp, FileOperations.itemExists(xmp.appendingPathComponent(relPath + ".xmp")) { return true }
            return false
        }
    }
}
