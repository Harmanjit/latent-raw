import Foundation
import GRDB
import os

/// Whether a transfer leaves the original where it was.
public enum TransferMode: String, Sendable, Equatable {
    case move, copy
}

/// What a transfer does to the image's xmpMM:PreservedFileName, the name
/// the file had when it was first catalogued.
public enum PreservedNameChange: Sendable, Equatable {
    /// Leave it as it is.
    case keep
    /// When the file gets a new name and has no preserved name yet, record
    /// the name it had. Otherwise leave it.
    case recordOriginal
    /// Set it to exactly this; undo puts back what was there.
    case exactly(String?)
}

/// One image to move or copy.
public struct TransferRequest: Sendable, Equatable {
    public var source: URL
    public var folder: URL
    /// Nil keeps the file's name, numbered when the destination already has
    /// it ("A 2.NEF"). A name is used exactly, or the image fails.
    public var name: String?
    public var preservedName: PreservedNameChange

    public init(source: URL, folder: URL, name: String? = nil, preservedName: PreservedNameChange = .recordOriginal) {
        self.source = source
        self.folder = folder
        self.name = name
        self.preservedName = preservedName
    }
}

/// What one transfer did, enough to undo it.
public struct CompletedTransfer: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case move, copy
        /// A copy put in the Trash (undoing `copy`). `source` is still the
        /// original it was made from, `destination` where the copy was.
        case trash
    }

    public var kind: Kind
    public var source: URL
    public var destination: URL
    /// The copy as it was made, so undoing it trashes only that file and
    /// never one put there since.
    public var destinationIdentity: FileOperations.Identity?
    public var preservedNameChanged: Bool
    public var previousPreservedName: String?
    public var newPreservedName: String?
}

/// What a batch did.
public struct TransferReport: Sendable {
    public struct Failure: Sendable, Equatable {
        public var url: URL
        public var reason: String
    }

    public var completed: [CompletedTransfer] = []
    /// Already where they were asked to go.
    public var skipped: [URL] = []
    public var failures: [Failure] = []
    public var wasCancelled = false

    public init() {}

    /// "A.NEF (The name “A.NEF” is already taken…); B.NEF (…)".
    public var failureDescription: String {
        failures.map { "\($0.url.lastPathComponent) (\($0.reason))" }.joined(separator: "; ")
    }
}

/// Failures tests inject into a transfer (`ImageTransfer.run`).
public struct TransferFaults: Sendable {
    /// Runs once an image is copied or ready to move, before anything is in
    /// its new place.
    public var beforePlacing: (@Sendable (URL) throws -> Void)?
    /// Runs part-way through placing it: after a move's file, before its
    /// sidecar; or after a sidecar went to another catalog, before the file.
    public var midway: (@Sendable (URL) throws -> Void)?

    public init(beforePlacing: (@Sendable (URL) throws -> Void)? = nil, midway: (@Sendable (URL) throws -> Void)? = nil) {
        self.beforePlacing = beforePlacing
        self.midway = midway
    }
}

/// Stops a batch between images. The image being transferred always
/// finishes, so nothing is left half-moved.
public final class TransferCancellation: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    public init() {}
    public func cancel() { state.withLock { $0 = true } }
    public var isCancelled: Bool { state.withLock { $0 } }
}

/// Moves and copies raw files between folders with everything Latent keeps
/// about them: the XMP sidecar (the source of truth for ratings, keywords
/// and edits), the thumbnail and the catalog row.
///
/// **Which catalog.** A folder's files belong to the nearest catalog that
/// would index them: its own `_latent`, or an enclosing folder's that
/// includes it (DESIGN.md §5.2), or, when neither, the catalog the folder
/// will have once it is opened. Sidecars and thumbnails go into that
/// catalog's `_latent` (created when there is a sidecar to put there).
///
/// **Rows.** Only the catalog the Library has open is written to, through
/// its actor, and each image's sidecar, thumbnail and row change in one
/// actor step, so a rating given meanwhile can't land between them. Every
/// other catalog catches up on its next reconcile from files left in a
/// state reconcile already understands: a sidecar waiting beside a new
/// file is applied to it, a file gone takes its row with it, and within one
/// catalog a moved file is recognised by its hash.
///
/// **Safety.** Nothing is overwritten: a name that is taken, by a file, by a
/// sidecar left behind by one, or by a row, gets a number or fails.
/// Nothing the user made is deleted: the original of a move goes only once
/// its copy is whole in the new place, its sidecar once the new one is
/// written, and undoing a copy puts the copy in the Trash. Each image
/// either moves completely or is left where it was.
public enum ImageTransfer {
    /// Transfers `requests` in order. Each image's work is off the main
    /// thread. `progress(done, total)` is called after each image;
    /// `cancellation` is checked before each.
    ///
    /// `faults` is for tests, to fail an image at the points where a
    /// failure must leave it where it was.
    public static func run(_ requests: [TransferRequest], mode: TransferMode, openCatalog: Catalog?,
                           cancellation: TransferCancellation? = nil,
                           progress: (@Sendable (Int, Int) -> Void)? = nil,
                           faults: TransferFaults = TransferFaults()) async -> TransferReport {
        var report = TransferReport()
        // The open catalog's rows, not its sidecars, are what an image takes
        // with it; a sidecar changed outside Latent is read into them first.
        if let openCatalog, !requests.isEmpty {
            do {
                _ = try await openCatalog.reconcile()
            } catch {
                logger.error("Reconcile before a transfer failed: \(String(describing: error), privacy: .private)")
            }
        }
        var destinations: [String: CatalogLocation] = [:]
        for (index, request) in requests.enumerated() {
            if cancellation?.isCancelled == true {
                report.wasCancelled = true
                break
            }
            do {
                let key = request.folder.standardizedFileURL.path
                let destination: CatalogLocation
                if let known = destinations[key] {
                    destination = known
                } else {
                    destination = try await checkedDestination(request.folder, openCatalog: openCatalog)
                    destinations[key] = destination
                }
                if let done = try await transfer(request, mode: mode, destination: destination,
                                                 openCatalog: openCatalog, faults: faults) {
                    report.completed.append(done)
                } else {
                    report.skipped.append(request.source)
                }
            } catch {
                report.failures.append(.init(url: request.source, reason: describe(error)))
                logger.error("Transferring \(request.source.lastPathComponent, privacy: .private) failed: \(String(describing: error), privacy: .private)")
            }
            progress?(index + 1, requests.count)
        }
        return report
    }

    /// Undoes copies: each copy, with its sidecar, goes to the Trash through
    /// `recycle`, its thumbnail is removed (it can be made again) and, in
    /// the open catalog, its row. A copy changed or replaced since it was
    /// made is left alone.
    public static func trash(_ copies: [CompletedTransfer], openCatalog: Catalog?,
                             recycle: @Sendable ([URL]) async throws -> Void,
                             cancellation: TransferCancellation? = nil,
                             progress: (@Sendable (Int, Int) -> Void)? = nil) async -> TransferReport {
        var report = TransferReport()
        for (index, copy) in copies.enumerated() {
            if cancellation?.isCancelled == true {
                report.wasCancelled = true
                break
            }
            let url = copy.destination.standardizedFileURL
            do {
                guard let identity = FileOperations.identity(url) else {
                    throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
                }
                if let expected = copy.destinationIdentity, expected != identity {
                    throw TransferError.changedSinceCopied
                }
                let location = try await location(ofFolder: url.deletingLastPathComponent(), openCatalog: openCatalog)
                let relPath = location.relPath(url.lastPathComponent)
                let sidecar = location.sidecarURL(relPath)
                try await recycle(FileOperations.itemExists(sidecar) ? [url, sidecar] : [url])
                if let openCatalog, isSameFolder(location.root, openCatalog.rootPath) {
                    try await openCatalog.forgetTrashedImage(relPath: relPath)
                }
                try? FileManager.default.removeItem(at: location.thumbnailURL(relPath))
                var done = copy
                done.kind = .trash
                report.completed.append(done)
            } catch {
                report.failures.append(.init(url: url, reason: describe(error)))
            }
            progress?(index + 1, copies.count)
        }
        return report
    }

    static let logger = Logger(subsystem: "com.latent.app", category: "catalog")

    enum TransferError: Error, CustomStringConvertible {
        case notAFile
        case insideCatalogContainer
        case destinationMissing
        case changedSinceCopied
        case originalNotRemoved(copy: URL, reason: String)

        var description: String {
            switch self {
            case .notAFile: "Only image files can be moved or copied."
            case .insideCatalogContainer: "Images can’t go inside a catalog’s \(Catalog.containerName) folder."
            case .destinationMissing: "The destination folder can’t be found."
            case .changedSinceCopied: "The copy has changed or been replaced since it was made, so it was left where it is."
            case .originalNotRemoved(let copy, let reason):
                "It was copied to “\(copy.deletingLastPathComponent().lastPathComponent)”, but the original couldn’t be removed: \(reason)"
            }
        }
    }

    /// Folders compared through symbolic links, so an open panel's
    /// /private/var and a catalog's /var are one folder.
    static func isSameFolder(_ a: URL, _ b: URL) -> Bool {
        FolderAccess.samePath(a, b) || FolderAccess.samePath(a.resolvingSymlinksInPath(), b.resolvingSymlinksInPath())
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case let problem as FileOperations.NameProblem: problem.description
        case let transfer as TransferError: transfer.description
        case let cocoa as CocoaError: cocoa.localizedDescription
        default: String(describing: error)
        }
    }

    // MARK: - Where things go

    /// The destination as a catalog location, refusing folders that can't
    /// take images.
    private static func checkedDestination(_ folder: URL, openCatalog: Catalog?) async throws -> CatalogLocation {
        let folder = folder.standardizedFileURL
        guard FileOperations.isDirectory(folder) else { throw TransferError.destinationMissing }
        if folder.pathComponents.contains(where: { $0 == Catalog.containerName || $0 == Catalog.legacyContainerName }) {
            throw TransferError.insideCatalogContainer
        }
        return try await location(ofFolder: folder, openCatalog: openCatalog)
    }

    /// Where the catalog that indexes (or would index) the files of `folder`
    /// keeps its sidecars. Reads the disk: the nearest folder at or above
    /// `folder` with a container, and whether that catalog includes the
    /// folders on the way down, asked of the open catalog's actor when it
    /// is that one (its database is already open) and read-only otherwise.
    static func location(ofFolder folder: URL, openCatalog: Catalog?) async throws -> CatalogLocation {
        let folder = folder.standardizedFileURL
        var ancestor = folder
        var parts: [String] = []
        while !FolderAccess.hasCatalog(ancestor) {
            guard ancestor.path != "/", !ancestor.path.isEmpty else {
                return CatalogLocation(root: folder, prefix: "")
            }
            parts.append(ancestor.lastPathComponent)
            ancestor = ancestor.deletingLastPathComponent()
        }
        guard !parts.isEmpty else { return CatalogLocation(root: folder, prefix: "") }
        let prefix = parts.reversed().joined(separator: "/")
        let included: Bool
        if let openCatalog, isSameFolder(openCatalog.rootPath, ancestor) {
            included = try await openCatalog.includesSubfolder(prefix)
        } else {
            included = FolderAccess.owningCatalog(of: folder).map { FolderAccess.samePath($0.root, ancestor) } ?? false
        }
        return included ? CatalogLocation(root: ancestor, prefix: prefix) : CatalogLocation(root: folder, prefix: "")
    }

    // MARK: - One image

    /// Everything one image's placement needs, worked out before it starts.
    struct Plan: Sendable {
        var mode: TransferMode
        var source: URL
        var sourceLocation: CatalogLocation
        /// The image's row in the open catalog, if it has one there.
        var sourceID: Int64?
        var folder: URL
        var destination: CatalogLocation
        var destinationIsOpen: Bool
        /// A complete copy of the source, hidden in `folder`, for a copy or a
        /// move to another volume.
        var temporaryCopy: URL?
        var name: String?
        var preservedName: PreservedNameChange
        /// Tests only: runs where a failure must undo what was already done
        /// (after a move's file, before its sidecar; after a sidecar went to
        /// another catalog, before the file follows).
        var midway: (@Sendable (URL) throws -> Void)?
    }

    /// Nil when the image is already where it was asked to go.
    private static func transfer(_ request: TransferRequest, mode: TransferMode, destination: CatalogLocation,
                                 openCatalog: Catalog?, faults: TransferFaults) async throws -> CompletedTransfer? {
        let source = request.source.standardizedFileURL
        let folder = request.folder.standardizedFileURL
        guard let sourceIdentity = FileOperations.identity(source) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
        }
        guard !FileOperations.isDirectory(source) else { throw TransferError.notAFile }
        let sourceFolder = source.deletingLastPathComponent()
        if mode == .move, isSameFolder(sourceFolder, folder),
           (request.name ?? source.lastPathComponent) == source.lastPathComponent {
            return nil
        }
        let sourceLocation = try await location(ofFolder: sourceFolder, openCatalog: openCatalog)
        var sourceID: Int64?
        var destinationIsOpen = false
        if let openCatalog {
            if isSameFolder(sourceLocation.root, openCatalog.rootPath) {
                sourceID = try await openCatalog.image(forRelPath: sourceLocation.relPath(source.lastPathComponent))?.id
            }
            destinationIsOpen = isSameFolder(destination.root, openCatalog.rootPath)
        }

        // The slow part, outside any actor: a copy, or a move to another
        // volume, first makes a whole copy under a hidden name.
        var temporary: URL?
        if mode == .copy || FileOperations.device(ofFolder: folder) != sourceIdentity.device {
            let hidden = FileOperations.temporaryURL(beside: folder.appendingPathComponent(source.lastPathComponent))
            try FileManager.default.copyItem(at: source, to: hidden)
            temporary = hidden
        }
        defer {
            if let temporary, FileOperations.itemExists(temporary) {
                try? FileManager.default.removeItem(at: temporary)
            }
        }
        try faults.beforePlacing?(source)

        let plan = Plan(mode: mode, source: source, sourceLocation: sourceLocation, sourceID: sourceID,
                        folder: folder, destination: destination, destinationIsOpen: destinationIsOpen,
                        temporaryCopy: temporary, name: request.name, preservedName: request.preservedName,
                        midway: faults.midway)
        if let openCatalog, sourceID != nil || destinationIsOpen {
            return try await openCatalog.placeTransfer(plan)
        }
        return try place(plan, rows: nil)
    }

    /// The catalog work `place` needs from the open catalog. Built by the
    /// catalog's actor and used only during one of its steps.
    struct Rows {
        var record: (Int64) throws -> ImageRecord?
        var imageExists: (String) throws -> Bool
        var sidecarFields: (Int64) throws -> XMPSidecar.Fields?
        var updatePath: (_ id: Int64, _ relPath: String, _ preservedName: String?) throws -> Void
        var insertCopy: (_ of: Int64, _ relPath: String, _ preservedName: String?, _ size: Int64, _ mtime: Int64,
                         _ keepThumbnail: Bool) throws -> Int64
        var deleteRow: (Int64) throws -> Void
        var writeSidecar: (Int64) throws -> Void
    }

    /// Names the image and puts it, its sidecar and thumbnail in place, then
    /// brings the open catalog's rows along (`rows`, nil when the open
    /// catalog isn't involved). Synchronous, so on the open catalog's actor
    /// it is one step.
    static func place(_ plan: Plan, rows: Rows?) throws -> CompletedTransfer {
        let fm = FileManager.default
        let isMove = plan.mode == .move
        let source = plan.sourceLocation
        let sameCatalog = isSameFolder(source.root, plan.destination.root)
        // One catalog keeps one container, even an old `_rawhead` one.
        var destination = plan.destination
        if sameCatalog { destination.container = source.container }

        let sourceName = plan.source.lastPathComponent
        let sourceRelPath = source.relPath(sourceName)
        let sourceSidecar = source.sidecarURL(sourceRelPath)
        let sourceThumbnail = source.thumbnailURL(sourceRelPath)
        guard let sourceIdentity = FileOperations.identity(plan.source) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: plan.source.path])
        }
        let sourceSidecarIdentity = FileOperations.identity(sourceSidecar)
        let hasSidecar = sourceSidecarIdentity != nil

        // A name is taken by a file, by a sidecar a file left behind (it would
        // be applied to this image), or by a row whose file has gone (whose
        // ratings and edits reconcile would give this one). A move may take
        // its own name under another spelling.
        func isTaken(_ name: String) throws -> Bool {
            let relPath = destination.relPath(name)
            if let existing = FileOperations.identity(plan.folder.appendingPathComponent(name)),
               !(isMove && existing == sourceIdentity) { return true }
            if let existing = FileOperations.identity(destination.sidecarURL(relPath)),
               !(isMove && existing == sourceSidecarIdentity) { return true }
            if plan.destinationIsOpen, let rows, !(sameCatalog && relPath == sourceRelPath), try rows.imageExists(relPath) {
                return true
            }
            return false
        }
        let name: String
        if let requested = plan.name {
            if let problem = FileOperations.problem(withName: requested) { throw problem }
            guard try !isTaken(requested) else { throw FileOperations.NameProblem.taken(requested) }
            name = requested
        } else {
            guard let free = try FileOperations.uniqueName(for: sourceName, isTaken: isTaken) else {
                throw FileOperations.NameProblem.taken(sourceName)
            }
            name = free
        }
        let destinationURL = plan.folder.appendingPathComponent(name)
        let destinationRelPath = destination.relPath(name)
        let destinationSidecar = destination.sidecarURL(destinationRelPath)
        let destinationThumbnail = destination.thumbnailURL(destinationRelPath)

        // PreservedFileName, read only when it may change.
        var previousPreserved: String?
        var newPreserved: String?
        var preservedChanged = false
        let record = try plan.sourceID.flatMap { id in try rows?.record(id) }
        let mayChange: Bool = switch plan.preservedName {
        case .keep: false
        case .recordOriginal: name != sourceName
        case .exactly: true
        }
        if let record {
            previousPreserved = record.preservedName
        } else if mayChange, hasSidecar {
            previousPreserved = (try? XMPSidecar.read(from: sourceSidecar))?.preservedFileName
        }
        newPreserved = previousPreserved
        if mayChange {
            switch plan.preservedName {
            case .keep: break
            case .recordOriginal: if previousPreserved == nil { newPreserved = sourceName }
            case .exactly(let value): newPreserved = value
            }
            preservedChanged = newPreserved != previousPreserved
        }

        if sameCatalog && isMove {
            try moveWithinCatalog(plan, to: destinationURL, relPath: destinationRelPath,
                                  companions: [(sourceSidecar, destinationSidecar), (sourceThumbnail, destinationThumbnail)],
                                  rows: rows, preservedName: preservedChanged ? .some(newPreserved) : nil,
                                  hadSidecar: hasSidecar, destinationSidecar: destinationSidecar)
        } else if sameCatalog {
            try copyWithinCatalog(plan, to: destinationURL, relPath: destinationRelPath,
                                  sourceSidecar: hasSidecar ? sourceSidecar : nil, destinationSidecar: destinationSidecar,
                                  sourceThumbnail: sourceThumbnail, destinationThumbnail: destinationThumbnail,
                                  rows: rows, preservedName: newPreserved, preservedChanged: preservedChanged)
        } else {
            // Sidecar first: until the file arrives, it waits unused beside
            // where the file will be, and the original is untouched.
            var created: [URL] = []
            do {
                if hasSidecar {
                    try ensureContainer(for: destination)
                    try fm.createDirectory(at: destinationSidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if let rows, let id = plan.sourceID, var fields = try rows.sidecarFields(id) {
                        fields.preservedFileName = newPreserved
                        try writeSidecarExclusively(fields, to: destinationSidecar)
                        created.append(destinationSidecar)
                    } else {
                        try FileOperations.copyExclusively(sourceSidecar, to: destinationSidecar)
                        created.append(destinationSidecar)
                        if preservedChanged { try rewritePreservedName(newPreserved, in: destinationSidecar) }
                    }
                }
                // The thumbnail only saves the other catalog making one; its
                // next thumbnail pass checks it either way.
                if FileOperations.itemExists(sourceThumbnail), FileOperations.isDirectory(destination.container),
                   (try? fm.createDirectory(at: destinationThumbnail.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil,
                   (try? FileOperations.copyExclusively(sourceThumbnail, to: destinationThumbnail)) != nil {
                    created.append(destinationThumbnail)
                }
                try plan.midway?(plan.source)
                try placeFile(plan, at: destinationURL)
            } catch {
                for url in created.reversed() { try? fm.removeItem(at: url) }
                throw error
            }
            if isMove {
                if plan.temporaryCopy != nil {
                    do {
                        try fm.removeItem(at: plan.source)
                    } catch {
                        throw TransferError.originalNotRemoved(copy: destinationURL, reason: describe(error))
                    }
                }
                // What the old catalog knew goes with the file; its content
                // is in the new sidecar now.
                if let rows, let id = plan.sourceID {
                    do { try rows.deleteRow(id) } catch {
                        logger.error("Removing a moved image's row failed; reconcile will: \(String(describing: error), privacy: .private)")
                    }
                }
                if hasSidecar { try? fm.removeItem(at: sourceSidecar) }
                try? fm.removeItem(at: sourceThumbnail)
            }
        }

        return CompletedTransfer(kind: isMove ? .move : .copy, source: plan.source, destination: destinationURL,
                                 destinationIdentity: FileOperations.identity(destinationURL),
                                 preservedNameChanged: preservedChanged,
                                 previousPreservedName: previousPreserved, newPreservedName: newPreserved)
    }

    /// The file itself: the hidden copy renamed into place, or the original
    /// renamed (a change of case allowed).
    private static func placeFile(_ plan: Plan, at destination: URL) throws {
        if let temporary = plan.temporaryCopy {
            try FileOperations.renameExclusively(temporary, to: destination)
        } else {
            try FileOperations.renameAllowingCaseChange(plan.source, to: destination)
        }
    }

    /// A move inside one catalog, a rename included: the file, then its
    /// sidecar and thumbnail, then the row's path, each undone if a later
    /// one fails. `preservedName` is the new value when it changes.
    private static func moveWithinCatalog(_ plan: Plan, to destination: URL, relPath: String,
                                          companions: [(URL, URL)], rows: Rows?, preservedName: String??,
                                          hadSidecar: Bool, destinationSidecar: URL) throws {
        let fm = FileManager.default
        try placeFile(plan, at: destination)
        var moved: [(from: URL, to: URL)] = []
        do {
            try plan.midway?(plan.source)
            for (from, to) in companions where FileOperations.itemExists(from) {
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileOperations.renameAllowingCaseChange(from, to: to)
                moved.append((from, to))
            }
            if let rows, let id = plan.sourceID {
                let current = try rows.record(id)?.preservedName
                try rows.updatePath(id, relPath, preservedName ?? current)
            }
        } catch {
            for step in moved.reversed() { try? FileOperations.renameAllowingCaseChange(step.to, to: step.from) }
            if plan.temporaryCopy != nil {
                try? fm.removeItem(at: destination)
            } else {
                try? FileOperations.renameAllowingCaseChange(destination, to: plan.source)
            }
            throw error
        }
        if plan.temporaryCopy != nil { try? fm.removeItem(at: plan.source) }
        guard let preservedName else { return }
        if let rows, let id = plan.sourceID {
            if hadSidecar || preservedName != nil {
                do { try rows.writeSidecar(id) } catch {
                    logger.error("Writing the renamed image's sidecar failed: \(String(describing: error), privacy: .private)")
                }
            }
        } else if FileOperations.itemExists(destinationSidecar) {
            try? rewritePreservedName(preservedName, in: destinationSidecar)
        }
    }

    /// A copy inside one catalog: the file, then (in the open catalog) a
    /// row with the original's ratings, keywords, edit, history and
    /// snapshots and a sidecar written from it, or (elsewhere) a copy of the
    /// sidecar for reconcile to apply. The copy is removed if that fails.
    private static func copyWithinCatalog(_ plan: Plan, to destination: URL, relPath: String,
                                          sourceSidecar: URL?, destinationSidecar: URL,
                                          sourceThumbnail: URL, destinationThumbnail: URL,
                                          rows: Rows?, preservedName: String?, preservedChanged: Bool) throws {
        let fm = FileManager.default
        try placeFile(plan, at: destination)
        var created: [URL] = [destination]
        var insertedID: Int64?
        do {
            var thumbnailCopied = false
            if FileOperations.itemExists(sourceThumbnail) {
                try? fm.createDirectory(at: destinationThumbnail.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? FileOperations.copyExclusively(sourceThumbnail, to: destinationThumbnail)) != nil {
                    thumbnailCopied = true
                    created.append(destinationThumbnail)
                }
            }
            if let rows, let id = plan.sourceID {
                let values = try destination.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let newID = try rows.insertCopy(id, relPath, preservedName, Int64(values.fileSize ?? 0),
                                                ImageRecord.milliseconds(values.contentModificationDate ?? .distantPast),
                                                thumbnailCopied)
                insertedID = newID
                if sourceSidecar != nil || preservedName != nil {
                    try rows.writeSidecar(newID)
                    created.append(destinationSidecar)
                }
            } else if let sourceSidecar {
                try fm.createDirectory(at: destinationSidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileOperations.copyExclusively(sourceSidecar, to: destinationSidecar)
                created.append(destinationSidecar)
                if preservedChanged { try rewritePreservedName(preservedName, in: destinationSidecar) }
            }
        } catch {
            if let insertedID { try? rows?.deleteRow(insertedID) }
            for url in created.reversed() { try? fm.removeItem(at: url) }
            throw error
        }
    }

    /// Writes a new sidecar under a hidden name, then renames it into place
    /// without overwriting.
    private static func writeSidecarExclusively(_ fields: XMPSidecar.Fields, to destination: URL) throws {
        let temporary = FileOperations.temporaryURL(beside: destination)
        do {
            try XMPSidecar.write(fields, to: temporary)
            try FileOperations.renameExclusively(temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func rewritePreservedName(_ name: String?, in sidecar: URL) throws {
        var fields = try XMPSidecar.read(from: sidecar)
        guard fields.preservedFileName != name else { return }
        fields.preservedFileName = name
        try XMPSidecar.write(fields, to: sidecar)
    }

    /// Makes the destination's `_latent` as `Catalog.open` would, renaming
    /// an old `_rawhead` one, so opening the folder later finds it ready.
    private static func ensureContainer(for location: CatalogLocation) throws {
        let fm = FileManager.default
        let container = location.root.appendingPathComponent(Catalog.containerName, isDirectory: true)
        if FileOperations.isDirectory(container) { return }
        let legacy = location.root.appendingPathComponent(Catalog.legacyContainerName, isDirectory: true)
        if FileOperations.isDirectory(legacy) {
            try fm.moveItem(at: legacy, to: container)
            return
        }
        try fm.createDirectory(at: container.appendingPathComponent("xmp"), withIntermediateDirectories: true)
        var thumbnails = container.appendingPathComponent("thumbnails", isDirectory: true)
        try fm.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        fm.createFile(atPath: container.appendingPathComponent(".metadata_never_index").path, contents: nil)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        try? thumbnails.setResourceValues(excluded)
    }
}

/// Where a catalog keeps what it knows about the files of one folder.
struct CatalogLocation: Sendable, Equatable {
    /// The catalog's folder.
    var root: URL
    /// The folder's path inside the catalog, "" at its root.
    var prefix: String
    var container: URL

    init(root: URL, prefix: String) {
        self.root = root.standardizedFileURL
        self.prefix = prefix
        let current = self.root.appendingPathComponent(Catalog.containerName, isDirectory: true)
        let legacy = self.root.appendingPathComponent(Catalog.legacyContainerName, isDirectory: true)
        container = !FileOperations.isDirectory(current) && FileOperations.isDirectory(legacy) ? legacy : current
    }

    func relPath(_ name: String) -> String { prefix.isEmpty ? name : prefix + "/" + name }

    /// The same layout as `Catalog.sidecarURL(forRelPath:)`.
    func sidecarURL(_ relPath: String) -> URL {
        container.appendingPathComponent("xmp", isDirectory: true).appendingPathComponent(relPath + ".xmp")
    }

    /// The same layout as `Catalog.thumbnailURL(forRelPath:)`.
    func thumbnailURL(_ relPath: String) -> URL {
        container.appendingPathComponent("thumbnails", isDirectory: true).appendingPathComponent(relPath + ".heic")
    }
}

extension Catalog {
    /// Whether reconciling reaches the subfolder `relPath`: by each folder's
    /// recorded mode on the way down, or the catalog's default.
    func includesSubfolder(_ relPath: String) throws -> Bool {
        let defaultMode = try defaultSubfolderMode()
        let modes = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT rel_path, mode FROM subfolders").reduce(into: [String: SubfolderMode]()) { result, row in
                if let mode = SubfolderMode(rawValue: row["mode"]) { result[row["rel_path"]] = mode }
            }
        }
        return FolderAccess.isIncluded(relPath, defaultMode: defaultMode, modes: modes)
    }

    /// One image's placement as one step on this actor.
    func placeTransfer(_ plan: ImageTransfer.Plan) throws -> CompletedTransfer {
        try ImageTransfer.place(plan, rows: transferRows())
    }

    /// Removes the row (and thumbnail) of a copy that has gone to the Trash.
    func forgetTrashedImage(relPath: String) throws {
        try dbQueue.write { db in
            guard let id = try Int64.fetchOne(db, sql: "SELECT id FROM images WHERE rel_path = ?", arguments: [relPath]) else { return }
            try db.execute(sql: "DELETE FROM image_keywords WHERE image_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM images WHERE id = ?", arguments: [id])
        }
    }

    private func transferRows() -> ImageTransfer.Rows {
        ImageTransfer.Rows(
            record: { id in try self.dbQueue.read { db in try ImageRecord.fetchOne(db, key: id) } },
            imageExists: { relPath in try self.image(forRelPath: relPath) != nil },
            sidecarFields: { id in try self.sidecarFields(forImageID: id) },
            updatePath: { id, relPath, preservedName in
                try self.dbQueue.write { db in
                    try db.execute(sql: "UPDATE images SET rel_path = ?, preserved_name = ? WHERE id = ?",
                                   arguments: [relPath, preservedName, id])
                }
            },
            insertCopy: { id, relPath, preservedName, size, mtime, keepThumbnail in
                try self.dbQueue.write { db in
                    guard var row = try ImageRecord.fetchOne(db, key: id) else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    row.id = nil
                    row.relPath = relPath
                    row.preservedName = preservedName
                    row.size = size
                    row.mtime = mtime
                    row.sidecarMtime = nil
                    if !keepThumbnail { row.thumbKey = nil }
                    try row.insert(db)
                    guard let newID = row.id else { throw CocoaError(.fileWriteUnknown) }
                    try db.execute(sql: """
                        INSERT INTO edits (image_id, schema_version, process_version, params_json, updated_at)
                        SELECT ?, schema_version, process_version, params_json, updated_at FROM edits WHERE image_id = ?
                        """, arguments: [newID, id])
                    try db.execute(sql: """
                        INSERT INTO snapshots (image_id, name, params_json)
                        SELECT ?, name, params_json FROM snapshots WHERE image_id = ?
                        """, arguments: [newID, id])
                    try db.execute(sql: """
                        INSERT INTO history (image_id, step, params_json, created_at)
                        SELECT ?, step, params_json, created_at FROM history WHERE image_id = ?
                        """, arguments: [newID, id])
                    try db.execute(sql: """
                        INSERT INTO image_keywords (image_id, keyword_id)
                        SELECT ?, keyword_id FROM image_keywords WHERE image_id = ?
                        """, arguments: [newID, id])
                    return newID
                }
            },
            deleteRow: { id in
                try self.dbQueue.write { db in
                    try db.execute(sql: "DELETE FROM image_keywords WHERE image_id = ?", arguments: [id])
                    try db.execute(sql: "DELETE FROM images WHERE id = ?", arguments: [id])
                }
            },
            writeSidecar: { id in try self.writeSidecar(forImageID: id) })
    }
}
