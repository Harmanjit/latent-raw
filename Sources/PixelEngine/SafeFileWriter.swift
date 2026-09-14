import Foundation

/// Writes export files so that a crash, a full disk, an encoder error or a
/// cancelled export never leaves a half-written picture behind, and never
/// costs the file that was there before.
///
/// The new file is written under a hidden temporary name, flushed to disk,
/// and only then moved to its real name. Until that move the old file (if
/// any) is untouched; after it the new file is complete. The temporary file
/// sits in the destination folder rather than the temporary directory,
/// because a rename is only atomic within one volume.
///
/// Under the sandbox that needs write access to the folder, which an export
/// folder chosen in the open panel has (its bookmark covers the folder). A
/// Save panel is different: "Export open image" is granted the one file the
/// user named, not its folder, so no sibling can be created there. Then the
/// temporary file goes in the system's item-replacement folder for that
/// volume, which the sandbox allows and which is on the same volume, so the
/// final move is still atomic.
///
/// Replacing goes through `FileManager.replaceItemAt`, which carries the old
/// file's creation date, permissions and extended attributes (Finder tags)
/// over to the new one.
public enum SafeFileWriter {
    /// A file on its way to `destination`: write the complete file to `url`,
    /// then `commit()`. `discard()` (in a `defer`) removes whatever wasn't
    /// committed, so every early exit, thrown error or cancellation cleans
    /// up; after a commit it only tidies the scratch folder.
    public struct PendingWrite: Sendable {
        /// The temporary file to write.
        public let url: URL
        /// Where the file goes, symbolic links resolved.
        public let destination: URL
        let scratchFolder: URL?

        /// Puts the written file in place of `destination` (creating it if
        /// nothing is there). Throws, leaving `destination` as it was, if the
        /// file wasn't written or can't be moved.
        public func commit() throws {
            try SafeFileWriter.refuseFolder(at: destination)
            try SafeFileWriter.synchronize(url)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: url,
                                                          backupItemName: nil, options: [])
            } else {
                try FileManager.default.moveItem(at: url, to: destination)
            }
        }

        /// Deletes the temporary file if it's still there, and the scratch folder.
        public func discard() {
            if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
            if let scratchFolder { try? FileManager.default.removeItem(at: scratchFolder) }
        }
    }

    /// Starts a write to `url`. A symbolic link is followed: the file it
    /// points at is replaced and the link stays a link. A folder at `url` is
    /// refused, here and again at commit, because `replaceItemAt` would swap
    /// the file in and delete the folder with everything inside it.
    public static func begin(_ url: URL) throws -> PendingWrite {
        try begin(url, canCreateSibling: probeCreate)
    }

    static func begin(_ url: URL, canCreateSibling: (URL) -> Bool) throws -> PendingWrite {
        let url = url.resolvingSymlinksInPath()
        try refuseFolder(at: url)
        let (temp, scratchFolder) = temporaryLocation(for: url, canCreateSibling: canCreateSibling)
        return PendingWrite(url: temp, destination: url, scratchFolder: scratchFolder)
    }

    /// Calls `fill` with a temporary URL, which it must create and write the
    /// complete file to, then puts that file in place of `url`. If `fill` or
    /// anything after it throws, the temporary file is deleted and `url` is
    /// left as it was.
    public static func replace(_ url: URL, fill: (URL) throws -> Void) throws {
        try replace(url, canCreateSibling: probeCreate, fill: fill)
    }

    static func replace(_ url: URL, canCreateSibling: (URL) -> Bool, fill: (URL) throws -> Void) throws {
        let pending = try begin(url, canCreateSibling: canCreateSibling)
        defer { pending.discard() }
        try fill(pending.url)
        try pending.commit()
    }

    static func refuseFolder(at url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw CocoaError(.fileWriteFileExists, userInfo: [
                NSLocalizedDescriptionKey: "A folder named “\(url.lastPathComponent)” is in the way.",
                NSFilePathErrorKey: url.path,
            ])
        }
    }

    /// Writes `data` to `url` the same way.
    public static func write(_ data: Data, to url: URL) throws {
        try replace(url) { temp in try data.write(to: temp, options: .withoutOverwriting) }
    }

    /// Where to write the temporary file: a hidden sibling when the folder
    /// accepts new files, otherwise a fresh item-replacement folder on the
    /// same volume (returned so it can be removed afterwards).
    /// `canCreateSibling` is injectable for tests; by default it tries to
    /// create the sibling, which is the only reliable test under the sandbox
    /// (`access(2)` reports POSIX permissions, not sandbox rules).
    static func temporaryLocation(for url: URL, canCreateSibling: (URL) -> Bool = probeCreate) -> (URL, URL?) {
        let sibling = temporaryURL(for: url)
        if canCreateSibling(sibling) { return (sibling, nil) }
        if let folder = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                     appropriateFor: url, create: true) {
            return (folder.appendingPathComponent(sibling.lastPathComponent, isDirectory: false), folder)
        }
        return (sibling, nil)
    }

    static func probeCreate(_ url: URL) -> Bool {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return false }
        close(fd)
        unlink(url.path)
        return true
    }

    /// A hidden sibling (the leading dot keeps it out of Finder) with a
    /// random part, so two writes never collide. The ".tmp" ending means a
    /// catalog scanning the folder never takes it for a photo. File names
    /// are limited to 255 bytes and the additions take 22, so a very long
    /// name is shortened first, by whole characters so it stays valid UTF-8.
    static func temporaryURL(for url: URL) -> URL {
        let token = UUID().uuidString.prefix(8)
        var name = url.lastPathComponent
        while name.utf8.count > 200 { name.removeLast() }
        return url.deletingLastPathComponent()
            .appendingPathComponent(".\(name).latent-\(token).tmp", isDirectory: false)
    }

    /// Asks the kernel to put the file's data on disk before the rename, so
    /// a power cut can't leave the rename done but the data missing. `fsync`,
    /// not `F_FULLFSYNC`: the latter also flushes the drive's own cache but
    /// costs tens of milliseconds a file, which adds up over a batch, and
    /// APFS's copy-on-write metadata already keeps the old or the new file whole.
    static func synchronize(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
