import Foundation

/// Reads and writes edit-stack XMP sidecars (DESIGN.md §5.5).
///
/// Writes are atomic: to a temporary file, then renamed over the old
/// sidecar, so a crash mid-write can never leave a half-written file
/// (DESIGN.md §5.3). Reads use Foundation's XMLDocument. Exiv2 (per
/// DESIGN.md §3) may replace the read side later for MakerNotes and
/// arbitrary foreign XMP; for Latent's own sidecars this is enough.
public enum XMPSidecar {
    /// The namespace URI is fixed once released — see DESIGN.md §5.5 / §16.
    /// TODO: fill in the real GitHub owner path before first public commit.
    static let namespaceURI = "https://github.com/OWNER/latent/ns/1.0/"

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

        public init(rating: Int = 0, label: String? = nil, flag: Int = 0, rotation: Int = 0,
                    keywords: [String] = [],
                    preservedFileName: String? = nil, sourceHash: String,
                    schemaVersion: Int = 1, processVersion: String = "1.0",
                    editStackJSON: String = "", snapshotsJSON: String = "", historyJSON: String = "") {
            self.snapshotsJSON = snapshotsJSON
            self.historyJSON = historyJSON
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
        case notXMP
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
        let tmp = directory
            .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")

        try xml.write(to: tmp, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmp)
    }

    private static func render(_ f: Fields) -> String {
        let keywordItems = f.keywords.map { "      <rdf:li>\(escape($0))</rdf:li>" }.joined(separator: "\n")
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
            xmlns:latent="\(namespaceURI)"
            xmp:Rating="\(f.rating)"\(labelAttr)\(preservedAttr)
            latent:SchemaVersion="\(f.schemaVersion)"
            latent:ProcessVersion="\(escape(f.processVersion))"
            latent:SourceHash="\(escape(f.sourceHash))"
            latent:Flag="\(f.flag)"
            latent:Rotation="\(f.rotation)">
           <dc:subject><rdf:Bag>
        \(keywordItems)
           </rdf:Bag></dc:subject>
           <latent:EditStack><![CDATA[\(f.editStackJSON)]]></latent:EditStack>
        \(f.snapshotsJSON.isEmpty ? "" : "   <latent:Snapshots><![CDATA[\(f.snapshotsJSON)]]></latent:Snapshots>")
        \(f.historyJSON.isEmpty ? "" : "   <latent:History><![CDATA[\(f.historyJSON)]]></latent:History>")
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
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
    public static func read(from url: URL) throws -> Fields {
        let document = try XMLDocument(contentsOf: url, options: [.nodePreserveWhitespace])
        return try parse(document)
    }

    public static func read(xml: String) throws -> Fields {
        let document = try XMLDocument(xmlString: xml, options: [.nodePreserveWhitespace])
        return try parse(document)
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
        // Some writers put simple properties in child elements rather
        // than attributes; accept both.
        func property(_ name: String, local: String) -> String? {
            attribute(name) ?? childText(local)
        }

        let keywords = (try? description.nodes(forXPath:
            "*[local-name()='subject']/*[local-name()='Bag']/*[local-name()='li']"))?
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []

        let editStack = childText("EditStack")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let snapshots = childText("Snapshots")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let history = childText("History")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return Fields(
            rating: Int(property("xmp:Rating", local: "Rating") ?? "") ?? 0,
            label: property("xmp:Label", local: "Label").flatMap { $0.isEmpty ? nil : $0 },
            flag: Int(property("latent:Flag", local: "Flag") ?? "") ?? 0,
            rotation: Int(property("latent:Rotation", local: "Rotation") ?? "") ?? 0,
            keywords: keywords,
            preservedFileName: property("xmpMM:PreservedFileName", local: "PreservedFileName"),
            sourceHash: property("latent:SourceHash", local: "SourceHash") ?? "",
            schemaVersion: Int(property("latent:SchemaVersion", local: "SchemaVersion") ?? "") ?? 1,
            processVersion: property("latent:ProcessVersion", local: "ProcessVersion") ?? "1.0",
            editStackJSON: editStack,
            snapshotsJSON: snapshots,
            historyJSON: history)
    }
}
