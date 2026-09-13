import SwiftUI
import Catalog
import PixelEngine

/// The rendered image for one editor model, with the placeholder shown
/// when nothing is open. Shared by Develop, Loupe and both Compare panes.
///
/// `mirror` receives every zoom, pan and double-click this pane gets, so
/// two side-by-side panes move together. It's a one-way tap: the mirror's
/// own view mirrors back to this one, so both are always symmetric.
struct ImageViewport: View {
    @ObservedObject var model: EditorModel
    var mirror: EditorModel? = nil

    var body: some View {
        ZStack {
            Color(white: 0.12)

            if let device = model.device, let presenter = model.presenter,
               let preview = model.preview {
                MetalImageView(preview: preview,
                                tile: model.tile,
                                transform: model.viewport,
                                rotation: model.rotation,
                                sensorSize: model.sensorSize,
                                presenter: presenter,
                                device: device,
                                onResize: { model.viewportDidResize(to: $0) },
                                onHeadroomChange: { model.displayHeadroomDidChange(to: $0) },
                                backgroundLevel: model.backgroundLevel,
                                onZoom: { factor, point in
                                    model.zoom(by: factor, about: point)
                                    mirror?.zoom(by: factor, about: point)
                                },
                                onPan: { delta in
                                    model.pan(by: delta)
                                    mirror?.pan(by: delta)
                                },
                                onDoubleClick: { point in
                                    model.toggleZoom(at: point)
                                    mirror?.toggleZoom(at: point)
                                },
                                toolActive: model.maskToolActive,
                                onToolBegan: { point, exclude in
                                    model.promptModifierExclude = exclude
                                    model.maskToolBegan(at: point)
                                },
                                onToolMoved: { model.maskToolMoved(to: $0) },
                                onToolEnded: { model.maskToolEnded() })
            } else {
                VStack(spacing: 12) {
                    Text(model.isReady ? "No image open" : "Metal unavailable")
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
    }
}
