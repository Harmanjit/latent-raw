import Foundation
import GRDB

/// Ratings, labels, keywords and the descriptive fields another
/// application left in a sidecar beside the photo: darktable's
/// `DSC_0107.NEF.xmp`, or Lightroom's and Capture One's `DSC_0107.xmp`.
///
/// Read only. Latent never writes to these files (its own sidecars live in
/// `_latent/xmp`); it copies what they say into the catalog, and from there
/// into its own sidecar, once: when a photo is first catalogued with no
/// sidecar of Latent's, or when Folder › Import Ratings and Keywords from
/// Other Apps' Sidecars… is chosen, which fills only what Latent has empty.
public enum ForeignSidecar {
    /// Settings › Folders › "Read ratings and keywords from other apps'
    /// sidecars". On unless switched off.
    public static let preferenceKey = "latent.readForeignSidecars"

    /// Tests set this instead of the user default. Nil in the app.
    nonisolated(unsafe) static var enabledOverrideForTesting: Bool?

    /// Whether reconcile reads them for newly catalogued photos.
    public static var isEnabled: Bool {
        enabledOverrideForTesting ?? (UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true)
    }

    /// Where another application's sidecar for `file` may be, in the order
    /// tried: darktable's name (the whole file name plus .xmp), then
    /// Lightroom's (the extension replaced).
    public static func candidates(for file: URL) -> [URL] {
        let darktable = file.appendingPathExtension("xmp")
        let lightroom = file.deletingPathExtension().appendingPathExtension("xmp")
        return darktable == lightroom ? [darktable] : [darktable, lightroom]
    }

    /// What the first readable sidecar beside `file` says, or nil when
    /// there is none (or none that parses).
    public static func read(besides file: URL) -> ForeignMetadata? {
        for url in candidates(for: file) where FileOperations.itemExists(url) {
            if let metadata = try? read(from: url) { return metadata }
        }
        return nil
    }

    /// Parses one sidecar with Latent's own XMP reader, plus darktable's
    /// colour labels, which aren't xmp:Label.
    public static func read(from url: URL) throws -> ForeignMetadata {
        let document = try XMPSidecar.loadDocument(from: url)
        let fields = try XMPSidecar.parse(document)
        var label = ColorLabel(xmpLabel: fields.label)?.xmpValue ?? DescriptiveField.normalized(fields.label)
        if label == nil {
            let items = (try? document.nodes(forXPath:
                "//*[local-name()='Description']/*[local-name()='colorlabels']//*[local-name()='li']")) ?? []
            label = items.lazy.compactMap { Int($0.stringValue?.trimmingCharacters(in: .whitespaces) ?? "") }
                .compactMap(darktableLabel).first?.xmpValue
        }
        var descriptive: [DescriptiveField: String] = fields.more
        for (field, value) in [(DescriptiveField.title, fields.title), (.caption, fields.caption),
                               (.creator, fields.creator), (.copyright, fields.copyright)] {
            if let value { descriptive[field] = value }
        }
        // xmp:Rating -1 is how darktable and Lightroom mark a reject.
        return ForeignMetadata(rating: min(max(fields.rating, 0), 5), rejected: fields.rating < 0,
                               label: label, keywords: fields.keywords.compactMap(KeywordPath.normalized),
                               descriptive: descriptive)
    }

    /// darktable's colour label numbers.
    static func darktableLabel(_ number: Int) -> ColorLabel? {
        switch number {
        case 0: .red
        case 1: .yellow
        case 2: .green
        case 3: .blue
        case 4: .purple
        default: nil
        }
    }
}

/// What another application's sidecar says about a photo.
public struct ForeignMetadata: Equatable, Sendable {
    public var rating: Int
    public var rejected: Bool
    public var label: String?
    public var keywords: [String]
    public var descriptive: [DescriptiveField: String]

    /// Fills what `snapshot` has empty: no stars, no flag, no label, no
    /// keywords, each empty descriptive field. Nothing Latent already has
    /// is replaced.
    public func fill(_ snapshot: inout MetadataSnapshot) {
        if snapshot.rating == 0 { snapshot.rating = rating }
        if snapshot.flag == 0, rejected { snapshot.flag = ImageFlag.rejected.rawValue }
        if snapshot.label == nil { snapshot.label = label }
        if snapshot.keywords.isEmpty { snapshot.keywords = keywords.sorted() }
        for (field, value) in descriptive where snapshot.descriptive[field] == nil {
            snapshot.descriptive[field] = value
        }
    }
}

/// A photo's rating, flag, label, keywords and descriptive fields together:
/// what metadata presets, imported sidecars and Add to This Catalog change,
/// and what their one undo step puts back.
public struct MetadataSnapshot: Equatable, Sendable {
    public var rating: Int
    public var flag: Int
    public var label: String?
    /// Sorted, so two snapshots with the same keywords compare equal.
    public var keywords: [String]
    public var descriptive: [DescriptiveField: String]

    public init(rating: Int = 0, flag: Int = 0, label: String? = nil, keywords: [String] = [],
                descriptive: [DescriptiveField: String] = [:]) {
        self.rating = rating; self.flag = flag; self.label = label
        self.keywords = keywords.sorted(); self.descriptive = descriptive
    }

    public init(row: ImageRecord, keywords: [String]) {
        self.init(rating: row.rating, flag: row.flag, label: row.label, keywords: keywords,
                  descriptive: row.descriptive)
    }

    /// Puts everything but the keywords on `row`.
    func apply(to row: inout ImageRecord) {
        row.rating = min(max(rating, 0), 5)
        row.flag = flag
        row.label = DescriptiveField.normalized(label)
        for field in DescriptiveField.allCases { field.set(descriptive[field], on: &row) }
    }
}

extension Catalog {
    /// The image's metadata as one value, or nil if there is no such image.
    public func metadataSnapshot(forImageID id: Int64) throws -> MetadataSnapshot? {
        try dbQueue.read { db in
            guard let row = try ImageRecord.fetchOne(db, key: id) else { return nil }
            return MetadataSnapshot(row: row, keywords: try Self.keywordNames(forImageID: id, in: db))
        }
    }

    /// Sets rating, flag, label, keywords and descriptive fields at once and
    /// writes the sidecar, returning what the image had (nil if there is no
    /// such image). A snapshot equal to what is there writes nothing.
    @discardableResult
    public func exchangeMetadata(_ snapshot: MetadataSnapshot, forImageID id: Int64) throws -> MetadataSnapshot? {
        let outcome: (before: MetadataSnapshot, changed: Bool)? = try dbQueue.write { db in
            guard var row = try ImageRecord.fetchOne(db, key: id) else { return nil }
            let keywords = try Self.keywordNames(forImageID: id, in: db)
            let before = MetadataSnapshot(row: row, keywords: keywords)
            guard before != snapshot else { return (before, false) }
            snapshot.apply(to: &row)
            try row.update(db)
            if Set(keywords) != Set(snapshot.keywords) {
                try Self.replaceKeywords(snapshot.keywords, forImageID: id, in: db)
            }
            return (before, true)
        }
        guard let outcome else { return nil }
        if outcome.changed { try writeSidecar(forImageID: id) }
        return outcome.before
    }

    /// Fills what the image has empty from another application's sidecar
    /// beside its file. Returns what it had when something changed, nil
    /// when nothing did (no such sidecar, nothing empty to fill, a virtual
    /// copy, which has no file of its own).
    @discardableResult
    public func fillFromForeignSidecar(forImageID id: Int64) throws -> MetadataSnapshot? {
        guard let row = try dbQueue.read({ db in try ImageRecord.fetchOne(db, key: id) }),
              !row.isVirtualCopy,
              let foreign = ForeignSidecar.read(besides: fileURL(forRelPath: row.relPath)),
              let before = try metadataSnapshot(forImageID: id) else { return nil }
        var next = before
        foreign.fill(&next)
        guard next != before else { return nil }
        return try exchangeMetadata(next, forImageID: id)
    }

    /// Reconcile's part: photos catalogued this pass that came with no
    /// sidecar of Latent's take what another application's says. Returns
    /// how many did.
    func importForeignSidecars(forNewImageIDs ids: [Int64], report: inout ReconcileReport) -> Int {
        guard ForeignSidecar.isEnabled, !ids.isEmpty else { return 0 }
        var count = 0
        for id in ids {
            do {
                guard let row = try dbQueue.read({ db in try ImageRecord.fetchOne(db, key: id) }),
                      row.sidecarMtime == nil,
                      !FileOperations.itemExists(sidecarURL(forRelPath: row.relPath)) else { continue }
                if try fillFromForeignSidecar(forImageID: id) != nil { count += 1 }
            } catch {
                report.failures.append((String(id), "other app's sidecar not read: \(error)"))
            }
        }
        return count
    }

    static func keywordNames(forImageID id: Int64, in db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT k.name FROM keywords k
            JOIN image_keywords ik ON ik.keyword_id = k.id
            WHERE ik.image_id = ? ORDER BY k.name
            """, arguments: [id])
    }
}
