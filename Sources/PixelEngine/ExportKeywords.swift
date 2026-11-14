import Foundation
import ImageIO

extension ExportMetadata {
    /// The keywords as an exported file carries them. The catalog keeps a
    /// hierarchical keyword as its whole path ("Places|France|Paris", see
    /// Catalog's KeywordPath); IPTC keywords are flat, so each level is
    /// written as a keyword of its own, as Lightroom exports the levels
    /// above a keyword. Repeats are kept once, in order.
    static func flattenedKeywords(_ keywords: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for keyword in keywords {
            for level in keyword.split(separator: "|").map({ $0.trimmingCharacters(in: .whitespaces) })
            where !level.isEmpty && seen.insert(level).inserted {
                result.append(level)
            }
        }
        return result
    }
}

// MARK: - Keyword hierarchy and the embedded edit

extension ExportMetadata {
    /// Lightroom's namespace, where lr:hierarchicalSubject lives.
    static let lightroomNamespace = "http://ns.adobe.com/lightroom/1.0/"
    /// Latent's own XMP namespace: the one its sidecars use
    /// (`XMPSidecar.namespaceURI` in Catalog, which a test keeps equal).
    public static let latentNamespace = "https://github.com/Harmanjit/latent-raw/ns/1.0/"

    /// The catalog's keywords, whole ("Places|France|Paris"), as
    /// lr:hierarchicalSubject beside dc:subject, as Lightroom writes them.
    /// dc:subject keeps the flattened levels, as before.
    static func addKeywordHierarchy(_ keywords: [String], to xmp: CGMutableImageMetadata) {
        var seen = Set<String>()
        let paths = keywords.map { $0.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "|") }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !paths.isEmpty else { return }
        CGImageMetadataRegisterNamespaceForPrefix(xmp, lightroomNamespace as CFString, "lr" as CFString, nil)
        guard let tag = CGImageMetadataTagCreate(lightroomNamespace as CFString, "lr" as CFString,
                                                 "hierarchicalSubject" as CFString, .arrayUnordered,
                                                 paths as CFArray) else { return }
        CGImageMetadataSetTagWithPath(xmp, nil, "lr:hierarchicalSubject" as CFString, tag)
    }

    /// `xmp` (or new XMP) with the edit as latent:EditStack, the element a
    /// Latent sidecar keeps it in, so the edit can be read back from the
    /// exported file (`embeddedEdit(in:)`).
    static func addingEmbeddedEdit(_ json: String, to xmp: CGImageMetadata?) -> CGImageMetadata? {
        guard !json.isEmpty else { return xmp }
        let mutable = xmp.flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(mutable, latentNamespace as CFString, "latent" as CFString, nil)
        guard let tag = CGImageMetadataTagCreate(latentNamespace as CFString, "latent" as CFString,
                                                 "EditStack" as CFString, .string, json as CFString) else { return xmp }
        CGImageMetadataSetTagWithPath(mutable, nil, "latent:EditStack" as CFString, tag)
        return mutable
    }

    /// The Latent edit an exported image carries (Embed Latent edit), as
    /// EditStack JSON; nil when it has none or can't be read.
    public static func embeddedEdit(in url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let xmp = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return nil }
        var found: String?
        CGImageMetadataEnumerateTagsUsingBlock(xmp, nil, nil) { _, tag in
            if (CGImageMetadataTagCopyNamespace(tag) as String?) == latentNamespace,
               (CGImageMetadataTagCopyName(tag) as String?) == "EditStack",
               let value = CGImageMetadataTagCopyValue(tag) as? String {
                found = value
                return false
            }
            return true
        }
        return found.flatMap { $0.isEmpty ? nil : $0 }
    }
}
