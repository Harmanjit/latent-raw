import Foundation

/// The Lensfun lens database, parsed from the XML files shipped in this
/// module's resources (see Resources/lensfun-db/README.md). Read-only
/// once loaded, so it's safe to share across threads.
///
/// Loading parses ~5 MB of XML with a streaming parser, a few hundred
/// milliseconds. `shared` does it once, on first use; the app warms it
/// in the background at launch so the first image doesn't pay.
public final class LensfunDatabase: Sendable {
    public let cameras: [LensfunCamera]
    public let lenses: [LensfunLens]
    /// mount name -> names of mounts whose lenses also fit.
    public let mountCompatibility: [String: [String]]
    /// Database version, for recording in edits (DESIGN.md §5.6).
    public let version: String

    /// The bundled database.
    public static let shared: LensfunDatabase = {
        (try? LensfunDatabase(bundled: ())) ?? LensfunDatabase(cameras: [], lenses: [],
                                                                mountCompatibility: [:],
                                                                version: "none")
    }()

    /// Kicks off loading on a background thread so `shared` is ready by
    /// the time an image is opened.
    public static func warmUp() {
        Thread.detachNewThread { _ = LensfunDatabase.shared }
    }

    init(cameras: [LensfunCamera], lenses: [LensfunLens],
         mountCompatibility: [String: [String]], version: String) {
        self.cameras = cameras
        self.lenses = lenses
        self.mountCompatibility = mountCompatibility
        self.version = version
    }

    convenience init(bundled: Void) throws {
        guard let directory = Bundle.latentResources.url(forResource: "lensfun-db", withExtension: nil) else {
            throw LensfunError.databaseMissing
        }
        try self.init(directory: directory)
    }

    /// Loads every `*.xml` in `directory`.
    public convenience init(directory: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var version = "unknown"
        if let readme = try? String(contentsOf: directory.appendingPathComponent("README.md"), encoding: .utf8),
           let line = readme.split(separator: "\n").first(where: { $0.hasPrefix("- Date:") }) {
            version = line.replacingOccurrences(of: "- Date:", with: "").trimmingCharacters(in: .whitespaces)
        }

        var cameras: [LensfunCamera] = []
        var lenses: [LensfunLens] = []
        var compat: [String: [String]] = [:]
        for file in files {
            let parser = LensfunXMLParser()
            try parser.parse(url: file)
            cameras += parser.cameras
            lenses += parser.lenses
            compat.merge(parser.mountCompatibility) { $0 + $1 }
        }
        self.init(cameras: cameras, lenses: lenses, mountCompatibility: compat, version: version)
    }

    /// Mounts whose lenses fit a body with `mount`: the mount itself plus
    /// everything the database lists as compatible.
    public func mountsAccepted(by mount: String) -> Set<String> {
        var set: Set<String> = [mount]
        set.formUnion(mountCompatibility[mount] ?? [])
        return set
    }
}

public enum LensfunError: Error {
    case databaseMissing
    case parseFailed(String)
}

/// Streaming parser for one database file. Element vocabulary is small
/// and stable: mount / camera / lens, with the calibration children.
final class LensfunXMLParser: NSObject, XMLParserDelegate {
    private(set) var cameras: [LensfunCamera] = []
    private(set) var lenses: [LensfunLens] = []
    private(set) var mountCompatibility: [String: [String]] = [:]

    private var text = ""
    private var path: [String] = []
    private var error: String?

    // Mount being built.
    private var mountName = ""
    private var mountCompat: [String] = []
    // Camera / lens being built.
    private var maker = ""
    private var modelDefault = ""
    private var modelNames: [String] = []
    private var currentLang: String?
    private var mounts: [String] = []
    private var cropFactor: Float = 1
    private var aspectRatio: Float = 1.5
    private var distortion: [LensfunLens.DistortionPoint] = []
    private var tca: [LensfunLens.TCAPoint] = []
    private var vignetting: [LensfunLens.VignettingPoint] = []
    private var focalElement: ClosedRange<Float>?
    private var apertureElement: Float?

    func parse(url: URL) throws {
        guard let parser = XMLParser(contentsOf: url) else { throw LensfunError.parseFailed(url.path) }
        parser.delegate = self
        // The DTD reference isn't shipped; don't try to resolve it.
        parser.shouldResolveExternalEntities = false
        if !parser.parse(), let err = parser.parserError {
            throw LensfunError.parseFailed("\(url.lastPathComponent): \(err)")
        }
        if let error { throw LensfunError.parseFailed(error) }
    }

    private func reset() {
        maker = ""; modelDefault = ""; modelNames = []; mounts = []
        cropFactor = 1; aspectRatio = 1.5
        distortion = []; tca = []; vignetting = []
        focalElement = nil; apertureElement = nil
    }

    private func f(_ attrs: [String: String], _ key: String, _ fallback: Float) -> Float {
        attrs[key].flatMap(Float.init) ?? fallback
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes attrs: [String: String]) {
        path.append(name)
        text = ""
        currentLang = attrs["lang"]
        switch name {
        case "mount": mountName = ""; mountCompat = []
        case "camera", "lens": reset()
        case "focal" where path.count >= 2 && path[path.count - 2] == "lens":
            // <focal min="18" max="70"/> or <focal value="50"/>.
            if let v = attrs["value"].flatMap(Float.init) { focalElement = v...v }
            else if let lo = attrs["min"].flatMap(Float.init), let hi = attrs["max"].flatMap(Float.init), lo <= hi {
                focalElement = lo...hi
            }
        case "aperture" where path.count >= 2 && path[path.count - 2] == "lens":
            // <aperture min="3.5" max="22"/>: min is the widest (smallest
            // f-number), max the smallest opening, which isn't needed.
            apertureElement = attrs["min"].flatMap(Float.init) ?? attrs["value"].flatMap(Float.init)
        case "distortion":
            let focal = f(attrs, "focal", 0)
            let model: DistortionModel?
            switch attrs["model"] {
            case "ptlens": model = .ptlens(a: f(attrs, "a", 0), b: f(attrs, "b", 0), c: f(attrs, "c", 0))
            case "poly3":  model = .poly3(k1: f(attrs, "k1", 0))
            case "poly5":  model = .poly5(k1: f(attrs, "k1", 0), k2: f(attrs, "k2", 0))
            default:       model = nil   // "none" or unknown
            }
            if let model { distortion.append(.init(focal: focal, model: model)) }
        case "tca":
            let focal = f(attrs, "focal", 0)
            switch attrs["model"] {
            case "linear":
                tca.append(.init(focal: focal, model: TCAModel(
                    red: SIMD3(0, 0, f(attrs, "kr", 1)), blue: SIMD3(0, 0, f(attrs, "kb", 1)))))
            case "poly3":
                tca.append(.init(focal: focal, model: TCAModel(
                    red: SIMD3(f(attrs, "br", 0), f(attrs, "cr", 0), f(attrs, "vr", 1)),
                    blue: SIMD3(f(attrs, "bb", 0), f(attrs, "cb", 0), f(attrs, "vb", 1)))))
            default: break
            }
        case "vignetting":
            if attrs["model"] == "pa" {
                vignetting.append(.init(focal: f(attrs, "focal", 0), aperture: f(attrs, "aperture", 0),
                                        distance: f(attrs, "distance", 1000),
                                        model: VignettingModel(k1: f(attrs, "k1", 0),
                                                               k2: f(attrs, "k2", 0),
                                                               k3: f(attrs, "k3", 0))))
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = path.count >= 2 ? path[path.count - 2] : ""
        switch (parent, name) {
        case ("mount", "name"):   mountName = value
        case ("mount", "compat"): mountCompat.append(value)
        case (_, "mount") where path.count == 2:
            mountCompatibility[mountName, default: []] += mountCompat
        case ("camera", "maker"), ("lens", "maker"):
            if currentLang == nil || maker.isEmpty { maker = value }
        case ("camera", "model"), ("lens", "model"):
            if currentLang == nil { modelDefault = value }
            modelNames.append(value)
        case ("camera", "mount"): mounts = [value]
        case ("lens", "mount"): mounts.append(value)
        case (_, "cropfactor"): cropFactor = Float(value) ?? 1
        case (_, "aspect-ratio"):
            // "3:2" or a plain number.
            let parts = value.split(separator: ":").compactMap { Float($0) }
            aspectRatio = parts.count == 2 && parts[1] > 0 ? parts[0] / parts[1] : (Float(value) ?? 1.5)
        case (_, "camera"):
            cameras.append(LensfunCamera(maker: maker, model: modelDefault, modelNames: modelNames,
                                         mount: mounts.first ?? "", cropFactor: cropFactor))
        case (_, "lens"):
            let spec = LensSpec.resolve(names: [modelDefault] + modelNames,
                                        focalElement: focalElement, apertureElement: apertureElement)
            lenses.append(LensfunLens(maker: maker, model: modelDefault, modelNames: modelNames,
                                      mounts: mounts, cropFactor: cropFactor, aspectRatio: aspectRatio,
                                      distortion: distortion, tca: tca, vignetting: vignetting,
                                      spec: spec))
        default: break
        }
        currentLang = nil
        text = ""
        path.removeLast()
    }
}

extension Bundle {
    /// The resource bundle for this module, found the way a shipped app
    /// needs it. SwiftPM's generated `Bundle.module` looks only in the app
    /// bundle's root and in a hard-coded `.build/` path, so an app built by
    /// scripts/make_app.sh (resources in Contents/Resources, per macOS
    /// convention) crashed at launch once the build directory was gone.
    /// Check Contents/Resources first; `Bundle.module` still serves
    /// `swift run` and `swift test`.
    static let latentResources: Bundle = {
        let name = "latent_LensKit.bundle"
        if let url = Bundle.main.resourceURL?.appendingPathComponent(name),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()
}
