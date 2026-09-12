import Foundation

/// Writes edit-stack XMP sidecars atomically (DESIGN.md §5.3: "write to a
/// temporary file, then atomically rename"). This is a minimal hand-rolled
/// writer for Phase 2 bring-up; Exiv2 (per DESIGN.md §3) will likely replace
/// the read side once we need to parse MakerNotes and arbitrary existing
/// XMP, but a dependency-free writer is enough to prove the round trip.
public enum XMPSidecar {
    /// namespace URI is fixed once released — see DESIGN.md §5.5 / §16.
    /// TODO: fill in the real GitHub owner path before first public commit.
    static let namespaceURI = "https://github.com/OWNER/rawhead/ns/1.0/"

    public struct Fields {
        public var rating: Int
        public var label: String?
        public var keywords: [String]
        public var preservedFileName: String?
        public var sourceHashHex: String
        public var schemaVersion: Int
        public var processVersion: String
        public var editStackJSON: String   // pre-serialized, see DESIGN.md §5.6

        public init(rating: Int = 0, label: String? = nil, keywords: [String] = [],
                    preservedFileName: String? = nil, sourceHashHex: String,
                    schemaVersion: Int = 1, processVersion: String = "1.0",
                    editStackJSON: String) {
            self.rating = rating
            self.label = label
            self.keywords = keywords
            self.preservedFileName = preservedFileName
            self.sourceHashHex = sourceHashHex
            self.schemaVersion = schemaVersion
            self.processVersion = processVersion
            self.editStackJSON = editStackJSON
        }
    }

    /// Writes `fields` to `destination` via a temp file + atomic rename, so a
    /// crash mid-write can never leave a half-written sidecar (DESIGN.md §5.3).
    public static func write(_ fields: Fields, to destination: URL) throws {
        let xml = render(fields)
        let tmp = destination.deletingLastPathComponent()
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
            xmlns:rawhead="\(namespaceURI)"
            xmp:Rating="\(f.rating)"\(labelAttr)\(preservedAttr)
            rawhead:SchemaVersion="\(f.schemaVersion)"
            rawhead:ProcessVersion="\(escape(f.processVersion))"
            rawhead:SourceHash="xxh3:\(f.sourceHashHex)">
           <dc:subject><rdf:Bag>
        \(keywordItems)
           </rdf:Bag></dc:subject>
           <rawhead:EditStack><![CDATA[\(f.editStackJSON)]]></rawhead:EditStack>
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
}
