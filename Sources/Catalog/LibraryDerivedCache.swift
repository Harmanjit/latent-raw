import Foundation

/// Lists the Library works out from its image list and keywords and then
/// reads many times over, each kept with the versions it was worked out
/// from (`Library.imagesVersion`, `Library.keywordsVersion`). A read with
/// the same versions gets the kept list; any change to the images or the
/// keywords bumps a version, so the next read works it out again. Nothing
/// is ever shown stale, and nothing is worked out until it is read.
///
/// On a 10,000-photo folder these were the main-thread cost of every
/// keystroke in the search field (the RAW+JPEG pairs, every photo's search
/// text) and in the keywording field and smart collection sheet (the
/// folder's keywords, each field's existing values).
struct LibraryDerivedCache {
    /// One kept list and the versions it belongs to.
    struct Entry<Value> {
        var versions: [Int]
        var value: Value
    }

    var pairs: Entry<[Int64: [ImageRecord]]>?
    var availableKeywords: Entry<[String]>?
    var searchHaystacks: Entry<[Int64: String]>?
    /// The photos the grid starts from (`imagesShownInGrid`), sorted.
    var sortedShown: Entry<[ImageRecord]>?
    var existingValues: [SmartCriterion.Field: Entry<[String]>] = [:]

    /// The list at `key`, worked out by `compute` unless it was kept for
    /// exactly these `versions`.
    mutating func value<Value>(_ key: WritableKeyPath<LibraryDerivedCache, Entry<Value>?>, version versions: Int...,
                               compute: () -> Value) -> Value {
        if let entry = self[keyPath: key], entry.versions == versions { return entry.value }
        let value = compute()
        self[keyPath: key] = Entry(versions: versions, value: value)
        return value
    }

    /// A field's existing values (`SmartCriterion.existingValues`), kept
    /// per field.
    mutating func existingValues(for field: SmartCriterion.Field, version versions: Int...,
                                 compute: () -> [String]) -> [String] {
        if let entry = existingValues[field], entry.versions == versions { return entry.value }
        let value = compute()
        existingValues[field] = Entry(versions: versions, value: value)
        return value
    }
}
