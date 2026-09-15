import Foundation

/// File names and the few file-system moves that never overwrite, for
/// Move to Folder, Copy to Folder and Rename (`ImageTransfer`).
///
/// Adapted from minivu's FileOperations. Moves on one volume are renames
/// that refuse to overwrite (`RENAME_EXCL`), so a file that appears at the
/// destination between the check and the move is never clobbered, and a
/// copy goes to a hidden name first and is renamed into place the same
/// way, so no half-copied file ever carries a real name. Nothing here
/// deletes anything but its own temporary files. Synchronous file-system
/// work: call it off the main thread.
public enum FileOperations {
    // MARK: - Names

    /// Why a name can't be used.
    public enum NameProblem: Error, Equatable, Sendable, CustomStringConvertible {
        case empty
        case separator
        case controlCharacter
        case leadingDot
        case tooLong
        /// Another file, or a sidecar left by one, already has the name.
        case taken(String)

        public var description: String {
            switch self {
            case .empty: "The name can’t be empty."
            case .separator: "The name can’t contain “/” or “:”."
            case .controlCharacter: "The name can’t contain control characters."
            case .leadingDot: "Names that begin with a dot “.” are hidden and reserved for the system."
            case .tooLong: "The name is too long."
            case .taken(let name): "The name “\(name)” is already taken. Please choose a different name."
            }
        }
    }

    /// The rules for a name in itself, whatever folder it goes in.
    public static func problem(withName name: String) -> NameProblem? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return .empty }
        // Finder shows a ":" in a name as "/", and "/" separates paths.
        if name.contains("/") || name.contains(":") { return .separator }
        if name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return .controlCharacter }
        if name.hasPrefix(".") { return .leadingDot }
        // APFS and HFS+ allow 255 bytes of UTF-8 in a name.
        if name.utf8.count > 255 { return .tooLong }
        return nil
    }

    /// The file name a rename to `base` gives `original`: the extension is
    /// always the original's, so a raw file stays one Latent indexes. A
    /// base typed with that extension on the end ("Sunset.NEF") isn't given
    /// it twice. Surrounding spaces are dropped, as Finder does.
    public static func renamedFileName(base: String, original: String) -> Result<String, NameProblem> {
        let ext = (original as NSString).pathExtension
        var stem = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ext.isEmpty, (stem as NSString).pathExtension.caseInsensitiveCompare(ext) == .orderedSame,
           !(stem as NSString).deletingPathExtension.isEmpty {
            stem = (stem as NSString).deletingPathExtension
        }
        let name = ext.isEmpty ? stem : stem + "." + ext
        if stem.isEmpty { return .failure(.empty) }
        if let problem = problem(withName: name) { return .failure(problem) }
        return .success(name)
    }

    /// "DSC_0107.NEF" -> "DSC_0107 2.NEF", "DSC_0107 3.NEF"… the first
    /// `isTaken` says is free, or nil after `limit` tries. A name that
    /// already ends in a counter continues it ("A 2.NEF" -> "A 3.NEF"); only
    /// 1–3 digits without a leading zero count as one, so "IMG 0042.NEF"
    /// becomes "IMG 0042 2.NEF".
    public static func uniqueName(for name: String, limit: Int = 10_000, isTaken: (String) throws -> Bool) rethrows -> String? {
        guard try isTaken(name) else { return name }
        var base = name, ext = ""
        let e = (name as NSString).pathExtension
        let b = (name as NSString).deletingPathExtension
        if !e.isEmpty && !b.isEmpty { base = b; ext = e }
        var n = 2
        if let (stem, counter) = trailingCounter(base) { base = stem; n = counter + 1 }
        for _ in 0..<limit {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if try !isTaken(candidate), problem(withName: candidate) == nil { return candidate }
            n += 1
        }
        return nil
    }

    /// "photo 2" -> ("photo", 2); nil when there's no counter.
    static func trailingCounter(_ base: String) -> (String, Int)? {
        guard let space = base.lastIndex(of: " ") else { return nil }
        let digits = base[base.index(after: space)...]
        let stem = base[..<space]
        guard (1...3).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              digits.first != "0", let value = Int(digits), value >= 2,
              !stem.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (String(stem), value)
    }

    // MARK: - Identity

    /// A file's device and inode: the same file whatever its path is spelt
    /// as (case, a symlinked /tmp).
    public struct Identity: Hashable, Sendable {
        public var device: Int32
        public var inode: UInt64
    }

    /// lstat, so a broken symlink still counts as taking its name.
    public static func identity(_ url: URL) -> Identity? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return Identity(device: st.st_dev, inode: st.st_ino)
    }

    /// The device a folder is on, following links.
    static func device(ofFolder url: URL) -> Int32? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return st.st_dev
    }

    static func itemExists(_ url: URL) -> Bool { identity(url) != nil }

    static func isDirectory(_ url: URL) -> Bool {
        var st = stat()
        return stat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    // MARK: - Moves that never overwrite

    /// A rename that refuses to overwrite. Throws a Cocoa error; across
    /// volumes that is `crossDevice`, for the caller to copy instead.
    static func renameExclusively(_ source: URL, to destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) != 0 else { return }
        throw cocoaError(errno: errno, source: source, destination: destination)
    }

    /// `renameExclusively`, except that a destination which is the source
    /// under another spelling (a change of letter case on a case-insensitive
    /// volume) is renamed through a hidden temporary name.
    static func renameAllowingCaseChange(_ source: URL, to destination: URL) throws {
        do {
            try renameExclusively(source, to: destination)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            guard let from = identity(source), identity(destination) == from else { throw error }
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent(".latent-rename-\(UUID().uuidString)")
            try renameExclusively(source, to: temporary)
            do {
                try renameExclusively(temporary, to: destination)
            } catch {
                try? renameExclusively(temporary, to: source)
                throw error
            }
        }
    }

    /// Copies to a hidden temporary name beside `destination` (a clone on
    /// APFS, dates and extended attributes kept), then renames the copy into
    /// place without overwriting. A copy that fails, or finds the name taken
    /// since it was checked, leaves nothing behind.
    static func copyExclusively(_ source: URL, to destination: URL) throws {
        let temporary = temporaryURL(beside: destination)
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
            try renameExclusively(temporary, to: destination)
        } catch {
            if itemExists(temporary) { try? FileManager.default.removeItem(at: temporary) }
            throw error
        }
    }

    /// A hidden name in `destination`'s folder. Hidden, so a reconcile that
    /// runs meanwhile, or Finder, never lists a half-made file.
    static func temporaryURL(beside destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".latent-transfer-\(UUID().uuidString)")
    }

    /// POSIX failures as Cocoa errors, whose descriptions read as sentences.
    static func cocoaError(errno code: Int32, source: URL, destination: URL) -> Error {
        let underlying = POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        switch code {
        case EEXIST, ENOTEMPTY:
            return CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path, NSUnderlyingErrorKey: underlying])
        case ENOENT:
            return CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path, NSUnderlyingErrorKey: underlying])
        case EACCES, EPERM:
            return CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: destination.path, NSUnderlyingErrorKey: underlying])
        case ENOSPC:
            return CocoaError(.fileWriteOutOfSpace, userInfo: [NSFilePathErrorKey: destination.path, NSUnderlyingErrorKey: underlying])
        case EROFS:
            return CocoaError(.fileWriteVolumeReadOnly, userInfo: [NSFilePathErrorKey: destination.path, NSUnderlyingErrorKey: underlying])
        case EXDEV:
            return CrossDeviceError()
        default:
            return CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: source.path, NSUnderlyingErrorKey: underlying])
        }
    }

    /// rename(2) can't cross volumes; the caller copies instead.
    struct CrossDeviceError: Error {}
}
