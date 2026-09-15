import SwiftUI
import Catalog
import PixelEngine

/// The rendered image for one editor model, with the placeholder shown
/// when nothing is open. Shared by Develop, Loupe and both Compare panes.
///
/// `mirror` is the other Compare pane, if any. Zoom and pan reach it
/// through `EditorModel.linkedPane` as a relative view rather than from
/// here, since replaying this pane's gesture there drifts apart as soon
/// as the two images differ in size, crop or rotation.
struct ImageViewport: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var prefs = AppPreferences.shared
    var mirror: EditorModel? = nil
    /// Develop only. Viewing modes pass false so a click can never edit.
    var allowsTools: Bool = true

    var body: some View {
        ZStack {
            prefs.surroundColor

            if let device = model.device, let presenter = model.presenter,
               let preview = model.preview {
                MetalImageView(preview: preview,
                                tile: model.tile,
                                transform: model.viewport,
                                frame: model.frame,
                                presenter: presenter,
                                device: device,
                                onResize: { model.viewportDidResize(to: $0) },
                                onHeadroomChange: { model.displayHeadroomDidChange(to: $0) },
                                backgroundLevel: prefs.surroundLinear,
                                onZoom: { factor, point in
                                    model.zoom(by: factor, about: point)
                                },
                                onPan: { delta in
                                    model.pan(by: delta)
                                },
                                onDoubleClick: { point in
                                    model.toggleZoom(at: point)
                                },
                                toolActive: allowsTools && model.imageToolActive,
                                onToolBegan: { model.imageToolBegan(at: $0, exclude: $1) },
                                onToolMoved: { model.imageToolMoved(to: $0) },
                                onToolEnded: { model.imageToolEnded() })
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isImage)
                    .accessibilityLabel(model.imageTitle ?? "Image")
                    .accessibilityValue(model.showingBefore ? "\(SpokenText.zoom(model.zoomLabel)), before editing"
                                                            : SpokenText.zoom(model.zoomLabel))
                if allowsTools && model.cropToolActive {
                    CropOverlay(model: model)
                }
                if allowsTools && model.healToolActive {
                    HealOverlay(model: model)
                }
            } else {
                VStack(spacing: 12) {
                    Text(model.isReady ? "No image open" : model.setupError == nil ? "Starting…" : "Metal unavailable")
                        .foregroundStyle(.secondary)
                    if model.isReady && mirror == nil {
                        Button("Open Raw File…") { model.showOpenPanel() }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The caption under a Loupe or Compare image: name, exposure, rating
/// and flag, as the culling overlays in darktable and Lightroom show.
struct ImageCaption: View {
    let record: ImageRecord?
    var title: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            if let title {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            if let record {
                Text(record.fileName).font(.caption).lineLimit(1).truncationMode(.middle)
                Text(record.exposureLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if record.flag > 0 { Text("✓").foregroundStyle(.green) }
                if record.flag < 0 { Text("✗").foregroundStyle(.red) }
                if record.rating > 0 {
                    Text(String(repeating: "★", count: record.rating)).foregroundStyle(.yellow)
                }
            } else {
                Text("Nothing selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor))
        // One line, not scraps of glyphs: "Candidate, DSC_0107.NEF, 1/250 s, picked, 3 stars".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SpokenText.caption(title: title, name: record?.fileName,
                                               exposure: record?.exposureLine ?? "",
                                               rating: record?.rating ?? 0, flag: record?.flag ?? 0))
    }
}
