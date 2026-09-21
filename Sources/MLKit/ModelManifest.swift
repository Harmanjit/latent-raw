import Foundation
import CoreML
import CryptoKit

/// One `<id>.model.json` beside its package(s): what a model is, where it
/// came from, which packages make it up and how each hashes. The same
/// shape is a row of ModelCatalog.json, where the packages carry no hash
/// because nothing is installed yet (docs/Retouch.md §2 A).
///
/// Decoding is lenient about the optional keys and strict about the rest:
/// a manifest arrives from the same untrusted folder as its weights, so
/// the id is checked against `idPattern` (it names a folder and a cache
/// entry) and the two URLs must be http(s) (they open in a browser).
public struct ModelManifest: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable { case promptedSegmentation, subjectSegmentation, semanticSegmentation, denoise }

    public enum ComputeUnits: String, Codable, Sendable {
        case cpuOnly, cpuAndGPU, cpuAndNeuralEngine, all

        /// cpuOnly 0, cpuAndGPU 1, cpuAndNeuralEngine 1, all 2: the
        /// registry runs a model at the lowest rank anyone asks for, so a
        /// manifest can keep a model off the Neural Engine (see
        /// `CoreMLStore.defaultComputeUnits` for why one would).
        public var rank: Int {
            switch self {
            case .cpuOnly: return 0
            case .cpuAndGPU, .cpuAndNeuralEngine: return 1
            case .all: return 2
            }
        }

        public var mlComputeUnits: MLComputeUnits {
            switch self {
            case .cpuOnly: return .cpuOnly
            case .cpuAndGPU: return .cpuAndGPU
            case .cpuAndNeuralEngine: return .cpuAndNeuralEngine
            case .all: return .all
            }
        }

        public init(_ units: MLComputeUnits) {
            switch units {
            case .cpuOnly: self = .cpuOnly
            case .cpuAndGPU: self = .cpuAndGPU
            case .cpuAndNeuralEngine: self = .cpuAndNeuralEngine
            case .all: self = .all
            @unknown default: self = .all
            }
        }
    }

    public enum Activation: String, Codable, Sendable { case sigmoid, probabilities }
    public enum Refine: String, Codable, Sendable { case none, guided }

    public struct Licence: Codable, Sendable, Equatable {
        public var name: String
        public var url: URL
        public var commercialUse: Bool

        public init(name: String, url: URL, commercialUse: Bool) {
            self.name = name
            self.url = url
            self.commercialUse = commercialUse
        }

        private enum CodingKeys: String, CodingKey { case name, url, commercialUse }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try ModelManifest.required(String.self, .name, in: c, path: "licence")
            url = try ModelManifest.webURL(try ModelManifest.required(String.self, .url, in: c, path: "licence"))
            commercialUse = try ModelManifest.required(Bool.self, .commercialUse, in: c, path: "licence")
        }
    }

    public struct Package: Codable, Sendable, Equatable {
        /// "<name>.mlpackage" inside the model's folder.
        public var name: String
        /// imageEncoder | promptEncoder | maskDecoder for prompted kinds.
        public var role: String?
        /// `PackageHash.sha256(ofPackageAt:)` of the package; nil only in
        /// catalogue rows.
        public var sha256: String?
        public var inputNames: [String]
        public var outputNames: [String]

        public init(name: String, role: String? = nil, sha256: String?,
                    inputNames: [String] = [], outputNames: [String] = []) {
            self.name = name
            self.role = role
            self.sha256 = sha256
            self.inputNames = inputNames
            self.outputNames = outputNames
        }

        private enum CodingKeys: String, CodingKey { case name, role, sha256, inputNames, outputNames }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try ModelManifest.required(String.self, .name, in: c, path: "packages")
            role = try c.decodeIfPresent(String.self, forKey: .role)
            sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
            inputNames = try c.decodeIfPresent([String].self, forKey: .inputNames) ?? []
            outputNames = try c.decodeIfPresent([String].self, forKey: .outputNames) ?? []
        }
    }

    public struct Converter: Codable, Sendable, Equatable {
        public var script: String
        public var sourceRevision: String?
        public var coremltools: String?
        public var torch: String?
        public var date: String?

        public init(script: String, sourceRevision: String? = nil, coremltools: String? = nil,
                    torch: String? = nil, date: String? = nil) {
            self.script = script
            self.sourceRevision = sourceRevision
            self.coremltools = coremltools
            self.torch = torch
            self.date = date
        }
    }

    /// What an id may look like: it names `external/<id>/` and the
    /// compile-cache entries, so nothing a path could misread.
    public static let idPattern = "^[a-z0-9][a-z0-9.-]{0,63}$"

    public var id: String
    public var displayName: String
    public var purpose: String
    public var version: Int
    public var kind: Kind
    public var licence: Licence
    /// http(s) only: "Get…" opens it in the browser.
    public var sourceURL: URL
    public var sizeMB: Int
    /// The square the image is stretched to.
    public var inputSize: Int
    public var packages: [Package]
    /// Subject kind: what the output holds.
    public var outputActivation: Activation?
    /// Subject kind; nil = .none.
    public var refine: Refine?
    /// Semantic kind: the labels JSON beside the package.
    public var labelsFile: String?
    /// nil = no manifest override.
    public var computeUnits: ComputeUnits?
    public var converter: Converter?

    /// What MaskShape stores: "<id>@<version>".
    public var modelVersion: String { "\(id)@\(version)" }
    /// Every package carries a hash: a manifest, not a catalogue row.
    public var isInstallable: Bool { packages.allSatisfy { $0.sha256 != nil } }

    public init(id: String, displayName: String, purpose: String, version: Int, kind: Kind, licence: Licence,
                sourceURL: URL, sizeMB: Int, inputSize: Int, packages: [Package],
                outputActivation: Activation? = nil, refine: Refine? = nil, labelsFile: String? = nil,
                computeUnits: ComputeUnits? = nil, converter: Converter? = nil) {
        self.id = id
        self.displayName = displayName
        self.purpose = purpose
        self.version = version
        self.kind = kind
        self.licence = licence
        self.sourceURL = sourceURL
        self.sizeMB = sizeMB
        self.inputSize = inputSize
        self.packages = packages
        self.outputActivation = outputActivation
        self.refine = refine
        self.labelsFile = labelsFile
        self.computeUnits = computeUnits
        self.converter = converter
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, purpose, version, kind, licence, sourceURL, sizeMB, inputSize, packages
        case outputActivation, refine, labelsFile, computeUnits, converter
    }

    /// Optional keys lenient; throws `ManifestError` for a missing required
    /// key, an id off `idPattern`, or a non-http(s) URL. Unknown keys are
    /// ignored, so a manifest written by a later build still lists.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try Self.required(String.self, .id, in: c)
        guard Self.isValidID(id) else { throw ManifestError.badID(id) }
        displayName = try Self.required(String.self, .displayName, in: c)
        purpose = try Self.required(String.self, .purpose, in: c)
        version = try Self.required(Int.self, .version, in: c)
        kind = try Self.required(Kind.self, .kind, in: c)
        licence = try Self.required(Licence.self, .licence, in: c)
        sourceURL = try Self.webURL(try Self.required(String.self, .sourceURL, in: c))
        sizeMB = try Self.required(Int.self, .sizeMB, in: c)
        inputSize = try Self.required(Int.self, .inputSize, in: c)
        packages = try Self.required([Package].self, .packages, in: c)
        outputActivation = try c.decodeIfPresent(Activation.self, forKey: .outputActivation)
        refine = try c.decodeIfPresent(Refine.self, forKey: .refine)
        labelsFile = try c.decodeIfPresent(String.self, forKey: .labelsFile)
        computeUnits = try c.decodeIfPresent(ComputeUnits.self, forKey: .computeUnits)
        converter = try c.decodeIfPresent(Converter.self, forKey: .converter)
    }

    public static func load(from url: URL) throws -> ModelManifest {
        try JSONDecoder().decode(ModelManifest.self, from: try Data(contentsOf: url))
    }

    public static func isValidID(_ id: String) -> Bool {
        // The whole string must match: `$` alone would let a trailing
        // newline through.
        id.range(of: idPattern, options: .regularExpression) == id.startIndex..<id.endIndex
    }

    // MARK: - Decoding helpers

    /// A required key, or `ManifestError.missingKey` naming it (with its
    /// parent for the nested structs). A key that is there but of the
    /// wrong type is missing too, as far as a reader is concerned.
    fileprivate static func required<T: Decodable, K: CodingKey>(_ type: T.Type, _ key: K,
                                                                 in container: KeyedDecodingContainer<K>,
                                                                 path: String? = nil) throws -> T {
        let name = path.map { "\($0).\(key.stringValue)" } ?? key.stringValue
        do {
            guard let value = try container.decodeIfPresent(type, forKey: key) else {
                throw ManifestError.missingKey(name)
            }
            return value
        } catch let error as ManifestError {
            throw error
        } catch {
            throw ManifestError.missingKey(name)
        }
    }

    /// The string as a URL, when it is one with an http or https scheme.
    fileprivate static func webURL(_ string: String) throws -> URL {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else {
            throw ManifestError.badURL(string)
        }
        return url
    }
}

public enum ManifestError: Error, Equatable, CustomStringConvertible {
    case missingKey(String), badID(String), badURL(String)

    public var description: String {
        switch self {
        case .missingKey(let key): return "The model's manifest has no '\(key)'."
        case .badID(let id): return "The model id '\(id)' is not lower-case letters, digits, dots and dashes."
        case .badURL(let url): return "The model's manifest links to '\(url)', which is not a web address."
        }
    }
}

/// Which model a stored `modelVersion` names.
///
/// Masks store "<id>@<version>". The four literals earlier sidecars wrote
/// are parsed, never rewritten on load, so a 0.9.0 sidecar stays
/// byte-identical until an edit changes it.
public struct ModelRef: Hashable, Sendable {
    public var id: String
    public var version: Int

    public init(id: String, version: Int) {
        self.id = id
        self.version = version
    }

    /// Parses "<id>@<version>" and the four legacy literals; nil for
    /// anything else (the kind's default then runs and says so).
    public init?(stored: String) {
        if let legacy = Self.legacy[stored] {
            self = legacy
            return
        }
        guard let at = stored.lastIndex(of: "@") else { return nil }
        let id = String(stored[..<at])
        let digits = stored[stored.index(after: at)...]
        guard ModelManifest.isValidID(id), !digits.isEmpty, digits.allSatisfy(\.isNumber),
              let version = Int(digits) else { return nil }
        self.init(id: id, version: version)
    }

    public var stored: String { "\(id)@\(version)" }

    public static let legacy: [String: ModelRef] = [
        "sam2.1-small.1": ModelRef(id: "sam2.1-small", version: 1),
        "vision.foregroundInstance.1": ModelRef(id: "vision.foregroundInstance", version: 1),
        "segformer-b2-ade20k-512.1": ModelRef(id: "segformer-b2-ade20k-512", version: 1),
        "latent.skyHeuristic.1": ModelRef(id: "latent.skyHeuristic", version: 1)]
}

/// The content hash of a `.mlpackage`, as `scripts/latent_manifest.py`
/// computes it: the same three files in the same order, so the two never
/// disagree about a package. It catches corruption and keys the compile
/// cache; the sandbox, not the hash, is the security boundary.
public enum PackageHash {
    public static let hashedFiles = ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"]

    /// SHA-256 over `hashedFiles` in that order, each as relative-path
    /// bytes + 0x00 + file bytes. Throws `PackageHashError.unexpectedFile`
    /// for any other regular file in the package (hidden ones included,
    /// as the script counts them) and `.missingFile` for one of the three
    /// that isn't there.
    public static func sha256(ofPackageAt url: URL) throws -> String {
        let fm = FileManager.default
        let root = url.standardizedFileURL
        // Every regular file, before any hashing, so a package with a file
        // the hash would not cover is refused whole.
        let expected = Set(hashedFiles)
        if let walk = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: []) {
            for case let file as URL in walk {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let relative = relativePath(of: file, under: root)
                if !expected.contains(relative) { throw PackageHashError.unexpectedFile(relative) }
            }
        }
        var hasher = SHA256()
        for relative in hashedFiles {
            let file = root.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw PackageHashError.missingFile(relative)
            }
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: Data([0]))
            // Streamed: the weights file is tens to hundreds of megabytes.
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func relativePath(of file: URL, under root: URL) -> String {
        let rootParts = root.pathComponents
        let parts = file.standardizedFileURL.pathComponents
        guard parts.count > rootParts.count else { return file.lastPathComponent }
        return parts[rootParts.count...].joined(separator: "/")
    }
}

public enum PackageHashError: Error, Equatable { case missingFile(String), unexpectedFile(String) }
