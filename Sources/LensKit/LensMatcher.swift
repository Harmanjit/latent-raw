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
/// So candidates are first filtered by mount and by those specs, then
/// ranked — an exact name match wins, then Nikon's numeric ID (which the
/// database encodes as a trailing number on some model names), then the
/// entry with the most calibration data.
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

    public static func findLens(camera: LensfunCamera, identity: LensIdentity, name: String,
                                focal: Double, in db: LensfunDatabase) -> LensfunLens? {
        let mounts = db.mountsAccepted(by: camera.mount)
        let wantName = normalize(name)
        let wantMakerNotes = normalize(identity.makerNotesName)

        func specsFit(_ lens: LensfunLens) -> Bool {
            guard let range = lens.focalRange else { return false }
            let dbIsZoom = range.upperBound > range.lowerBound * 1.05
            // Zooms: the shot must fall within the calibrated range, with
            // slack because calibrations rarely sit at the exact extremes.
            // Primes: the focal length has to agree closely — a 90mm is not
            // a 100mm, whatever the slack says.
            let slack: Float = dbIsZoom ? 0.12 : 0.03
            let lo = range.lowerBound * (1 - slack), hi = range.upperBound * (1 + slack)
            guard Float(focal) >= lo && Float(focal) <= hi else { return false }
            if identity.minFocal > 0 && identity.maxFocal > 0 {
                // Prime vs zoom must agree, and the ranges must overlap.
                if identity.isZoom != dbIsZoom { return false }
                if Float(identity.minFocal) > hi || Float(identity.maxFocal) < lo { return false }
            }
            return true
        }

        let candidates = db.lenses.filter { !Set($0.mounts).isDisjoint(with: mounts) && specsFit($0) }

        // Lensfun often lists the same lens twice: once with a numeric ID
        // suffix (calibrated on one body) and once by plain name. An ID hit
        // on either should count for both, so the ranking below can then
        // prefer whichever was calibrated on the matching format.
        var idMatchedNames: Set<String> = []
        if identity.nikonLensID != 0 {
            for lens in candidates where lens.trailingNumericID == Int(identity.nikonLensID) {
                idMatchedNames.formUnion(lens.modelNames.map(normalize))
                idMatchedNames.insert(normalize(lens.model.split(separator: " ").dropLast().joined(separator: " ")))
            }
        }

        var scored: [(LensfunLens, Int)] = []
        for lens in candidates {
            var score = 0
            let names = lens.modelNames.map(normalize)
            if !wantName.isEmpty, names.contains(wantName) { score += 10_000 }
            else if !wantName.isEmpty, names.contains(where: { $0.contains(wantName) || wantName.contains($0) }) { score += 5_000 }
            if !wantMakerNotes.isEmpty, names.contains(where: { $0.contains(wantMakerNotes) }) { score += 5_000 }
            if !idMatchedNames.isDisjoint(with: names) { score += 8_000 }
            // Maximum aperture agreement (one third of a stop).
            if identity.maxApertureAtMinFocal > 0, let a = apertureHint(lens),
               abs(log2(Float(identity.maxApertureAtMinFocal) / a)) < 0.2 { score += 1_000 }
            // More calibration is better, and native crop factor beats a
            // profile measured on another format.
            score += lens.distortion.count * 10 + lens.tca.count * 5 + lens.vignetting.count
            if abs(lens.cropFactor - camera.cropFactor) < 0.05 { score += 500 }
            scored.append((lens, score))
        }
        return scored.max { $0.1 < $1.1 }?.0
    }

    /// The widest aperture the database measured vignetting at — a proxy
    /// for the lens's maximum aperture, which the database doesn't state.
    static func apertureHint(_ lens: LensfunLens) -> Float? {
        lens.vignetting.map(\.aperture).filter { $0 > 0 }.min()
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
