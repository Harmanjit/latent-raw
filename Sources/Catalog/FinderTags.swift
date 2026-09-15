import Foundation

/// One Finder tag on a file: its name and the colour Finder shows it in.
///
/// Read-only. Latent never writes tags: they belong to Finder, and writing
/// an extended attribute would change the original's metadata, which
/// Latent promises not to touch. They are read during reconcile (off the
/// main thread, with the listing it already makes) and cached on the
/// image's row, so the grid and the filter never touch the disk for them.
/// A tag changed in Finder shows after the next Refresh, as any other
/// change on disk does (DESIGN.md §5.3, no live watching).
///
/// `URLResourceValues.tagNames` gives the names only. The colour sits
/// beside each name in the same extended attribute ("Red\n6"), so the
/// attribute is read directly: a tag recoloured in Finder shows in its own
/// colour.
public struct FinderTag: Hashable, Sendable {
    public var name: String
    /// Finder's label number: 0 none, 1 grey, 2 green, 3 purple, 4 blue,
    /// 5 yellow, 6 red, 7 orange.
    public var colorIndex: Int

    public init(name: String, colorIndex: Int) {
        self.name = name
        self.colorIndex = (0...7).contains(colorIndex) ? colorIndex : 0
    }

    static let attributeName = "com.apple.metadata:_kMDItemUserTags"
    /// Anything larger isn't a tag list; don't read it into memory.
    static let maximumAttributeSize = 64 * 1024

    /// Tags on the file at `url`; empty when it has none or they can't be
    /// read. One `getxattr` for the size and one for the bytes, and only
    /// the first for the usual untagged file.
    public static func read(from url: URL) -> [FinderTag] {
        url.withUnsafeFileSystemRepresentation { path -> [FinderTag] in
            guard let path else { return [] }
            let size = getxattr(path, attributeName, nil, 0, 0, XATTR_NOFOLLOW)
            guard size > 0, size <= maximumAttributeSize else { return [] }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, attributeName, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
            guard read == size else { return [] }
            return parse(attribute: data)
        }
    }

    /// The attribute's bytes: a property list array of "Name\nN" strings.
    static func parse(attribute data: Data) -> [FinderTag] {
        guard let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else {
            return []
        }
        return parse(values)
    }

    /// "Name\nN" entries. A name stored without a colour (the file system's
    /// own setter stores "Red\n0" or just "Red") takes the colour Finder
    /// gives its standard tag of that name, or none. Duplicates keep the first.
    public static func parse(_ values: [String]) -> [FinderTag] {
        var seen = Set<String>()
        return values.compactMap { value in
            let parts = value.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first.map(String.init), !name.isEmpty, seen.insert(name).inserted else { return nil }
            var index = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            if !(1...7).contains(index) { index = standardColors[name.lowercased()] ?? 0 }
            return FinderTag(name: name, colorIndex: index)
        }
    }

    private static let standardColors: [String: Int] = [
        "gray": 1, "grey": 1, "green": 2, "purple": 3, "blue": 4, "yellow": 5, "red": 6, "orange": 7,
    ]

    // MARK: - Stored form

    /// How tags sit in `images.finder_tags`: one line per tag, the colour
    /// digit then the name ("6Red\n0Work"), nil for none. A tag name can't
    /// hold a line break (Finder's own format separates on it), and a plain
    /// string decodes far faster than JSON for every row of a large folder.
    public static func encode(_ tags: [FinderTag]) -> String? {
        guard !tags.isEmpty else { return nil }
        return tags.map { "\($0.colorIndex)\($0.name)" }.joined(separator: "\n")
    }

    public static func decode(_ stored: String?) -> [FinderTag] {
        guard let stored, !stored.isEmpty else { return [] }
        return stored.split(separator: "\n").compactMap { line in
            guard let first = line.first, let digit = first.wholeNumberValue else { return nil }
            let name = String(line.dropFirst())
            return name.isEmpty ? nil : FinderTag(name: name, colorIndex: digit)
        }
    }

    /// Whether a stored list holds a tag called `name`, without building
    /// the tags: the filter asks this of every image in the folder.
    public static func stored(_ stored: String?, contains name: String) -> Bool {
        guard let stored, !stored.isEmpty else { return false }
        return stored.split(separator: "\n").contains { $0.dropFirst() == name[...] }
    }
}

public extension ImageRecord {
    /// The file's Finder tags as last read by reconcile.
    var tags: [FinderTag] { FinderTag.decode(finderTags) }
}
