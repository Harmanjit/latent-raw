import Foundation

/// Stacks for the open Library: Group into Stack, Unstack, Remove from
/// Stack, Move to Top of Stack, Auto-Stack by Capture Time, expanding and
/// collapsing, and exported files added to the catalog beside their
/// originals. Changes to what is stacked can be undone; expanding and
/// collapsing are a way of looking, as in Lightroom, and are not.
extension Library {
    /// The stack `id` is in, if any.
    public func stack(containing id: Int64) -> ImageStack? {
        guard let stackID = stackMemberships[id]?.stackID else { return nil }
        return stacks.first { $0.id == stackID }
    }

    /// Whether any of `records` is in a stack.
    public func anyStacked(_ records: [ImageRecord]) -> Bool {
        records.contains { $0.id.map { stackMemberships[$0] != nil } ?? false }
    }

    // MARK: Asking

    /// Group into Stack (⌘G): `records` (with the stacks they are in) become
    /// one collapsed stack with the lead on top, which stays selected.
    public func groupIntoStack(_ records: [ImageRecord]) async throws {
        let ids = records.compactMap(\.id)
        guard ids.count >= 2 || anyStacked(records) else { return }
        let top = selectedImageID.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
        let next = StackEditing.group(ids, top: top, in: stacks)
        try await commit(next, undo: "Group into Stack")
        if let top { setSelection([top], primary: top) }
    }

    /// Unstack (⇧⌘G): the stacks holding any of `records` come apart, and
    /// their photos all show again.
    public func unstack(_ records: [ImageRecord]) async throws {
        try await commit(StackEditing.unstack(Set(records.compactMap(\.id)), in: stacks), undo: "Unstack")
    }

    /// Remove from Stack: `records` leave their stacks.
    public func removeFromStack(_ records: [ImageRecord]) async throws {
        try await commit(StackEditing.remove(Set(records.compactMap(\.id)), from: stacks), undo: "Remove from Stack")
    }

    /// Move to Top of Stack (⇧S): `record` becomes the photo its collapsed
    /// stack shows.
    public func moveToTopOfStack(_ record: ImageRecord) async throws {
        guard let id = record.id else { return }
        try await commit(StackEditing.moveToTop(id, in: stacks), undo: "Move to Top of Stack")
    }

    /// Expand or collapse the stacks of `records` (S); nil turns each the
    /// other way. Collapsing selects the photos the stacks now show.
    public func setStacksCollapsed(_ collapsed: Bool?, of records: [ImageRecord]) async throws {
        let stackIDs = Set(records.compactMap { $0.id.flatMap { stackMemberships[$0]?.stackID } })
        guard !stackIDs.isEmpty else { return }
        let next = StackEditing.setCollapsed(collapsed, stackIDs: stackIDs, in: stacks)
        try await commit(next, undo: nil)
        selectShownMembers(of: stackIDs)
    }

    /// Expand All Stacks or Collapse All Stacks.
    public func setAllStacksCollapsed(_ collapsed: Bool) async throws {
        try await commit(StackEditing.setCollapsed(collapsed, stackIDs: nil, in: stacks), undo: nil)
    }

    /// Auto-Stack by Capture Time over every photo the grid could show
    /// (filters aside): photos taken within `gap` seconds of the one before
    /// stack together. Returns the number of stacks made.
    @discardableResult
    public func autoStackByCaptureTime(gap: TimeInterval) async throws -> Int {
        let result = StackEditing.autoStack(imagesShownInGrid(), gap: gap, in: stacks)
        guard result.added > 0 else { return 0 }
        try await commit(result.stacks, undo: "Auto-Stack by Capture Time")
        return result.added
    }

    // MARK: Exported files

    /// A file an export wrote, for Add to This Catalog.
    public struct ExportedFile: Sendable, Equatable {
        public enum Placement: Sendable, Equatable { case unstacked, above, below }
        public var url: URL
        /// The photo it was exported from.
        public var sourceID: Int64
        public var placement: Placement

        public init(url: URL, sourceID: Int64, placement: Placement) {
            self.url = url
            self.sourceID = sourceID
            self.placement = placement
        }
    }

    /// What Add to This Catalog managed.
    public struct ExportedFilesReport: Sendable, Equatable {
        public var added = 0
        /// Written outside the open folder, or in a subfolder it doesn't
        /// include: not indexed.
        public var outside = 0
    }

    /// Indexes `files` an export just wrote into the open folder, stacks
    /// each with its original where asked, and selects them. Files outside
    /// the folder are counted and left alone.
    @discardableResult
    public func addExportedFiles(_ files: [ExportedFile]) async throws -> ExportedFilesReport {
        var report = ExportedFilesReport()
        guard let root = folderURL, let catalog else { return report }
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var inside: [(file: ExportedFile, relPath: String)] = []
        for file in files {
            let path = file.url.standardizedFileURL.resolvingSymlinksInPath().path
            if path.hasPrefix(prefix) {
                inside.append((file, String(path.dropFirst(prefix.count))))
            } else {
                report.outside += 1
            }
        }
        guard !inside.isEmpty else { return report }
        try await refresh()
        guard catalog === self.catalog else { return report }
        let idsByPath = Dictionary(images.compactMap { record in record.id.map { (record.relPath, $0) } },
                                   uniquingKeysWith: { first, _ in first })
        var next = stacks
        var added: [Int64] = []
        for (file, relPath) in inside {
            guard let id = idsByPath[relPath] else {
                report.outside += 1
                continue
            }
            added.append(id)
            switch file.placement {
            case .unstacked: break
            case .above: next = StackEditing.add(id, besides: file.sourceID, above: true, in: next)
            case .below: next = StackEditing.add(id, besides: file.sourceID, above: false, in: next)
            }
        }
        report.added = added.count
        try await commit(next, undo: "Add to Stack")
        let shown = Set(visibleImages.compactMap(\.id))
        let selectable = Set(added).intersection(shown)
        if !selectable.isEmpty { setSelection(selectable, primary: added.first { selectable.contains($0) }) }
        return report
    }

    // MARK: Writing

    /// Writes `next` as the catalog's stacks and shows it, filing `undo`
    /// (when named) to put back the stacks as they were.
    private func commit(_ next: [ImageStack], undo name: String?) async throws {
        guard let catalog, next != stacks else { return }
        let before = stacks
        try await catalog.replaceStacks(next)
        guard catalog === self.catalog else { return }
        stacks = try await catalog.allStacks()
        if let name {
            undoRegistration(name, in: catalog) { library, catalog in
                library.replayStacks(before, named: name, in: catalog)
            }(true)
        }
    }

    /// Runs as an undo or redo: files the opposite at once (which reads the
    /// stacks this replaced when it runs), then puts back `state`. Waits for
    /// undos and redos asked for before it, as the Library's others do.
    func replayStacks(_ state: [ImageStack], named name: String, in catalog: Catalog) {
        let verb = undoManager?.isRedoing == true ? "Redo" : "Undo"
        let opposite = StackLedger()
        let done = undoRegistration(name, in: catalog) { library, catalog in
            library.replayStacks(opposite.stacks, named: name, in: catalog)
        }
        let previous = undoRestores
        let replaying = Task { @MainActor [weak self] in
            _ = await previous?.result
            guard let self, catalog === self.catalog else { return }
            opposite.stacks = try await catalog.allStacks()
            try await catalog.replaceStacks(state)
            guard catalog === self.catalog else { return }
            self.stacks = try await catalog.allStacks()
        }
        undoRestores = replaying
        perform("\(verb) \(name)") {
            try await replaying.value
            done(true)
        }
    }

    /// After collapsing or expanding: the selection becomes what each of
    /// `stackIDs` now shows of the photos that were selected, or its top.
    private func selectShownMembers(of stackIDs: Set<Int64>) {
        let shown = Set(visibleImages.compactMap(\.id))
        var selection = selectedImageIDs.intersection(shown)
        for stack in stacks where stackIDs.contains(stack.id) {
            if let visible = stack.memberIDs.first(where: shown.contains), !stack.memberIDs.contains(where: selection.contains) {
                selection.insert(visible)
            }
        }
        let lead = selectedImageID.flatMap { shown.contains($0) ? $0 : nil }
            ?? selectedImageID.flatMap { stack(containing: $0)?.memberIDs.first(where: shown.contains) }
        setSelection(selection, primary: lead)
    }
}

/// The stacks an undo or redo replaced, filled in as it runs and read by
/// the action that reverses it.
@MainActor
final class StackLedger {
    var stacks: [ImageStack] = []
}
