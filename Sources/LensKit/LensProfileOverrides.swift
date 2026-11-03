import Foundation
import Synchronization
import RawCore

/// Lens profiles chosen by hand, for a camera and lens the automatic match
/// gets wrong or can't place (DESIGN.md §9.2: a wrong profile is worse than
/// none, so the matcher refuses to guess, and this is how the user fills
/// the gap).
///
/// The catalog keeps the choices (`lens_overrides`: camera, lens, Lensfun
/// model) and loads them here when it opens, so every image opened in this
/// process with that camera and lens, in the editor, an export or a
/// thumbnail, resolves the chosen profile. A process-wide table rather than
/// a parameter because the choice belongs to the lens, not to one photo.
public enum LensProfileOverrides {
    /// What identifies "this lens on this camera" across files.
    public struct Key: Hashable, Sendable, Codable {
        public var camera: String
        public var lens: String

        public init(camera: String, lens: String) {
            self.camera = camera
            self.lens = lens
        }

        /// From a raw file's metadata. The lens part prefers what the file
        /// names the lens, then the maker's lens ID, then its focal range
        /// and apertures, which is everything the matcher itself sees.
        public init(cameraMake: String, cameraModel: String, lensName: String, identity: LensIdentity) {
            camera = [cameraMake, cameraModel].map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: " ")
            var parts: [String] = []
            let name = lensName.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { parts.append(name) }
            if identity.makerLensID != 0 { parts.append("id \(identity.makerLensID)") }
            if identity.nikonLensID != 0 { parts.append("nikon \(identity.nikonLensID)/\(identity.nikonLensType)") }
            if identity.minFocal > 0 {
                parts.append(String(format: "%.0f-%.0fmm f/%.1f-%.1f", identity.minFocal, identity.maxFocal,
                                    identity.maxApertureAtMinFocal, identity.maxApertureAtMaxFocal))
            }
            lens = parts.isEmpty ? "unknown lens" : parts.joined(separator: " · ")
        }
    }

    private static let table = Mutex<[Key: String]>([:])

    /// Replaces every choice, as the catalog holds them.
    public static func replaceAll(_ choices: [Key: String]) {
        table.withLock { $0 = choices }
    }

    /// Sets (or with nil clears) one choice.
    public static func set(_ model: String?, for key: Key) {
        table.withLock { $0[key] = model }
    }

    /// The Lensfun model chosen for `key`, if any.
    public static func model(for key: Key) -> String? {
        table.withLock { $0[key] }
    }

    /// The profile for a file: the chosen one when there is a choice and
    /// the database still has it, else the automatic match.
    public static func match(cameraMake: String, cameraModel: String, lensName: String,
                             identity: LensIdentity, focal: Double,
                             in db: LensfunDatabase = .shared) -> LensProfileMatch? {
        let key = Key(cameraMake: cameraMake, cameraModel: cameraModel, lensName: lensName, identity: identity)
        if let chosen = model(for: key),
           let manual = manualMatch(model: chosen, cameraMake: cameraMake, cameraModel: cameraModel,
                                    identity: identity, in: db) {
            return manual
        }
        return LensMatcher.match(cameraMake: cameraMake, cameraModel: cameraModel, lensName: lensName,
                                 identity: identity, focal: focal, in: db)
    }

    /// A match for a lens picked by name. The camera comes from the
    /// database when it lists the body; otherwise a stand-in with the
    /// file's crop factor (or the lens's calibration crop), which is all
    /// the correction needs from it.
    public static func manualMatch(model: String, cameraMake: String, cameraModel: String,
                                   identity: LensIdentity, in db: LensfunDatabase = .shared) -> LensProfileMatch? {
        guard let lens = db.lenses.first(where: { $0.model == model }) else { return nil }
        let camera = LensMatcher.findCamera(make: cameraMake, model: cameraModel, in: db)
            ?? LensfunCamera(maker: cameraMake, model: cameraModel, modelNames: [cameraModel],
                             mount: lens.mounts.first ?? "",
                             cropFactor: identity.cropFactor > 0 ? Float(identity.cropFactor) : lens.cropFactor)
        return LensProfileMatch(camera: camera, lens: lens,
                                shotCropFactor: LensProfileMatch.shotCropFactor(
                                    exifCropFactor: identity.cropFactor, bodyCropFactor: camera.cropFactor))
    }

    /// The lenses a picker should offer: those with any correction data,
    /// grouped by maker, makers and models in alphabetical order. Lenses
    /// that fit the camera's mount (when the database knows the camera)
    /// come first within the list as `fitting`; the rest are `others`.
    public static func choices(cameraMake: String, cameraModel: String,
                               in db: LensfunDatabase = .shared) -> (fitting: [LensfunLens], others: [LensfunLens]) {
        let usable = db.lenses.filter { !$0.distortion.isEmpty || !$0.tca.isEmpty || !$0.vignetting.isEmpty }
        var seen = Set<String>()
        let unique = usable.filter { seen.insert($0.model).inserted }
            .sorted { ($0.maker.lowercased(), $0.model.lowercased()) < ($1.maker.lowercased(), $1.model.lowercased()) }
        guard let camera = LensMatcher.findCamera(make: cameraMake, model: cameraModel, in: db) else {
            return ([], unique)
        }
        let mounts = db.mountsAccepted(by: camera.mount)
        let fitting = unique.filter { !mounts.isDisjoint(with: $0.mounts) }
        let fittingModels = Set(fitting.map(\.model))
        return (fitting, unique.filter { !fittingModels.contains($0.model) })
    }
}
