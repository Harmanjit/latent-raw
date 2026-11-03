import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PixelEngine
import Catalog

/// The export sheet's format menu: the image formats this Mac can write,
/// then DNG and the original with its sidecar.
struct ExportFormatPicker: View {
    @Binding var preset: ExportPreset

    var body: some View {
        Picker("Format", selection: selection) {
            ForEach(ExportSettings.Format.available, id: \.self) { format in
                Text(format.displayName).tag("image." + format.rawValue)
            }
            Divider()
            Text("DNG (edits baked in)").tag(ExportFileKind.dng.rawValue)
            Text("Original + XMP sidecar").tag(ExportFileKind.original.rawValue)
        }
        .help("JPEG, HEIC, PNG and TIFF everywhere; AVIF and JPEG XL when this Mac can write them. "
              + "DNG keeps raw editing room with the edit's corrections baked in. Original copies the raw file "
              + "itself, with an XMP sidecar holding its rating, keywords and edit.")
        .accessibilityLabel("Format")
    }

    private var selection: Binding<String> {
        Binding {
            preset.fileKind == .image ? "image." + preset.format.rawValue : preset.fileKind.rawValue
        } set: { tag in
            if tag.hasPrefix("image."), let format = ExportSettings.Format(rawValue: String(tag.dropFirst(6))) {
                preset.fileKind = .image
                preset.format = format
            } else if let kind = ExportFileKind(rawValue: tag) {
                preset.fileKind = kind
            }
        }
    }
}

/// What DNG and Original exports do, in place of the image settings
/// they don't use.
struct ExportKindNote: View {
    let kind: ExportFileKind

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var text: String {
        switch kind {
        case .image:
            ""
        case .dng:
            "A linear DNG at full size, cropped and upright: white balance, exposure, noise reduction, lens "
                + "corrections, healing and masks are baked in. The look (tone, colour, presence, sharpening) "
                + "is left for the DNG's own edit, so it opens with Latent's default look."
        case .original:
            "The raw file itself, unchanged, with an .xmp sidecar beside it holding the rating, label, "
                + "keywords and Latent's edit. Other apps read the rating, label and keywords."
        }
    }
}

/// JPEG's size limit and a TIFF's bit depth and compression.
struct ExportFileOptionsSection: View {
    @Binding var preset: ExportPreset

    var body: some View {
        if preset.format.supportsQuality {
            HStack {
                Toggle("Limit file size to", isOn: $preset.sizeLimitEnabled)
                    .help("Lowers the quality, image by image, until the file fits. A photo that won't fit even at "
                          + "the lowest quality is reported, not written.")
                    .accessibilityHint("Lowers the quality of each file until it is no larger than the size given.")
                TextField("KB", value: $preset.sizeLimitKB, format: .number).frame(width: 70)
                    .disabled(!preset.sizeLimitEnabled)
                    .accessibilityLabel("File size limit in kilobytes")
                Text("KB").foregroundStyle(.secondary).accessibilityHidden(true)
                Spacer()
            }
        }
        if preset.format == .tiff {
            HStack {
                Picker("Bit depth", selection: $preset.tiffBitDepth) {
                    Text("16 bits per channel").tag(16)
                    Text("8 bits per channel").tag(8)
                }
                .frame(width: 240)
                .help("16 bits keeps smooth gradients for further editing; 8 bits makes a file half the size.")
                Picker("Compression", selection: $preset.tiffCompression) {
                    ForEach(TIFFCompression.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .frame(width: 190)
                .help("All three are lossless. ZIP is usually smallest, LZW is read by the most software, "
                      + "None is quickest to open.")
            }
        }
    }
}

/// The colour space menu: sRGB and Display P3 (rendered directly), Adobe
/// RGB and ProPhoto, the Mac's installed RGB profiles, and Other….
struct ExportColorSpacePicker: View {
    @Binding var preset: ExportPreset
    @State private var installed: [ExportColorProfile.Installed] = []

    var body: some View {
        Picker("Colour space", selection: selection) {
            Text("sRGB (safe everywhere)").tag("srgb")
            Text("Display P3 (wider, modern screens)").tag("p3")
            Text("Adobe RGB (1998) (print labs)").tag("adobe")
            Text("ProPhoto RGB (widest, for editing)").tag("prophoto")
            if let profile = preset.profile, profile.kind == .icc,
               !installed.contains(where: { $0.url.path == profile.path }) {
                Text(profile.name).tag("icc:" + (profile.path ?? ""))
            }
            if !installed.isEmpty {
                Divider()
                ForEach(installed) { Text($0.name).tag("icc:" + $0.url.path) }
            }
            Divider()
            Text("Other…").tag("other")
        }
        .help("sRGB for the web and anyone's screen. Adobe RGB when a print lab asks for it. ProPhoto RGB for "
              + "16-bit files going on to another editor. A printer or paper profile converts with perceptual "
              + "intent. Every file embeds its profile.")
        .task { installed = await Task.detached { ExportColorProfile.installedProfiles() }.value }
        if preset.profile?.kind == .proPhoto, preset.fileKind == .image, preset.settings.bitsPerComponent == 8 {
            Label("ProPhoto RGB in 8 bits can band in smooth skies; use a 16-bit TIFF.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        }
        if preset.hdrGainMap, preset.format.supportsGainMap, preset.settings.colorProfile?.needsConversion == true {
            Text("No HDR gain map in this colour space: the map describes sRGB or Display P3.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var selection: Binding<String> {
        Binding {
            switch preset.profile?.kind {
            case .adobeRGB: "adobe"
            case .proPhoto: "prophoto"
            case .icc: "icc:" + (preset.profile?.path ?? "")
            default: preset.colorSpaceIsP3 ? "p3" : "srgb"
            }
        } set: { tag in
            switch tag {
            case "srgb": preset.profile = nil; preset.colorSpaceIsP3 = false
            case "p3": preset.profile = nil; preset.colorSpaceIsP3 = true
            case "adobe": preset.profile = .adobeRGB
            case "prophoto": preset.profile = .proPhoto
            case "other": chooseOther()
            default:
                let path = String(tag.dropFirst(4))
                if let match = installed.first(where: { $0.url.path == path }) {
                    preset.profile = .icc(match)
                }
            }
        }
    }

    private func chooseOther() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "icc") ?? .data, UTType(filenameExtension: "icm") ?? .data]
        panel.directoryURL = URL(fileURLWithPath: "/Library/ColorSync/Profiles")
        panel.message = "Choose an RGB ICC profile to export into"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let profile = ExportColorProfile.icc(at: url) else {
            let alert = NSAlert()
            alert.messageText = "“\(url.lastPathComponent)” can't be used"
            alert.informativeText = "Exports need an RGB profile. CMYK and grey profiles aren't supported."
            alert.runModal()
            return
        }
        preset.profile = ExportProfileChoice(kind: .icc, name: profile.name, path: url.path,
                                             bookmark: BookmarkStore.bookmark(for: url))
    }
}

/// Image Sizing: whether to resize, how (long or short edge, a box,
/// megapixels, a percentage), Don't Enlarge, and the resolution written.
struct ExportSizingSection: View {
    @Binding var preset: ExportPreset

    var body: some View {
        Toggle("Resize to fit", isOn: $preset.resize)
            .help("Off writes the photo at its full cropped size.")
        if preset.resize {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Picker("Fit", selection: $preset.sizingMode) {
                        ForEach(ExportSizing.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .frame(width: 200)
                    .help("Long and short edge size one side. Width & height fits inside a box as given; Dimensions "
                          + "fits inside it whichever way the photo is turned. Megapixels and Percentage scale the "
                          + "whole picture.")
                    values
                    Spacer()
                }
                Toggle("Don't enlarge", isOn: $preset.dontEnlarge)
                    .help("A photo already smaller than the size asked for is written at its own size rather than "
                          + "enlarged.")
            }
            .padding(.leading, 20)
        }
        HStack {
            Toggle("Resolution", isOn: $preset.ppiEnabled)
                .help("The pixels per inch written into the file, which sets its print size in other apps. It "
                      + "changes no pixel; matte and glossy sharpening use it.")
            TextField("ppi", value: $preset.ppi, format: .number).frame(width: 60)
                .disabled(!preset.ppiEnabled)
                .accessibilityLabel("Resolution in pixels per inch")
            Text("ppi").foregroundStyle(.secondary).accessibilityHidden(true)
            Spacer()
            ForEach([240, 300, 360], id: \.self) { n in
                Button("\(n)") { preset.ppi = n; preset.ppiEnabled = true }.controlSize(.small)
                    .accessibilityLabel("\(n) pixels per inch")
            }
        }
    }

    @ViewBuilder private var values: some View {
        switch preset.sizingMode {
        case .longEdge:
            number($preset.maxLongEdge, "px", label: "Long edge in pixels")
            ForEach([1024, 2048, 4096], id: \.self) { n in
                Button("\(n)") { preset.maxLongEdge = n }.controlSize(.small).accessibilityLabel("\(n) pixels")
            }
        case .shortEdge:
            number($preset.shortEdge, "px", label: "Short edge in pixels")
        case .widthHeight, .dimensions:
            number($preset.boxWidth, "×", label: preset.sizingMode == .widthHeight ? "Width in pixels" : "First dimension in pixels")
            number($preset.boxHeight, "px", label: preset.sizingMode == .widthHeight ? "Height in pixels" : "Second dimension in pixels")
        case .megapixels:
            TextField("MP", value: $preset.megapixels, format: .number).frame(width: 60)
                .accessibilityLabel("Megapixels")
            Text("MP").foregroundStyle(.secondary).accessibilityHidden(true)
        case .percentage:
            TextField("%", value: $preset.percentage, format: .number).frame(width: 60)
                .accessibilityLabel("Percentage of full size")
            Text("%").foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }

    private func number(_ value: Binding<Int>, _ unit: String, label: String) -> some View {
        HStack(spacing: 4) {
            TextField("px", value: value, format: .number).frame(width: 64).accessibilityLabel(label)
            Text(unit).foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }
}

/// Output Sharpening: Screen, Matte or Glossy paper, at three amounts.
struct ExportSharpeningSection: View {
    @Binding var preset: ExportPreset

    var body: some View {
        HStack {
            Toggle("Sharpen for", isOn: $preset.sharpenEnabled)
                .help("A last sharpen for where the file is going, after the resize. Screen is light; matte paper "
                      + "needs the most, glossy a little less, both scaled to the resolution. The edit's own "
                      + "sharpening is unchanged.")
                .accessibilityHint("Adds output sharpening for a screen or for matte or glossy paper.")
            Picker("Medium", selection: $preset.sharpenMedium) {
                ForEach(OutputSharpening.Medium.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden().frame(width: 130).disabled(!preset.sharpenEnabled)
            .accessibilityLabel("Sharpen for")
            Picker("Amount", selection: $preset.sharpenStrength) {
                ForEach(OutputSharpening.Strength.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .frame(width: 160).disabled(!preset.sharpenEnabled)
            .accessibilityLabel("Sharpening amount")
            Spacer()
        }
    }
}

/// Which metadata the file carries.
struct ExportMetadataSection: View {
    @Binding var preset: ExportPreset

    var body: some View {
        Picker("Metadata", selection: level) {
            Text("None").tag(ExportMetadataLevel?.none)
            ForEach(ExportMetadataLevel.allCases.reversed(), id: \.self) { Text($0.title).tag(Optional($0)) }
        }
        .frame(width: 330)
        .help("All: the camera, lens, exposure, date, IPTC fields, keywords and rating. All except camera info "
              + "leaves out the camera, lens, settings and serial numbers. The copyright levels write only the "
              + "copyright notice, with or without the creator's name and contact details.")
        Toggle("Include location", isOn: $preset.includeLocation)
            .disabled(!preset.includeMetadata || !preset.metadataLevel.allowsLocation)
            .padding(.leading, 20)
            .accessibilityHint(ExportPreset.locationHelp)
            .help(ExportPreset.locationHelp)
    }

    private var level: Binding<ExportMetadataLevel?> {
        Binding {
            preset.includeMetadata ? preset.metadataLevel : nil
        } set: { value in
            preset.includeMetadata = value != nil
            if let value { preset.metadataLevel = value }
        }
    }
}

/// Where the files go: the location menu, a subfolder, and the folder
/// itself when it is a chosen one.
struct ExportLocationSection: View {
    @Binding var preset: ExportPreset
    @Binding var destination: URL?

    var body: some View {
        Picker("Export to", selection: $preset.location) {
            ForEach(ExportLocation.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .frame(width: 330)
        .help("Same folder as original puts each file beside its photo. Choose folder later asks when the export "
              + "starts, which suits presets and Export With Previous.")
        if preset.location == .chosenFolder {
            HStack {
                Text(destination?.path ?? "choose a folder…").lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(destination == nil ? .secondary : .primary)
                    .accessibilityLabel("Destination")
                    .accessibilityValue(destination?.path ?? "none chosen")
                Spacer()
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                    panel.message = "Folder to export into"
                    if panel.runModal() == .OK, let url = panel.url {
                        destination = url
                        BookmarkStore.save(url, key: BookmarkStore.exportDestination)
                    }
                }
            }
        }
        HStack {
            Text("Subfolder")
            TextField("none", text: $preset.subfolder).frame(width: 180)
                .accessibilityLabel("Put in subfolder")
                .help("A folder made inside the destination (or inside each photo's folder) for these files. "
                      + "Leave empty for none.")
            Spacer()
        }
    }
}

/// What happens when the export is done: Finder, and another app.
struct ExportAfterSection: View {
    @Binding var preset: ExportPreset

    var body: some View {
        Toggle("Show in Finder when done", isOn: $preset.revealWhenDone)
        HStack {
            Toggle("Open in", isOn: $preset.openInApp)
                .disabled(preset.openInAppPath == nil)
                .help("Opens the exported files in this app when the export is done.")
            Text(appName ?? "no app chosen").foregroundStyle(preset.openInAppPath == nil ? .secondary : .primary)
                .accessibilityLabel("Application")
                .accessibilityValue(appName ?? "none chosen")
            Spacer()
            Button("Choose App…") { chooseApp() }
                .accessibilityHint("Picks the application the exported files open in.")
        }
    }

    private var appName: String? {
        preset.openInAppPath.map { FileManager.default.displayName(atPath: $0) }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Application to open exported files in"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preset.openInAppPath = url.path
        preset.openInApp = true
    }
}

/// Multi-batch export: tick saved presets to export the selection once
/// with each, in one run.
struct ExportMultiBatchSection: View {
    let presets: [NamedExportPreset]
    @Binding var chosen: Set<UUID>
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                if presets.isEmpty {
                    Text("Save presets first; each ticked preset then writes its own set of files.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(presets) { saved in
                    Toggle(saved.name, isOn: Binding {
                        chosen.contains(saved.id)
                    } set: { on in
                        if on { chosen.insert(saved.id) } else { chosen.remove(saved.id) }
                    })
                    .accessibilityHint("Exports the selection with this preset as well.")
                }
                if !chosen.isEmpty {
                    Text("The ticked presets are exported one after another, each into a subfolder of the "
                         + "destination named after it (or as the preset says, when it chooses its own place). "
                         + "The settings below aren't used.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
        } label: {
            Text(chosen.isEmpty ? "Export with several presets" : "Export with \(chosen.count) preset\(chosen.count == 1 ? "" : "s")")
                .help("Multi-batch: one run writes the selection once per ticked preset, say a web JPEG and a "
                      + "print TIFF.")
        }
    }

    /// The batches for the ticked presets, in the menu's order. Presets
    /// writing to a chosen folder go into `<destination>/<preset name>`;
    /// Choose-later ones ask now. Nil when a folder that was needed is
    /// missing or a Choose-later panel was cancelled.
    static func batches(for presets: [NamedExportPreset], chosen: Set<UUID>, destination: URL?,
                        choose: (String) -> URL? = { ExportQueue.chooseFolder(for: $0) }) -> [ExportBatch]? {
        var batches: [ExportBatch] = []
        for saved in presets where chosen.contains(saved.id) {
            let folder: URL
            switch saved.preset.location {
            case .chosenFolder:
                guard let destination else { return nil }
                let name = ExportBatchPlanner.Options.cleanSubfolder(saved.name)
                folder = name.isEmpty ? destination : destination.appendingPathComponent(name, isDirectory: true)
            case .sameAsOriginal:
                // The queue writes beside each photo; the folder isn't used.
                folder = destination ?? URL(fileURLWithPath: "/", isDirectory: true)
            case .chooseLater:
                guard let asked = choose(saved.name) else { return nil }
                folder = asked
            }
            batches.append(ExportBatch(preset: saved.preset, destination: folder, name: saved.name))
        }
        return batches
    }
}
