// The latent:Merge record: what a merged photo was made from and how.

import Foundation

/// How a merged photo was made, stored as JSON inside its DNG's XMP and its
/// .xmp sidecar (`MergeXMP`). Provenance, and what the editor needs to know
/// about the pixels (where they clip, whether lens corrections are already
/// in them). Latent doesn't promise to re-run a merge from it.
///
/// The JSON keys are a contract shared with the catalog and the renderer, so
/// they never change meaning. Readers ignore keys they don't know (Swift's
/// `Decodable` does by default), which is how later versions add fields.
public struct MergeRecipe: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case hdr
        case panorama
        case hdrPanorama
    }

    /// One photo the merge used.
    public struct Source: Codable, Sendable, Equatable {
        /// Relative to the folder the merged photo is in, so moving the
        /// folder with its photos keeps the link.
        public var path: String
        /// The file's xxHash64, as hex, as the catalog stores it.
        public var hash: String
        /// Capture time, Unix seconds.
        public var captureTime: Int64

        public init(path: String, hash: String, captureTime: Int64) {
            self.path = path
            self.hash = hash
            self.captureTime = captureTime
        }
    }

    /// The format this type writes.
    public static let currentVersion = 1

    public var version: Int
    public var kind: Kind
    /// Which version of the merge algorithm made the pixels.
    public var algorithmVersion: String
    /// The stored value at and above which a pixel is clipped: highlight
    /// reconstruction starts here. In the file's units, after normalisation.
    public var clipLevel: Float
    /// True when lens distortion, vignetting and chromatic aberration
    /// corrections are already in the pixels, so the editor mustn't apply
    /// them again.
    public var lensApplied: Bool
    /// Stops the pixels were divided by to fit under 1.0, already added to
    /// the DNG's BaselineExposure (`ExposureNormalisation.shift`).
    public var baselineShift: Int
    /// Index into `sources` of the frame whose colour and exposure the merge follows.
    public var reference: Int
    /// The merge's settings (deghost amount, projection...), open-ended.
    public var options: [String: JSONValue]
    public var sources: [Source]

    public init(kind: Kind, algorithmVersion: String = "1", clipLevel: Float, lensApplied: Bool,
                baselineShift: Int = 0, reference: Int, options: [String: JSONValue] = [:], sources: [Source]) {
        self.version = Self.currentVersion
        self.kind = kind
        self.algorithmVersion = algorithmVersion
        self.clipLevel = clipLevel
        self.lensApplied = lensApplied
        self.baselineShift = baselineShift
        self.reference = reference
        self.options = options
        self.sources = sources
    }

    /// The recipe as it describes the stored file: `clipLevel` divided like
    /// the pixels and `baselineShift` set, for a recipe written in the
    /// merge's own units. The writer applies this itself; a caller writing
    /// the sidecar before the DNG uses it to write the same values.
    public func normalised(by normalisation: ExposureNormalisation) -> MergeRecipe {
        var stored = self
        stored.clipLevel = normalisation.stored(clipLevel)
        stored.baselineShift = normalisation.shift
        return stored
    }

    /// Compact JSON with sorted keys, so the same recipe is always the same bytes.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public init(jsonData: Data) throws {
        self = try JSONDecoder().decode(MergeRecipe.self, from: jsonData)
    }
}

/// Any JSON value, for the recipe's open-ended `options`.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: DynamicKey.self) {
            var object: [String: JSONValue] = [:]
            for key in container.allKeys { object[key.stringValue] = try container.decode(JSONValue.self, forKey: key) }
            self = .object(object)
        } else if var container = try? decoder.unkeyedContainer() {
            var items: [JSONValue] = []
            while !container.isAtEnd { items.append(try container.decode(JSONValue.self)) }
            self = .array(items)
        } else {
            let container = try decoder.singleValueContainer()
            // Bool before number, so JSON's true doesn't come back as 1.
            if let v = try? container.decode(Bool.self) {
                self = .bool(v)
            } else if let v = try? container.decode(Double.self) {
                self = .number(v)
            } else if let v = try? container.decode(String.self) {
                self = .string(v)
            } else {
                // Not an object, array, bool, number or string: JSON has only null left.
                self = .null
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .string(let v): var c = encoder.singleValueContainer(); try c.encode(v)
        case .number(let v): var c = encoder.singleValueContainer(); try c.encode(v)
        case .bool(let v): var c = encoder.singleValueContainer(); try c.encode(v)
        case .null: var c = encoder.singleValueContainer(); try c.encodeNil()
        case .array(let items):
            var c = encoder.unkeyedContainer()
            for item in items { try c.encode(item) }
        case .object(let object):
            var c = encoder.container(keyedBy: DynamicKey.self)
            for (key, value) in object { try c.encode(value, forKey: DynamicKey(key)) }
        }
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}
