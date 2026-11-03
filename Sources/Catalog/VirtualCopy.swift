import Foundation

/// Virtual copies: a second (third…) catalog row for one raw file, with its
/// own edit, rating, label, flag, rotation, keywords, history and
/// snapshots, as Lightroom's virtual copies are.
///
/// **How a copy is stored.** A copy is an ordinary row of `images` whose
/// `master_id` names the row of the file it shares. Its `rel_path` is the
/// master's path with a suffix, `DSC_0107.NEF#vc002-1a2b3c4d`: the copy's
/// number and a random token. Keeping the master's path in front means a
/// copy sorts straight after its master under every sort that ties on
/// path, and the rows stay unique without a second key. No real file can
/// have such a path: Latent only catalogues raw extensions, and the suffix
/// makes the extension `NEF#vc002-…`.
///
/// A trigger (migration `vcopies_v1_virtual_copies`) keeps a copy's path and
/// file facts in step with its master's row, so a rename or a move of the
/// master, by reconcile or by Latent's own Move and Rename, carries its
/// copies along without any code knowing about them, and deleting the
/// master's row deletes its copies.
///
/// **Sidecar and thumbnail.** A copy's sidecar and thumbnail are named by
/// its number and token, not its path (`_latent/xmp/.virtual-copies/
/// vc002-1a2b3c4d.xmp`), so they never have to move when the master does.
/// The sidecar carries the master's content hash, which is how reconcile
/// finds the master again when a database is rebuilt from the sidecars
/// (`restoreVirtualCopiesFromSidecars`).
public enum VirtualCopy {
    /// What marks a copy's path, between the master's path and the number.
    static let marker = "#vc"
    /// The folder, inside `xmp/` and `thumbnails/`, holding copies' files.
    /// Hidden, so no photo subfolder can ever share its name: reconcile
    /// skips hidden folders.
    public static let companionFolder = ".virtual-copies"
    static let tokenLength = 8

    /// A copy's identity: its number among its master's copies ("Copy 2")
    /// and a token unique in the catalog.
    public struct Key: Sendable, Hashable, Codable {
        public var number: Int
        public var token: String

        public init(number: Int, token: String) {
            self.number = number
            self.token = token
        }

        /// `vc002-1a2b3c4d`: the copy's sidecar and thumbnail name.
        public var stem: String { "vc" + String(format: "%03d", number) + "-" + token }

        /// What follows the master's path in the copy's path.
        public var suffix: String { "#" + stem }

        /// A fresh token: eight lowercase hex digits.
        public static func randomToken() -> String {
            String(format: "%08x", UInt32.random(in: 0...UInt32.max))
        }
    }

    /// The copy's path for a master path and key.
    public static func relPath(master: String, key: Key) -> String {
        master + key.suffix
    }

    /// Splits a copy's path into its master's path and its key, or nil when
    /// `relPath` is an ordinary file's. Reads the path backwards over its
    /// bytes, so the sorts and filters that ask for every row stay cheap.
    public static func parse(_ relPath: String) -> (masterRelPath: String, key: Key)? {
        // Native strings are contiguous UTF-8, so this reads them in place.
        var path = relPath
        if let found = path.utf8.withContiguousStorageIfAvailable(parse(bytes:)) { return found }
        path.makeContiguousUTF8()
        return path.utf8.withContiguousStorageIfAvailable(parse(bytes:)) ?? nil
    }

    private static func parse(bytes: UnsafeBufferPointer<UInt8>) -> (masterRelPath: String, key: Key)? {
        // "#vc" + at least three digits + "-" + eight hex digits, after a
        // master path of at least one byte.
        guard bytes.count >= 1 + 3 + 3 + 1 + tokenLength else { return nil }
        var index = bytes.count - 1
        for _ in 0..<tokenLength {
            let b = bytes[index]
            guard (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x66) else { return nil }
            index -= 1
        }
        guard bytes[index] == 0x2D else { return nil }   // "-"
        let digitsEnd = index
        index -= 1
        while index >= 0, bytes[index] >= 0x30, bytes[index] <= 0x39 { index -= 1 }
        guard digitsEnd - index - 1 >= 3, index >= 3,
              bytes[index] == 0x63, bytes[index - 1] == 0x76, bytes[index - 2] == 0x23 else { return nil }  // "#vc"
        let markerStart = index - 2
        let master = String(decoding: UnsafeBufferPointer(rebasing: bytes[0..<markerStart]), as: UTF8.self)
        let digits = String(decoding: UnsafeBufferPointer(rebasing: bytes[(index + 1)..<digitsEnd]), as: UTF8.self)
        let token = String(decoding: UnsafeBufferPointer(rebasing: bytes[(digitsEnd + 1)...]), as: UTF8.self)
        guard let number = Int(digits) else { return nil }
        return (master, Key(number: number, token: token))
    }

    /// The path of the file a row shows: its own for an ordinary row, its
    /// master's for a copy.
    public static func fileRelPath(_ relPath: String) -> String {
        parse(relPath)?.masterRelPath ?? relPath
    }

    /// Reads a companion file's name (`vc002-1a2b3c4d.xmp`) back into a key.
    static func key(fromCompanionName name: String) -> Key? {
        let stem = (name as NSString).deletingPathExtension
        guard stem.hasPrefix("vc"), let parsed = parse("x#" + stem), parsed.masterRelPath == "x" else { return nil }
        return parsed.key
    }

    /// "DSC_0107 (Copy 2).NEF": the name a copy shows in the grid, the
    /// panels and captions, and that exports are named from, so a copy
    /// exported beside its master doesn't take the master's name.
    public static func displayName(fileName: String, number: Int) -> String {
        let ns = fileName as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        return ext.isEmpty ? "\(base) (Copy \(number))" : "\(base) (Copy \(number)).\(ext)"
    }
}

extension ImageRecord {
    /// Whether this row is a virtual copy of another.
    public var isVirtualCopy: Bool { VirtualCopy.parse(relPath) != nil }

    /// The copy's number ("Copy 2"), nil for a master or ordinary photo.
    public var virtualCopyNumber: Int? { VirtualCopy.parse(relPath)?.key.number }

    /// The path of the raw file this row shows, relative to the catalog:
    /// the master's for a virtual copy. Everything that opens the file
    /// (the editor, exports, prints, thumbnails) goes by this.
    public var fileRelPath: String { VirtualCopy.fileRelPath(relPath) }

    /// The name of the raw file on disk, the master's for a copy, where
    /// `fileName` is the copy's own "DSC_0107 (Copy 2).NEF".
    public var sourceFileName: String { (fileRelPath as NSString).lastPathComponent }
}
