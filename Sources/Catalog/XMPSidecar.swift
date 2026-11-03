import Foundation

/// Reads and writes edit-stack XMP sidecars (DESIGN.md §5.5).
///
/// Writes are atomic: to a temporary file, then renamed over the old
/// sidecar, so a crash mid-write can never leave a half-written file
/// (DESIGN.md §5.3). Reads use Foundation's XMLDocument, which is all
/// Latent's own sidecars need (Exiv2 was not adopted, DESIGN.md §3).
public enum XMPSidecar {
    /// The namespace URI is fixed now that the repository is public
    /// (DESIGN.md §5.5); changing it would orphan existing sidecars.
    static let namespaceURI = "https://github.com/Harmanjit/latent-raw/ns/1.0/"

    public struct Fields: Equatable {
        public var rating: Int
        public var label: String?
        /// -1 rejected, 0 none, 1 picked (latent:Flag).
        public var flag: Int
        /// Manual quarter turns clockwise (latent:Rotation).
        public var rotation: Int
        public var keywords: [String]
        public var preservedFileName: String?
        /// Prefixed, e.g. "xxh64:ef46db3751d8e999".
        public var sourceHash: String
        public var schemaVersion: Int
        public var processVersion: String
        /// Pre-serialized JSON, see DESIGN.md §5.6. Empty when the image
        /// has no edits yet.
        public var editStackJSON: String
        /// JSON array of named snapshots, or empty (latent:Snapshots).
        public var snapshotsJSON: String = ""
        /// JSON of the edit history, or empty (latent:History).
        public var historyJSON: String = ""
        /// The recipe of a Photo Merge result (latent:Merge), or empty for
        /// any other photo. Provenance only: which photos went in, how they
        /// were merged and the values the renderer needs to read the result
        /// back (docs/PhotoMerge.md). The catalog keeps it as written and
        /// never interprets it.
        public var mergeJSON: String = ""

        public init(rating: Int = 0, label: String? = nil, flag: Int = 0, rotation: Int = 0,
                    keywords: [String] = [],
                    preservedFileName: String? = nil, sourceHash: String,
                    schemaVersion: Int = 1, processVersion: String = "1.0",
                    editStackJSON: String = "", snapshotsJSON: String = "", historyJSON: String = "",
                    mergeJSON: String = "") {
            self.snapshotsJSON = snapshotsJSON
            self.historyJSON = historyJSON
            self.mergeJSON = mergeJSON
            self.rating = rating
            self.label = label
            self.flag = flag
            self.rotation = rotation
            self.keywords = keywords
            self.preservedFileName = preservedFileName
            self.sourceHash = sourceHash
            self.schemaVersion = schemaVersion
            self.processVersion = processVersion
            self.editStackJSON = editStackJSON
        }
    }

    public enum ReadError: Error {
        case noDescription
    }

    // MARK: - Write

    /// Writes `fields` to `destination` via a temp file + atomic rename.
    /// Creates intermediate directories (sidecars for included subfolders
    /// live under mirrored subpaths, DESIGN.md §5.1).
    public static func write(_ fields: Fields, to destination: URL) throws {
        let xml = render(fields)
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tmp = FileOperations.companionTemporaryURL(for: destination)

        try xml.write(to: tmp, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmp)
    }

    private static func render(_ f: Fields) -> String {
        // A hierarchical keyword goes in dc:subject as each of its levels and
        // whole in lr:hierarchicalSubject (see KeywordPath). Only then: a
        // sidecar with flat keywords stays exactly as it always was.
        let hierarchical = f.keywords.contains(where: KeywordPath.isHierarchical)
        let subjects = hierarchical ? KeywordPath.flatSubjects(f.keywords) : f.keywords
        let keywordItems = subjects.map { "      <rdf:li>\(escape($0))</rdf:li>" }.joined(separator: "\n")
        let hierarchyItems = f.keywords.map { "      <rdf:li>\(escape($0))</rdf:li>" }.joined(separator: "\n")
        let hierarchyBlock = hierarchical ? "   <lr:hierarchicalSubject><rdf:Bag>\n\(hierarchyItems)\n   </rdf:Bag></lr:hierarchicalSubject>\n" : ""
        let lightroomNamespace = hierarchical ? "\n    xmlns:lr=\"http://ns.adobe.com/lightroom/1.0/\"" : ""
        let labelAttr = f.label.map { " xmp:Label=\"\(escape($0))\"" } ?? ""
        let preservedAttr = f.preservedFileName.map {
            " xmpMM:PreservedFileName=\"\(escape($0))\""
        } ?? ""

        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:xmpMM="http://ns.adobe.com/xap/1.0/mm/"
            xmlns:latent="\(namespaceURI)"\(lightroomNamespace)
            xmp:Rating="\(f.rating)"\(labelAttr)\(preservedAttr)
            latent:SchemaVersion="\(f.schemaVersion)"
            latent:ProcessVersion="\(escape(f.processVersion))"
            latent:SourceHash="\(escape(f.sourceHash))"
            latent:Flag="\(f.flag)"
            latent:Rotation="\(f.rotation)">
           <dc:subject><rdf:Bag>
        \(keywordItems)
           </rdf:Bag></dc:subject>
        \(hierarchyBlock)   <latent:EditStack>\(cdata(f.editStackJSON))</latent:EditStack>
        \(f.snapshotsJSON.isEmpty ? "" : "   <latent:Snapshots>\(cdata(f.snapshotsJSON))</latent:Snapshots>")
        \(f.historyJSON.isEmpty ? "" : "   <latent:History>\(cdata(f.historyJSON))</latent:History>")
        \(f.mergeJSON.isEmpty ? "" : "   <latent:Merge>\(cdata(f.mergeJSON))</latent:Merge>")
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    /// Wraps text in a CDATA section, which keeps JSON readable in the file
    /// with no escaping. The one thing CDATA can't hold is its own end
    /// marker `]]>`, and JSON may contain it inside a string (a snapshot
    /// named "a]]>b", a source file with it in its name); left alone it
    /// would end the section early and make the whole sidecar unreadable.
    /// So the section is closed between `]]` and `>` and a new one opened:
    /// `]]]]><![CDATA[>`. A reader joins adjacent sections back together,
    /// so the text comes back byte for byte.
    static func cdata(_ text: String) -> String {
        "<![CDATA[" + text.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>") + "]]>"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - Read

    /// Parses a sidecar. Tolerant of what it doesn't recognise: a sidecar
    /// written by another application yields whatever standard fields it
    /// carries (rating, label, keywords) and an empty edit stack.
    /// A sidecar is a few kilobytes; anything past this is not one.
    public static let maximumSidecarBytes = 16 * 1024 * 1024

    /// Parsing options: never resolve external entities or DTDs, so a
    /// sidecar someone drops into a photo folder cannot make the app read
    /// other files or fetch a URL.
    static let parseOptions: XMLNode.Options = [.nodePreserveWhitespace, .nodeLoadExternalEntitiesNever]

    /// Opens the file itself without following a link, and checks the size
    /// and type of what was opened: checking the path and then parsing it
    /// let a symbolic link pass the cap with its own few bytes while the
    /// parser read its target whole. Non-blocking, so a FIFO dropped in
    /// under a sidecar's name is refused rather than waited on.
    public static func read(from url: URL) throws -> Fields {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            if code == ELOOP { throw SidecarError.notARegularFile }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw SidecarError.notARegularFile }
        if info.st_size > maximumSidecarBytes { throw SidecarError.tooLarge(Int(info.st_size)) }
        // Bounded even if the file grows after the check.
        let data = try handle.read(upToCount: maximumSidecarBytes + 1) ?? Data()
        if data.count > maximumSidecarBytes { throw SidecarError.tooLarge(data.count) }
        let document = try XMLDocument(data: data, options: parseOptions)
        return try parse(document)
    }

    public static func read(xml: String) throws -> Fields {
        guard xml.utf8.count <= maximumSidecarBytes else { throw SidecarError.tooLarge(xml.utf8.count) }
        let document = try XMLDocument(xmlString: xml, options: parseOptions)
        return try parse(document)
    }

    public enum SidecarError: Error, CustomStringConvertible {
        case tooLarge(Int)
        /// A link, folder or device under a sidecar's name.
        case notARegularFile
        public var description: String {
            switch self {
            case .tooLarge(let n): "sidecar is \(n) bytes; the limit is \(maximumSidecarBytes)"
            case .notARegularFile: "sidecar is not a regular file"
            }
        }
    }

    private static func parse(_ document: XMLDocument) throws -> Fields {
        // Foundation's XPath is namespace-aware and won't resolve a prefix
        // like `rdf:` on its own, so elements are matched by local name.
        // That's also more forgiving of foreign sidecars that declare the
        // standard namespaces under unusual prefixes. Attributes are
        // looked up by their written, prefixed name — the conventional
        // prefixes (xmp, dc, xmpMM) are universal in practice.
        guard let description = try document
            .nodes(forXPath: "//*[local-name()='Description']").first as? XMLElement
        else { throw ReadError.noDescription }

        func attribute(_ name: String) -> String? {
            description.attribute(forName: name)?.stringValue
        }
        func childText(_ localName: String) -> String? {
            (try? description.nodes(forXPath: "*[local-name()='\(localName)']"))?
                .first?.stringValue
        }
        /// An attribute by local name, whatever its prefix. Sidecars from
        /// before the rename use `rawhead:` where new ones use `latent:`;
        /// matching the local name reads both.
        func attributeByLocalName(_ local: String) -> String? {
            description.attributes?.first { $0.localName == local }?.stringValue
        }
        // Some writers put simple properties in child elements rather
        // than attributes; accept both.
        func property(_ name: String, local: String) -> String? {
            attribute(name) ?? attributeByLocalName(local) ?? childText(local)
        }

        let keywords = (try? description.nodes(forXPath:
            "*[local-name()='subject']/*[local-name()='Bag']/*[local-name()='li']"))?
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        // Lightroom's keyword paths ("Places|France|Paris"), when present.
        let hierarchy = (try? description.nodes(forXPath:
            "*[local-name()='hierarchicalSubject']/*[local-name()='Bag']/*[local-name()='li']"))?
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []

        let editStack = childText("EditStack")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let snapshots = childText("Snapshots")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let history = childText("History")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let merge = childText("Merge")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return Fields(
            rating: Int(property("xmp:Rating", local: "Rating") ?? "") ?? 0,
            label: property("xmp:Label", local: "Label").flatMap { $0.isEmpty ? nil : $0 },
            flag: Int(property("latent:Flag", local: "Flag") ?? "") ?? 0,
            rotation: Int(property("latent:Rotation", local: "Rotation") ?? "") ?? 0,
            keywords: KeywordPath.merge(subjects: keywords, hierarchical: hierarchy),
            preservedFileName: property("xmpMM:PreservedFileName", local: "PreservedFileName"),
            sourceHash: property("latent:SourceHash", local: "SourceHash") ?? "",
            schemaVersion: Int(property("latent:SchemaVersion", local: "SchemaVersion") ?? "") ?? 1,
            processVersion: property("latent:ProcessVersion", local: "ProcessVersion") ?? "1.0",
            editStackJSON: editStack,
            snapshotsJSON: snapshots,
            historyJSON: history,
            mergeJSON: merge)
    }
}
