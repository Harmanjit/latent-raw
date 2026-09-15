import Foundation
import RawCore

/// What the matcher found for an image.
public struct LensProfileMatch: Sendable, Equatable {
    public var camera: LensfunCamera
    public var lens: LensfunLens
    /// Calibration crop factor over the camera's: scales database radii
    /// onto this sensor.
    public var cropRatio: Float { lens.cropFactor / max(camera.cropFactor, 0.01) }
}

/// Finds the database entries for a camera and lens (DESIGN.md §9.2).
///
/// Cameras match by maker and model name. Lenses are harder: most files
/// carry no lens *name*, only an ID, a focal range and maximum apertures.
///
/// The rule throughout is that a wrong profile is worse than none. A
/// profile for the wrong lens "corrects" distortion and vignetting the
/// photo never had, and nothing on screen says so, whereas no profile
/// shows as "No profile found" and the manual sliders still work. So:
///
/// 1. A candidate's focal range and maximum apertures (`LensSpec`) must
///    agree with what the camera reports, to within rounding.
/// 2. Among those, the lens is picked by evidence: a Nikon lens ID the
///    table knows (`NikonLensIDs`), then the lens name the file records,
///    then Lensfun's own trailing Nikon ID number.
/// 3. With no evidence, the specs alone must leave exactly one lens.
///    Several different lenses sharing a spec (three 35mm f/1.8s on a
///    Nikon) is no match, not a guess.
///
/// Only once the *lens* is settled does the choice between its entries
/// (Lensfun often lists one lens twice, calibrated on different bodies)
/// fall to the entry with the matching crop factor and the most data.
public enum LensMatcher {
    public static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "corporation", with: "")
            .replacingOccurrences(of: "nikkor", with: "")
            .replacingOccurrences(of: "af-s", with: "")
            .replacingOccurrences(of: "[^a-z0-9.]", with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }

    public static func findCamera(make: String, model: String,
                                  in db: LensfunDatabase) -> LensfunCamera? {
        let wantMaker = normalize(make).split(separator: " ").first.map(String.init) ?? ""
        let wantModel = normalize(model)
        // Exact model spelling first, then a spelling contained in ours
        // ("Nikon D750" contains "d750"), longest match wins.
        var best: (LensfunCamera, Int)?
        for camera in db.cameras where wantMaker.isEmpty || normalize(camera.maker).hasPrefix(wantMaker) {
            for name in camera.modelNames {
                let n = normalize(name)
                guard !n.isEmpty else { continue }
                let score: Int
                if n == wantModel { score = 1000 }
                else if wantModel == normalize(camera.maker + " " + name) { score = 900 }
                else if wantModel.hasSuffix(" " + n) || wantModel == n { score = 500 + n.count }
                else { continue }
                if best == nil || score > best!.1 { best = (camera, score) }
            }
        }
        return best?.0
    }

    /// How far the camera's reported numbers may sit from the lens's
    /// nominal ones and still be the same lens. Nikon encodes focal
    /// lengths in steps of 1/24 of a doubling (about 3%), so a 17mm reads
    /// back as 17.3; apertures likewise in 1/24 EV steps, and nominal
    /// f-numbers are rounded ("f/1.8" is 1.78). A third of a stop, the
    /// gap between an f/1.8 and an f/2 lens, must not pass.
    static let focalTolerance: Float = 0.03          // relative
    static let apertureToleranceStops: Float = 0.125

    enum SpecAgreement { case agrees, unknown, conflicts }

    /// Does the lens's nominal spec agree with what the camera reported?
    /// `.unknown` when the camera reported nothing to compare, or the
    /// database's name didn't state the numbers the camera did report.
    static func specAgreement(_ lens: LensfunLens, _ identity: LensIdentity) -> SpecAgreement {
        var checked = false
        if identity.minFocal > 0 && identity.maxFocal > 0 {
            guard let nominal = lens.spec.focal else { return .unknown }
            func near(_ a: Float, _ b: Double) -> Bool {
                abs(a - Float(b)) <= focalTolerance * max(a, Float(b))
            }
            guard near(nominal.lowerBound, identity.minFocal), near(nominal.upperBound, identity.maxFocal) else {
                return .conflicts
            }
            checked = true
        }
        func stopsApart(_ a: Float, _ b: Double) -> Float { abs(2 * log2(a / Float(b))) }
        if identity.maxApertureAtMinFocal > 0 {
            guard let wide = lens.spec.apertureAtShortEnd else { return .unknown }
            guard stopsApart(wide, identity.maxApertureAtMinFocal) <= apertureToleranceStops else { return .conflicts }
            checked = true
        }
        if identity.maxApertureAtMaxFocal > 0, let longEnd = lens.spec.apertureAtLongEnd {
            guard stopsApart(longEnd, identity.maxApertureAtMaxFocal) <= apertureToleranceStops else { return .conflicts }
        }
        return checked ? .agrees : .unknown
    }

    /// Does the calibration data cover the focal length the shot was taken
    /// at? A profile measured only at 17-38mm says nothing about 55mm.
    static func coversShot(_ lens: LensfunLens, focal: Double) -> Bool {
        guard let range = lens.focalRange else { return false }
        let dbIsZoom = range.upperBound > range.lowerBound * 1.05
        // Zooms: the shot must fall within the calibrated range, with
        // slack because calibrations rarely sit at the exact extremes.
        // Primes: the focal length has to agree closely — a 90mm is not
        // a 100mm, whatever the slack says.
        let slack: Float = dbIsZoom ? 0.12 : 0.03
        let lo = range.lowerBound * (1 - slack), hi = range.upperBound * (1 + slack)
        return Float(focal) >= lo && Float(focal) <= hi
    }

    /// A name reduced to what identifies the lens: normalized, without
    /// the maker's name in front ("Canon EF 50mm…" and the maker notes'
    /// "EF 50mm…" are the same) and without Lensfun's trailing Nikon ID
    /// ("…50mm f/1.4G 160" and "…50mm f/1.4G" are the same lens).
    static func canonical(_ name: String, maker: String) -> String {
        var words = normalize(name).split(separator: " ").map(String.init)
        let makerWords = normalize(maker).split(separator: " ").map(String.init)
        if let first = makerWords.first, words.first == first { words.removeFirst() }
        let raw = name.split(separator: " ")
        if raw.count > 1, let last = raw.last, let n = Int(last), (0..<256).contains(n), words.last == String(n) {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }

    /// Whether a name the file records says which lens, rather than just
    /// restating the numbers ("17.0-55.0 mm f/2.8" says nothing new).
    static func isIdentifyingName(_ name: String) -> Bool {
        let letters = name.lowercased()
            .replacingOccurrences(of: "mm", with: "")
            .replacingOccurrences(of: "[^a-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "f", with: "")
        return letters.count >= 2
    }

    public static func findLens(camera: LensfunCamera, identity: LensIdentity, name: String,
                                focal: Double, in db: LensfunDatabase) -> LensfunLens? {
        let mounts = db.mountsAccepted(by: camera.mount)
        // Lensfun gives a compact's built-in lens a mount of its own, named
        // in lowerCamelCase ("canonG3", "sony707"); interchangeable mounts
        // are capitalised ("Nikon F AF"). Such a body can only carry that
        // lens, so there is no wrong lens to pick, and compact lens names
        // ("PowerShot G12 & compatibles") state no specs to check.
        let fixedLens = camera.mount.first?.isLowercase == true

        let onMount = db.lenses.filter { !Set($0.mounts).isDisjoint(with: mounts) && coversShot($0, focal: focal) }
        let checked = onMount.map { (lens: $0, agreement: specAgreement($0, identity)) }
        // A lens identified by ID or exact name only has to not contradict
        // the camera; anything weaker has to positively agree.
        let notConflicting = checked.filter { $0.agreement != .conflicts }.map(\.lens)
        let agreeing = checked.filter { $0.agreement == .agrees || (fixedLens && $0.agreement == .unknown) }.map(\.lens)

        func namedAs(_ lens: LensfunLens, _ wanted: [String]) -> Bool {
            let have = Set(lens.modelNames.map { canonical($0, maker: lens.maker) })
            return wanted.contains { have.contains(canonical($0, maker: lens.maker)) }
        }

        // 1. The Nikon ID table knows this lens: that entry or nothing.
        if let tableNames = NikonLensIDs.names(lensID: identity.makerLensID, nikonLensID: identity.nikonLensID) {
            // The table vouches that all the names it lists are this one lens.
            return bestEntry(of: notConflicting.filter { namedAs($0, tableNames) }, siblings: notConflicting,
                             camera: camera, identity: identity, fixedLens: fixedLens, knownToBeOneLens: true)
        }

        // 2. The file names the lens.
        let givenNames = [name, identity.makerNotesName].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let exact = notConflicting.filter { namedAs($0, givenNames) }
        if !exact.isEmpty {
            return bestEntry(of: exact, siblings: notConflicting, camera: camera, identity: identity, fixedLens: fixedLens)
        }
        let identifying = givenNames.filter(isIdentifyingName)
        if !identifying.isEmpty {
            // A near spelling ("EF50mm" for "EF 50mm") is still evidence, but
            // only with agreeing specs. If nothing matches, the named lens
            // isn't in the database: don't substitute one that merely fits.
            let partial = agreeing.filter { lens in
                let have = lens.modelNames.map { canonical($0, maker: lens.maker) }
                return identifying.contains { want in
                    let w = canonical(want, maker: lens.maker)
                    return have.contains { $0.contains(w) || w.contains($0) }
                }
            }
            return bestEntry(of: partial, siblings: agreeing, camera: camera, identity: identity, fixedLens: fixedLens)
        }

        // 3. Lensfun's trailing Nikon ID. The one-byte ID is shared by
        // unrelated lenses (the 24-120mm f/4 and the 24-70mm f/2.8E are
        // both 170), so it only counts alongside agreeing specs.
        if identity.nikonLensID != 0 {
            let byID = agreeing.filter { $0.trailingNumericID == Int(identity.nikonLensID) }
            if !byID.isEmpty {
                return bestEntry(of: byID, siblings: agreeing, camera: camera, identity: identity, fixedLens: fixedLens)
            }
        }

        // 4. Specs alone, which must single out one lens.
        guard fixedLens || (identity.minFocal > 0 && identity.maxFocal > 0) else { return nil }
        return bestEntry(of: agreeing, siblings: [], camera: camera, identity: identity, fixedLens: fixedLens)
    }

    /// The entry to use from candidates that should all be one lens, or
    /// nil if they turn out to be several different lenses.
    /// `siblings` are further entries that may describe the same lens
    /// (all those not contradicting the camera).
    static func bestEntry(of candidates: [LensfunLens], siblings: [LensfunLens], camera: LensfunCamera,
                          identity: LensIdentity, fixedLens: Bool, knownToBeOneLens: Bool = false) -> LensfunLens? {
        var pool = candidates
        guard !pool.isEmpty else { return nil }
        if fixedLens {
            // A compact's converter profiles share its mount; the file
            // can't say a converter was on, so the bare lens is the answer.
            let bare = pool.filter {
                let n = $0.model.lowercased()
                return !n.contains("converter") && !n.contains(", with ")
            }
            if !bare.isEmpty { pool = bare }
        } else {
            // A lens that sends the body an ID is electronic, so it's one
            // made for this mount, not a manual lens on an adapter (which
            // is what Lensfun's mount compatibility, M42 on Nikon F, adds).
            if identity.makerLensID != 0 || identity.nikonLensID != 0 {
                let native = pool.filter { $0.mounts.contains(camera.mount) }
                if !native.isEmpty { pool = native }
            }
            guard knownToBeOneLens || distinctLensCount(pool) == 1 else { return nil }
        }
        // The evidence may have hit only one of the lens's entries (the
        // trailing ID sits on the DX calibration of the 200-500mm, say):
        // its other entries are just as much this lens.
        let names = Set(pool.flatMap { lens in lens.modelNames.map { canonical($0, maker: lens.maker) } })
        for sibling in siblings where !pool.contains(sibling) {
            if sibling.modelNames.contains(where: { names.contains(canonical($0, maker: sibling.maker)) }) {
                pool.append(sibling)
            }
        }
        // One lens, possibly several calibrations: the one measured on this
        // format first, then the one with the most data.
        func rank(_ lens: LensfunLens) -> Int {
            (abs(lens.cropFactor - camera.cropFactor) < 0.05 ? 1_000 : 0)
                + lens.distortion.count * 10 + lens.tca.count * 5 + lens.vignetting.count
        }
        return pool.max { rank($0) < rank($1) }
    }

    /// How many different lenses the entries describe. Two entries are
    /// the same lens when any of their names agree once canonical, which
    /// ties "200-500mm F5.6 174" (English name "Nikkor AF-S 200-500mm
    /// f/5.6E ED VR") to "Nikon AF-S Nikkor 200-500mm f/5.6E ED VR".
    static func distinctLensCount(_ lenses: [LensfunLens]) -> Int {
        var groups: [Set<String>] = []
        for lens in lenses {
            let names = Set(lens.modelNames.map { canonical($0, maker: lens.maker) })
            var merged = names
            groups.removeAll { group in
                guard !group.isDisjoint(with: names) else { return false }
                merged.formUnion(group)
                return true
            }
            groups.append(merged)
        }
        return groups.count
    }

    /// Full lookup from a raw file's metadata.
    public static func match(cameraMake: String, cameraModel: String, lensName: String,
                             identity: LensIdentity, focal: Double,
                             in db: LensfunDatabase = .shared) -> LensProfileMatch? {
        guard let camera = findCamera(make: cameraMake, model: cameraModel, in: db),
              let lens = findLens(camera: camera, identity: identity, name: lensName,
                                  focal: focal, in: db) else { return nil }
        return LensProfileMatch(camera: camera, lens: lens)
    }
}
