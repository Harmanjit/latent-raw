import Foundation
import os
import PixelEngine
import Catalog
import MLKit

/// What an export writes for each photo.
enum ExportFileKind: String, Codable, CaseIterable {
    /// A rendered image file: JPEG, HEIC, PNG, TIFF, AVIF or JPEG XL.
    case image
    /// A linear DNG with the edit's scene-referred part baked in (Render to DNG).
    case dng
    /// The original raw file, untouched, with an XMP sidecar beside it.
    case original

    var title: String {
        switch self {
        case .image: "Image"
        case .dng: "DNG"
        case .original: "Original + XMP"
        }
    }
}

/// Where an export's files go.
enum ExportLocation: String, Codable, CaseIterable {
    /// The folder shown in the sheet, remembered between exports.
    case chosenFolder
    /// Beside each photo, in its own folder.
    case sameAsOriginal
    /// Asked for when the export starts: for presets and Export With
    /// Previous that shouldn't always land in one place.
    case chooseLater

    var title: String {
        switch self {
        case .chosenFolder: "Chosen folder"
        case .sameAsOriginal: "Same folder as original"
        case .chooseLater: "Choose folder later"
        }
    }
}

/// A colour space chosen in the export sheet beyond sRGB and Display P3:
/// Adobe RGB, ProPhoto RGB, or an ICC profile file. The profile's bytes
/// are read when the export runs, not kept in the preset.
struct ExportProfileChoice: Codable, Hashable {
    var kind: ExportColorProfile.Kind
    var name: String
    /// An ICC profile's file.
    var path: String?
    /// For a profile outside the ColorSync folders (chosen with Other…),
    /// the sandbox's permission to read it again.
    var bookmark: Data?

    static let adobeRGB = ExportProfileChoice(kind: .adobeRGB, name: ExportColorProfile.adobeRGB.name)
    static let proPhoto = ExportProfileChoice(kind: .proPhoto, name: ExportColorProfile.proPhoto.name)

    static func icc(_ installed: ExportColorProfile.Installed) -> ExportProfileChoice {
        ExportProfileChoice(kind: .icc, name: installed.name, path: installed.url.path)
    }

    /// The profile to export into; nil when an ICC file can't be read.
    func resolved() -> ExportColorProfile? {
        switch kind {
        case .sRGB: return .sRGB
        case .displayP3: return .displayP3
        case .adobeRGB: return .adobeRGB
        case .proPhoto: return .proPhoto
        case .icc:
            guard let path else { return nil }
            return Self.iccCache.withLock { cache in
                if let cached = cache[path] { return cached }
                var url = URL(fileURLWithPath: path)
                var scoped = false
                if let bookmark, let resolved = BookmarkStore.resolveQuietly(bookmark) {
                    url = resolved.url
                    scoped = url.startAccessingSecurityScopedResource()
                }
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let profile = ExportColorProfile.icc(at: url, name: name)
                cache[path] = profile
                return profile
            }
        }
    }

    /// ICC profiles read this session, by path: the sheet asks for the
    /// settings on every redraw, and a profile file doesn't change under it.
    private static let iccCache = OSAllocatedUnfairLock<[String: ExportColorProfile?]>(initialState: [:])
}

extension ExportPreset {
    /// The export's settings for the options above the basic ones; the
    /// defaults leave `settings` exactly as it was.
    func applyOutputSettings(to s: inout ExportSettings) {
        if let profile, profile.kind != .sRGB, profile.kind != .displayP3 {
            // An ICC file that can't be read fails the export (the queue
            // reports it) rather than quietly writing sRGB.
            s.colorProfile = profile.resolved()
                ?? ExportColorProfile(kind: .icc, name: profile.name, iccData: nil)
        }
        if ppiEnabled { s.ppi = Double(min(max(ppi, 1), 9999)) }
        if sharpenEnabled { s.outputSharpening = OutputSharpening(medium: sharpenMedium, strength: sharpenStrength) }
        s.tiffBitDepth = tiffBitDepth
        s.tiffCompression = tiffCompression
    }

    /// The colour space's name as the sheet and summaries show it.
    var colorSpaceName: String {
        if let profile, profile.kind != .sRGB, profile.kind != .displayP3 { return profile.name }
        return colorSpaceIsP3 ? "Display P3" : "sRGB"
    }

    /// Image sizing when it differs from a plain long edge that never
    /// enlarges (which `maxLongEdge` already says); nil otherwise.
    var sizing: ExportSizing? {
        guard resize, sizingMode != .longEdge || !dontEnlarge else { return nil }
        return ExportSizing(mode: sizingMode, longEdge: maxLongEdge, shortEdge: shortEdge, width: boxWidth,
                            height: boxHeight, megapixels: megapixels, percentage: percentage,
                            dontEnlarge: dontEnlarge)
    }

    /// The JPEG size limit in bytes, when it is on and the format has a
    /// quality to lower.
    var sizeLimitBytes: Int? {
        sizeLimitEnabled && format.supportsQuality && fileKind == .image ? sizeLimitKB * 1024 : nil
    }

    /// Whether the export renders an image at all (DNG renders its own
    /// way; originals aren't rendered).
    var rendersImage: Bool { fileKind == .image }

    /// The app chosen to open the files after export, if it is still there.
    var openInAppURL: URL? {
        guard openInApp, let openInAppPath, FileManager.default.fileExists(atPath: openInAppPath) else { return nil }
        return URL(fileURLWithPath: openInAppPath)
    }

    /// Where a batch with this preset writes: nil when it must be asked for
    /// (Choose later, or no folder chosen yet). Same folder as original
    /// writes under the catalog's folder.
    func destination(chosen: URL?, catalogRoot: URL?) -> URL? {
        switch location {
        case .chosenFolder: chosen
        case .sameAsOriginal: catalogRoot
        case .chooseLater: nil
        }
    }
}
