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
    ///
    /// Worked out once per database and camera and then kept: the picker
    /// asks on every redraw of the Lens Corrections panel, and filtering
    /// and sorting the whole database each time cost several milliseconds
    /// per slider tick. The database is read-only once loaded, so a list
    /// kept for it never goes stale; a different database starts afresh.
    public static func choices(cameraMake: String, cameraModel: String,
                               in db: LensfunDatabase = .shared) -> (fitting: [LensfunLens], others: [LensfunLens]) {
        let lists = entry(cameraMake: cameraMake, cameraModel: cameraModel, in: db)
        return (lists.fitting, lists.others)
    }

    /// One maker's lenses in the picker, models in alphabetical order.
    public struct MakerGroup: Sendable, Equatable {
        public var maker: String
        public var lenses: [LensfunLens]
    }

    /// The picker's lists already grouped by maker, makers in
    /// alphabetical order (ignoring case), as `choices` orders them.
    public struct PickerMenu: Sendable, Equatable {
        public var fitting: [MakerGroup]
        public var others: [MakerGroup]

        public init(fitting: [MakerGroup], others: [MakerGroup]) {
            self.fitting = fitting
            self.others = others
        }
    }

    /// `choices`, grouped by maker for the menu, from the same kept lists.
    public static func pickerMenu(cameraMake: String, cameraModel: String,
                                  in db: LensfunDatabase = .shared) -> PickerMenu {
        entry(cameraMake: cameraMake, cameraModel: cameraModel, in: db).menu
    }

    private static func entry(cameraMake: String, cameraModel: String, in db: LensfunDatabase) -> Entry {
        let camera = CameraKey(make: cameraMake, model: cameraModel)
        if let kept = menuCache.withLock({ $0.db === db ? $0.menus[camera] : nil }) { return kept }
        let unique = usableLenses(in: db)
        let fitting: [LensfunLens], others: [LensfunLens]
        if let body = LensMatcher.findCamera(make: cameraMake, model: cameraModel, in: db) {
            let mounts = db.mountsAccepted(by: body.mount)
            fitting = unique.filter { !mounts.isDisjoint(with: $0.mounts) }
            let fittingModels = Set(fitting.map(\.model))
            others = unique.filter { !fittingModels.contains($0.model) }
        } else {
            (fitting, others) = ([], unique)
        }
        let made = Entry(fitting: fitting, others: others,
                         menu: PickerMenu(fitting: groupedByMaker(fitting), others: groupedByMaker(others)))
        menuCache.withLock { cache in
            if cache.db !== db { cache = MenuCache(db: db) }
            cache.menus[camera] = made
        }
        return made
    }

    private struct CameraKey: Hashable {
        var make: String
        var model: String
    }

    /// The kept lists, for one database at a time.
    private struct MenuCache: Sendable {
        var db: LensfunDatabase?
        var usable: [LensfunLens]?
        var menus: [CameraKey: Entry] = [:]
    }

    /// One camera's lists, flat (as `choices` returns them) and grouped.
    private struct Entry: Sendable {
        var fitting: [LensfunLens]
        var others: [LensfunLens]
        var menu: PickerMenu
    }

    private static let menuCache = Mutex(MenuCache())

    /// Every lens with correction data, one per model, sorted by maker then
    /// model ignoring case; worked out once per database.
    private static func usableLenses(in db: LensfunDatabase) -> [LensfunLens] {
        if let kept = menuCache.withLock({ $0.db === db ? $0.usable : nil }) { return kept }
        var seen = Set<String>()
        let unique = db.lenses
            .filter { (!$0.distortion.isEmpty || !$0.tca.isEmpty || !$0.vignetting.isEmpty) && seen.insert($0.model).inserted }
            .map { (key: ($0.maker.lowercased(), $0.model.lowercased()), lens: $0) }
            .sorted { $0.key < $1.key }
            .map(\.lens)
        menuCache.withLock { cache in
            if cache.db !== db { cache = MenuCache(db: db) }
            cache.usable = unique
        }
        return unique
    }

    /// Splits a list sorted by maker (ignoring case) into one group per
    /// maker name, in order of first appearance.
    static func groupedByMaker(_ lenses: [LensfunLens]) -> [MakerGroup] {
        var index: [String: Int] = [:]
        var groups: [MakerGroup] = []
        for lens in lenses {
            if let i = index[lens.maker] {
                groups[i].lenses.append(lens)
            } else {
                index[lens.maker] = groups.count
                groups.append(MakerGroup(maker: lens.maker, lenses: [lens]))
            }
        }
        return groups
    }
}
