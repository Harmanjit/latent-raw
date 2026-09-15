// Putting a MergeRecipe into XMP, and getting it back out.

import Foundation

/// The `latent:Merge` XMP element: a recipe's JSON wrapped in CDATA.
///
/// XMP is XML. Its "packet" is an `x:xmpmeta` root holding RDF, and an
/// `rdf:Description` holding properties, each an element in some namespace.
/// Ours is one element whose text is the recipe's JSON:
///
///     <rdf:Description rdf:about="" xmlns:latent="https://github.com/Harmanjit/latent-raw/ns/1.0/">
///      <latent:Merge><![CDATA[{"kind":"hdr",...}]]></latent:Merge>
///     </rdf:Description>
///
/// CDATA ("character data") tells the XML parser the text is literal, so
/// the JSON's quotes and `<` or `&` in file names need no escaping. The one
/// thing CDATA can't contain is its own end marker, `]]>`; see `cdata(_:)`.
/// The same element goes into the DNG (tag 700) and the .xmp sidecar.
public enum MergeXMP {
    public static let namespaceURI = "https://github.com/Harmanjit/latent-raw/ns/1.0/"
    public static let prefix = "latent"
    public static let elementName = "Merge"
    public static var qualifiedName: String { "\(prefix):\(elementName)" }

    /// `<latent:Merge><![CDATA[...]]></latent:Merge>`, for a Description
    /// that declares the `latent` namespace.
    public static func element(for recipe: MergeRecipe) throws -> String {
        let json = String(decoding: try recipe.jsonData(), as: UTF8.self)
        return "<\(qualifiedName)>\(cdata(xmlSafe(json)))</\(qualifiedName)>"
    }

    /// A complete XMP packet holding only the recipe, as the DNG's XMP tag carries it.
    public static func packet(for recipe: MergeRecipe) throws -> String {
        // The xpacket wrapper lets tools find XMP in any file by scanning for
        // it; its id is the fixed value the XMP specification defines, and
        // the byte order mark in `begin` tells them the encoding (UTF-8).
        """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:\(prefix)="\(namespaceURI)">
           \(try element(for: recipe))
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    /// `text` as CDATA. A `]]>` inside would end the section early, so the
    /// section is closed between its `]]` and `>` and a new one opened:
    /// `a]]>b` becomes `<![CDATA[a]]]]><![CDATA[>b]]>`, which an XML parser
    /// reads back as `a]]>b`. (JSON can only contain `]]>` inside a string,
    /// such as a file name, but a file name can contain anything.)
    public static func cdata(_ text: String) -> String {
        "<![CDATA[" + text.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>") + "]]>"
    }

    /// Replaces characters XML forbids even inside CDATA (control characters
    /// other than tab and line breaks, U+FFFE, U+FFFF) with JSON `\u` escapes.
    /// JSON only allows them inside strings, where the escape means the same
    /// character, so the recipe decodes unchanged. `JSONEncoder` already
    /// escapes control characters; this covers the rest.
    static func xmlSafe(_ json: String) -> String {
        guard json.unicodeScalars.contains(where: { !isXMLCharacter($0) }) else { return json }
        var out = String.UnicodeScalarView()
        for scalar in json.unicodeScalars {
            if isXMLCharacter(scalar) {
                out.append(scalar)
            } else {
                out.append(contentsOf: String(format: "\\u%04X", scalar.value).unicodeScalars)
            }
        }
        return String(out)
    }

    /// XML 1.0's Char production.
    static func isXMLCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x9, 0xA, 0xD, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: return true
        default: return false
        }
    }

    // MARK: - Reading

    /// The recipe in an XMP packet or sidecar, or nil when there's no
    /// `latent:Merge` element. Throws when there is one but its JSON doesn't
    /// decode.
    ///
    /// A small text scan, not an XML parser: it looks for our own element
    /// and undoes the two ways its text can be stored, CDATA sections (how
    /// Latent writes it) and escaped text (`&quot;`, which is how an XMP
    /// toolkit that rewrites the file may store it). Parsing the whole
    /// packet is the catalog's job; this is for reading back what Latent wrote.
    public static func recipe(fromXMP xmp: String) throws -> MergeRecipe? {
        let open = "<\(qualifiedName)>", close = "</\(qualifiedName)>"
        guard let start = xmp.range(of: open),
              let end = xmp.range(of: close, range: start.upperBound..<xmp.endIndex) else { return nil }
        let text = elementText(String(xmp[start.upperBound..<end.lowerBound]))
        return try MergeRecipe(jsonData: Data(text.utf8))
    }

    /// The text an XML parser would report for an element's content:
    /// CDATA sections taken literally, everything between them unescaped.
    static func elementText(_ content: String) -> String {
        var result = ""
        var rest = Substring(content)
        while let open = rest.range(of: "<![CDATA[") {
            result += unescape(rest[..<open.lowerBound])
            let body = rest[open.upperBound...]
            guard let close = body.range(of: "]]>") else {
                // Unterminated: not valid XML; keep what's there.
                result += body
                return result
            }
            result += body[..<close.lowerBound]
            rest = body[close.upperBound...]
        }
        return result + unescape(rest)
    }

    /// Undoes XML's five named entities and numeric character references.
    static func unescape(_ text: Substring) -> String {
        guard text.contains("&") else { return String(text) }
        var out = ""
        var rest = text
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            guard let semi = rest[amp...].firstIndex(of: ";") else { break }
            let name = rest[rest.index(after: amp)..<semi]
            let named = ["lt": "<", "gt": ">", "amp": "&", "quot": "\"", "apos": "'"]
            if let replacement = named[String(name)] {
                out += replacement
            } else if name.hasPrefix("#"), let scalar = numericReference(name.dropFirst()) {
                out.unicodeScalars.append(scalar)
            } else {
                out += rest[amp...semi]
            }
            rest = rest[rest.index(after: semi)...]
        }
        return out + rest
    }

    private static func numericReference(_ digits: Substring) -> Unicode.Scalar? {
        let value = digits.hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
        return value.flatMap(Unicode.Scalar.init)
    }
}
