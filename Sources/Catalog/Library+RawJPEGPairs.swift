import Foundation

extension Library {
    /// `images` as the grid starts from: every image, less the JPEGs of
    /// RAW+JPEG pairs unless they are to be shown separately
    /// (`showsPairedCompanions`). Refreshes `pairedCompanions` on the way,
    /// so the info panel and file operations see the pairing the grid does.
    func imagesShownInGrid() -> [ImageRecord] {
        let pairs = RawJPEGPairs.companionsByRaw(in: images)
        if pairs != pairedCompanions { pairedCompanions = pairs }
        guard !showsPairedCompanions, !pairs.isEmpty else { return images }
        let hidden = Set(pairs.values.joined().compactMap(\.id))
        return images.filter { record in record.id.map { !hidden.contains($0) } ?? true }
    }

    /// The JPEGs that travel with `record` when it is moved, copied or
    /// renamed: its companions while they are hidden, none while they are
    /// shown as photos of their own (then each goes only where it is sent).
    public func companionsTravelling(with record: ImageRecord) -> [ImageRecord] {
        guard !showsPairedCompanions, let id = record.id else { return [] }
        return pairedCompanions[id] ?? []
    }

    /// The companion files of `records` that must follow them, keyed by the
    /// raw's file URL (standardised), for `LibraryFileOperations`.
    func companionURLsTravelling(with records: [ImageRecord]) -> [URL: [URL]] {
        var result: [URL: [URL]] = [:]
        for record in records {
            let companions = companionsTravelling(with: record).compactMap { fileURL(for: $0) }
            guard !companions.isEmpty, let url = fileURL(for: record) else { continue }
            result[url.standardizedFileURL] = companions
        }
        return result
    }
}
