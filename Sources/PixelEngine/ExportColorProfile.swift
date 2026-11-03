import Foundation
import CoreGraphics
import ColorKit

/// A colour space an export can be written in beyond the two the render
/// produces itself (sRGB and Display P3): Adobe RGB (1998), ProPhoto RGB,
/// or any RGB ICC profile installed on the Mac (a printer's, a lab's).
///
/// Why a conversion rather than a render in that space: the pipeline's
/// output stage knows matrix spaces with the sRGB curve, while these use
/// other curves (Adobe RGB's 2.2, ProPhoto's 1.8) or are arbitrary lookup
/// tables. So the export is rendered in the working space, Rec. 2020,
/// which holds Adobe RGB and nearly all of ProPhoto's real colours, at 16
/// bits, and ColorSync converts that into the profile; the file then
/// embeds the profile so every reader shows it right.
public struct ExportColorProfile: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case sRGB, displayP3, adobeRGB, proPhoto
        /// An ICC profile file; `iccData` holds its bytes.
        case icc
    }

    public var kind: Kind
    /// The profile's name, for showing ("Lab Glossy 300").
    public var name: String
    /// The ICC profile's bytes, for `.icc` only.
    public var iccData: Data?

    public init(kind: Kind, name: String? = nil, iccData: Data? = nil) {
        self.kind = kind
        self.name = name ?? Self.defaultName(kind)
        self.iccData = iccData
    }

    public static let sRGB = ExportColorProfile(kind: .sRGB)
    public static let displayP3 = ExportColorProfile(kind: .displayP3)
    public static let adobeRGB = ExportColorProfile(kind: .adobeRGB)
    public static let proPhoto = ExportColorProfile(kind: .proPhoto)

    static func defaultName(_ kind: Kind) -> String {
        switch kind {
        case .sRGB: "sRGB"
        case .displayP3: "Display P3"
        case .adobeRGB: "Adobe RGB (1998)"
        case .proPhoto: "ProPhoto RGB"
        case .icc: "ICC profile"
        }
    }

    /// True when the file's space isn't one the render writes directly,
    /// so ColorSync converts a Rec. 2020 render into it.
    public var needsConversion: Bool { kind == .adobeRGB || kind == .proPhoto || kind == .icc }

    /// The space the pipeline renders into for this file.
    public var renderSpace: ColorKit.OutputSpace {
        switch kind {
        case .sRGB: .sRGB
        case .displayP3: .displayP3
        case .adobeRGB, .proPhoto, .icc: .rec2020
        }
    }

    /// The colour space the file is tagged with; nil when an ICC profile
    /// can't be read or isn't an RGB profile.
    public var cgColorSpace: CGColorSpace? {
        switch kind {
        case .sRGB: return CGColorSpace(name: CGColorSpace.sRGB)
        case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3)
        case .adobeRGB: return CGColorSpace(name: CGColorSpace.adobeRGB1998)
        case .proPhoto: return CGColorSpace(name: CGColorSpace.rommrgb)
        case .icc:
            guard let iccData, let space = CGColorSpace(iccData: iccData as CFData), space.model == .rgb else { return nil }
            return space
        }
    }

    /// Matrix spaces hold the render's colours with a plain clip at their
    /// edge; a printer or paper profile's table is made for perceptual
    /// mapping, which compresses the gamut instead, as Print does.
    public var renderingIntent: CGColorRenderingIntent { kind == .icc ? .perceptual : .relativeColorimetric }

    /// The colour space a Rec. 2020 render is encoded in: Rec. 2020
    /// primaries with the sRGB curve, which is what the output stage
    /// writes for files (`RenderOutput.file`).
    static var renderedRec2020: CGColorSpace? { CGColorSpace(name: CGColorSpace.itur_2020_sRGBGamma) }

    // MARK: - Installed profiles

    /// An RGB ICC profile found in the Mac's ColorSync folders.
    public struct Installed: Sendable, Hashable, Identifiable {
        public var id: String { url.path }
        public let name: String
        public let url: URL
    }

    /// The folders macOS keeps colour profiles in, readable by every app.
    /// A profile elsewhere is chosen with Other… in the export sheet.
    public static let profileFolders = [URL(fileURLWithPath: "/Library/ColorSync/Profiles"),
                                        URL(fileURLWithPath: "/System/Library/ColorSync/Profiles")]

    /// The RGB output profiles in `folders` (and their subfolders, one
    /// level down: printer drivers install into their own), by name,
    /// leaving out what the menu offers already and display calibrations
    /// nobody exports into.
    public static func installedProfiles(in folders: [URL] = profileFolders) -> [Installed] {
        var found: [String: Installed] = [:]
        let fm = FileManager.default
        for folder in folders {
            var files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for sub in files where (try? sub.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                files += (try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil)) ?? []
            }
            for url in files where ["icc", "icm"].contains(url.pathExtension.lowercased()) {
                guard let profile = installed(at: url), found[profile.name] == nil else { continue }
                found[profile.name] = profile
            }
        }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The profile at `url` when it is an RGB profile not already offered.
    static func installed(at url: URL) -> Installed? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count < 64 << 20,
              let space = CGColorSpace(iccData: data as CFData), space.model == .rgb else { return nil }
        let name = (space.name as String?).flatMap { $0.hasPrefix("kCGColorSpace") ? nil : $0 }
            ?? url.deletingPathExtension().lastPathComponent
        let offered = ["sRGB", "Display P3", "Adobe RGB (1998)", "ProPhoto RGB", "ROMM RGB"]
        guard !offered.contains(where: { name.localizedCaseInsensitiveContains($0) }) else { return nil }
        return Installed(name: name, url: url)
    }

    /// The profile for a file at `url`, its bytes read now. Nil when the
    /// file can't be read or isn't an RGB profile.
    public static func icc(at url: URL, name: String? = nil) -> ExportColorProfile? {
        guard let data = try? Data(contentsOf: url), data.count < 64 << 20,
              let space = CGColorSpace(iccData: data as CFData), space.model == .rgb else { return nil }
        return ExportColorProfile(kind: .icc, name: name ?? url.deletingPathExtension().lastPathComponent, iccData: data)
    }
}

extension Exporter {
    /// `image` (a Rec. 2020 render, 16 bits) converted into `profile` by
    /// ColorSync at `bitsPerComponent`, and tagged with it, with
    /// `watermark` stamped in afterwards in the file's own encoding.
    static func converted(_ image: CGImage, to profile: ExportColorProfile, bitsPerComponent: Int,
                          watermark: ExportWatermark?) throws -> CGImage {
        guard let target = profile.cgColorSpace else { throw ExportColorProfileError.unusableProfile(profile.name) }
        let w = image.width, h = image.height
        let bytesPerRow = w * bitsPerComponent / 2
        var info = CGImageAlphaInfo.noneSkipLast.rawValue
        if bitsPerComponent == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        var data = Data(count: bytesPerRow * h)
        let drawn = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h,
                                          bitsPerComponent: bitsPerComponent, bytesPerRow: bytesPerRow,
                                          space: target, bitmapInfo: info) else { return false }
            context.setRenderingIntent(profile.renderingIntent)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            if let watermark, let placed = PlacedWatermark(watermark, imageWidth: w, imageHeight: h, space: target) {
                placed.composite(into: bytes, imageWidth: w, imageHeight: h, bitsPerComponent: bitsPerComponent)
            }
            return true
        }
        guard drawn, let provider = CGDataProvider(data: data as CFData),
              let result = CGImage(width: w, height: h, bitsPerComponent: bitsPerComponent,
                                   bitsPerPixel: bitsPerComponent * 4, bytesPerRow: bytesPerRow, space: target,
                                   bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
                                   shouldInterpolate: false, intent: .defaultIntent) else {
            throw ExportError.imageCreationFailed
        }
        return result
    }
}

public enum ExportColorProfileError: Error, CustomStringConvertible {
    case unusableProfile(String)

    public var description: String {
        switch self {
        case .unusableProfile(let name): "the colour profile “\(name)” can't be used (it isn't a readable RGB profile)"
        }
    }
}
