import Foundation
import RawCore

/// One photo a headless command works on (`latent-cli export`), with what
/// Latent knows about it: its record, for naming, and its stored edit and
/// keywords, for the file.
public struct HeadlessSource: Sendable {
    /// Where the edit came from.
    public enum Origin: String, Sendable {
        /// The folder's catalog database.
        case catalog
        /// The photo's sidecar in `_latent/xmp/`, with no database to ask.
        case sidecar
        /// Neither: the photo has never been edited in Latent.
        case none
    }

    public var record: ImageRecord
    /// The file itself (a virtual copy's master).
    public var fileURL: URL
    /// The folder `record.relPath` is relative to.
    public var root: URL
    public var editStackJSON: String?
    public var keywords: [String]
    public var origin: Origin
}

/// Turns what was typed after `latent-cli export` (a folder, or files) into
/// the photos to export, reading each one's edit the way the app would:
/// from the folder's existing catalog when there is one, else from the
/// sidecars in its `_latent/xmp/`. Nothing here creates a catalog, writes
/// a sidecar or reconciles; a folder's database is opened only when it
/// is already there.
public enum HeadlessSources {
    public struct Resolved: Sendable {
        public var sources: [HeadlessSource]
        /// Things worth saying: paths that aren't photos, companions left out.
        public var notes: [String]
    }

    public enum ResolveError: Error, CustomStringConvertible {
        case missing(String)
        public var description: String {
            switch self {
            case .missing(let path): "\(path) doesn't exist"
            }
        }
    }

    /// The photos `inputs` name. A folder gives its photos (those its
    /// catalog lists, included subfolders with them; without a catalog,
    /// the photos directly in it), in capture order, leaving out the JPEG
    /// half of each RAW+JPEG pair as the library does. A file gives itself.
    public static func resolve(_ inputs: [URL]) async throws -> Resolved {
        var sources: [HeadlessSource] = []
        var notes: [String] = []
        var catalogs: [String: Catalog] = [:]
        var seen = Set<String>()
        let fm = FileManager.default

        func openCatalog(for root: URL) throws -> Catalog? {
            let key = root.standardizedFileURL.path
            if let open = catalogs[key] { return open }
            let database = root.appendingPathComponent(Catalog.containerName).appendingPathComponent("catalog.sqlite")
            guard fm.fileExists(atPath: database.path) else { return nil }
            let opened = try Catalog.open(at: root)
            catalogs[key] = opened
            return opened
        }

        for input in inputs.map(\.standardizedFileURL) {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: input.path, isDirectory: &isDirectory) else {
                throw ResolveError.missing(input.path)
            }
            var found: [HeadlessSource] = []
            if isDirectory.boolValue {
                let (root, prefix) = owner(of: input)
                if let catalog = try openCatalog(for: root) {
                    let records = try await catalog.allImages().filter { record in
                        prefix.isEmpty || record.relPath.hasPrefix(prefix + "/")
                    }
                    let companions = RawJPEGPairs.companions(in: records.map(\.relPath))
                    if !companions.isEmpty {
                        notes.append("\(companions.count) JPEG\(companions.count == 1 ? "" : "s") of RAW+JPEG pairs left out")
                    }
                    for record in records where companions[record.relPath] == nil {
                        found.append(try await source(record, in: catalog))
                    }
                } else {
                    let names = (try? fm.contentsOfDirectory(atPath: input.path)) ?? []
                    let photos = names.filter { name in
                        !name.hasPrefix(".") && Catalog.indexedExtensions.contains((name as NSString).pathExtension.lowercased())
                    }.sorted()
                    let relPaths = photos.map { prefix.isEmpty ? $0 : prefix + "/" + $0 }
                    let companions = RawJPEGPairs.companions(in: relPaths)
                    if !companions.isEmpty {
                        notes.append("\(companions.count) JPEG\(companions.count == 1 ? "" : "s") of RAW+JPEG pairs left out")
                    }
                    for relPath in relPaths where companions[relPath] == nil {
                        found.append(standaloneSource(relPath: relPath, root: root))
                    }
                }
                found.sort { a, b in
                    let ta = a.record.captureTime ?? Int64.max, tb = b.record.captureTime ?? Int64.max
                    return ta != tb ? ta < tb : a.record.relPath < b.record.relPath
                }
            } else {
                guard Catalog.indexedExtensions.contains(input.pathExtension.lowercased()) else {
                    notes.append("\(input.lastPathComponent) isn't a photo Latent reads; left out")
                    continue
                }
                let (root, prefix) = owner(of: input.deletingLastPathComponent())
                let relPath = prefix.isEmpty ? input.lastPathComponent : prefix + "/" + input.lastPathComponent
                if let catalog = try openCatalog(for: root), let record = try await catalog.image(forRelPath: relPath) {
                    found.append(try await source(record, in: catalog))
                } else {
                    found.append(standaloneSource(relPath: relPath, root: root))
                }
            }
            for item in found where seen.insert(item.root.path + "/" + item.record.relPath).inserted {
                sources.append(item)
            }
        }
        return Resolved(sources: sources, notes: notes)
    }

    /// The catalog folder `folder` belongs to and its path inside it ("" for
    /// the folder itself). A folder with no catalog anywhere above it is
    /// its own root.
    static func owner(of folder: URL) -> (root: URL, prefix: String) {
        let folder = folder.standardizedFileURL
        if FolderAccess.hasCatalog(folder) { return (folder, "") }
        if let membership = FolderAccess.owningCatalog(of: folder) {
            return (membership.root.standardizedFileURL, membership.relPath)
        }
        return (folder, "")
    }

    private static func source(_ record: ImageRecord, in catalog: Catalog) async throws -> HeadlessSource {
        let id = record.id ?? -1
        return HeadlessSource(record: record, fileURL: await catalog.fileURL(forRelPath: record.relPath),
                              root: catalog.rootPath,
                              editStackJSON: try await catalog.editStack(forImageID: id),
                              keywords: try await catalog.keywords(forImageID: id), origin: .catalog)
    }

    /// A photo with no catalog row: its metadata read from the file, its
    /// edit, rating, rotation, keywords and descriptive fields from its
    /// sidecar when it has one.
    static func standaloneSource(relPath: String, root: URL) -> HeadlessSource {
        let url = root.appendingPathComponent(relPath)
        var record = standaloneRecord(for: url, relPath: relPath)
        let sidecarURL = root.appendingPathComponent(Catalog.containerName).appendingPathComponent("xmp")
            .appendingPathComponent(relPath + ".xmp")
        var json: String?
        var keywords: [String] = []
        var origin = HeadlessSource.Origin.none
        if FileManager.default.fileExists(atPath: sidecarURL.path), let fields = try? XMPSidecar.read(from: sidecarURL) {
            json = fields.editStackJSON.isEmpty ? nil : fields.editStackJSON
            keywords = fields.keywords
            record.rating = fields.rating
            record.label = fields.label
            record.flag = fields.flag
            record.userRotation = fields.rotation
            record.preservedName = fields.preservedFileName
            record.title = fields.title
            record.caption = fields.caption
            record.creator = fields.creator
            record.copyright = fields.copyright
            origin = .sidecar
        }
        return HeadlessSource(record: record, fileURL: url, root: root, editStackJSON: json, keywords: keywords,
                              origin: origin)
    }

    /// What the catalog would record for the file, read without decoding
    /// it; size and dates alone when the file can't be read.
    public static func standaloneRecord(for url: URL, relPath: String) -> ImageRecord {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let mtime = values?.contentModificationDate.map(ImageRecord.milliseconds) ?? 0
        var record = ImageRecord(
            id: nil, relPath: relPath, preservedName: nil, size: Int64(values?.fileSize ?? 0), mtime: mtime,
            xxhash: Data(count: 8), captureTime: nil, camera: nil, lens: nil, lensId: nil, iso: nil, shutter: nil,
            aperture: nil, focal: nil, width: nil, height: nil, orientation: nil, rating: 0, label: nil, flag: 0,
            sidecarMtime: nil, thumbKey: nil)
        if let s = try? RawFile(path: url.path, metadataOnly: true).summary {
            let camera = [s.cameraMake, s.cameraModel].filter { !$0.isEmpty }.joined(separator: " ")
            record.captureTime = s.captureTime.timeIntervalSince1970 > 0 ? Int64(s.captureTime.timeIntervalSince1970) : nil
            record.camera = camera.isEmpty ? nil : camera
            record.lens = s.lensModel.isEmpty ? nil : s.lensModel
            record.iso = s.iso > 0 ? Int(s.iso) : nil
            record.shutter = s.shutter > 0 ? s.shutter : nil
            record.aperture = s.aperture > 0 ? s.aperture : nil
            record.focal = s.focalLength > 0 ? s.focalLength : nil
            record.width = s.width
            record.height = s.height
            record.orientation = s.orientation
        }
        return record
    }
}
