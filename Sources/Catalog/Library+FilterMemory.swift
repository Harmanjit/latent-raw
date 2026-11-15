import Foundation

/// "Remember Filter per Source" and "Similar to This Photo": two ways the
/// filter bar's filter is set for the user rather than by them.
extension Library {
    // MARK: - Remember Filter per Source

    /// The key of the source showing now: the open folder, or the active
    /// collection in it.
    var currentFilterSourceKey: String? {
        FilterSourceMemory.key(folder: folderURL, collection: collections.activeID)
    }

    /// Notes the filter as the current source's. Nothing while the option
    /// is off.
    func rememberFilterForCurrentSource() {
        guard remembersFilterPerSource, let key = currentFilterSourceKey else { return }
        let before = filterSourceMemory
        filterSourceMemory.remember(filter, for: key)
        if filterSourceMemory != before { filterMemoryDidChange?(true, filterSourceMemory) }
    }

    /// Every change of the filter is remembered at once, so quitting the
    /// app (or a crash) doesn't lose the current source's.
    func filterDidChangeForSourceMemory() {
        rememberFilterForCurrentSource()
    }

    /// Called just before the grid switches to another folder or
    /// collection.
    func filterSourceWillChange() {
        rememberFilterForCurrentSource()
    }

    /// Called just after the switch: the new source's filter comes back,
    /// or everything shows for a source never filtered. Nothing while the
    /// option is off, so the filter carries over as it always has.
    func filterSourceDidChange() {
        guard remembersFilterPerSource, let key = currentFilterSourceKey else { return }
        let next = filterSourceMemory.filter(for: key)
        if filter != next { filter = next }
    }

    /// The saved option and memory, from the app at launch. Nothing is
    /// applied to the filter until the next switch of source.
    public func restoreFilterMemory(enabled: Bool, memory: FilterSourceMemory) {
        let callback = filterMemoryDidChange
        filterMemoryDidChange = nil
        filterSourceMemory = memory
        remembersFilterPerSource = enabled
        filterMemoryDidChange = callback
    }

    // MARK: - Similar to This Photo

    /// Sets the filter to photos like `record`: same camera body, same
    /// lens, captured within a day of it (`SimilarPhotoCriteria`). The rest
    /// of the filter is cleared first, so nothing else hides them; the
    /// active folder or collection stays. Returns false, changing nothing,
    /// when the photo records none of the three.
    @discardableResult
    public func showSimilar(to record: ImageRecord) -> Bool {
        let criteria = SimilarPhotoCriteria(record: record)
        guard criteria.hasAnyPart else { return false }
        applySimilar(criteria, to: LibraryFilter())
        return true
    }

    /// The Similar popover switched a part on or off: only camera, lens and
    /// capture date change in the filter.
    public func updateSimilar(_ criteria: SimilarPhotoCriteria) {
        applySimilar(criteria, to: filter)
    }

    /// Stops "Similar": the parts it set are cleared from the filter.
    public func endSimilar() {
        guard similarPhotoCriteria != nil else { return }
        var next = filter
        next.camera = nil
        next.lens = nil
        next.captureDateRange = nil
        similarPhotoCriteria = nil
        filter = next
    }

    private func applySimilar(_ criteria: SimilarPhotoCriteria, to base: LibraryFilter) {
        isApplyingSimilarCriteria = true
        defer { isApplyingSimilarCriteria = false }
        similarPhotoCriteria = criteria
        filter = criteria.applied(to: base)
    }

    /// Once something else changes camera, lens or the date range (the
    /// user's own pick, Clear Filters, another source's remembered filter)
    /// the criteria no longer describe the filter and are dropped.
    func dropSimilarCriteriaIfStale() {
        guard !isApplyingSimilarCriteria, let criteria = similarPhotoCriteria,
              !criteria.isReflected(in: filter) else { return }
        similarPhotoCriteria = nil
    }
}
