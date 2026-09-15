import SwiftUI
import AppKit
import Catalog

/// Survey (N): the selected images side by side, as many as fit best in
/// a row or a grid. A click, or ← and →, focuses a pane; rating and flag
/// keys act on the focused pane; the ✕ that appears over a pane under the
/// pointer, or the / key, takes it out of the survey and deselects it.
struct SurveyView: View {
    @ObservedObject var survey: SurveyModel
    @ObservedObject var library: Library
    @ObservedObject private var prefs = AppPreferences.shared
    /// Takes a pane away (ContentView, which leaves Survey when one is left).
    let onRemove: (Int64) -> Void
    /// The library's selection changed while Survey showed.
    let onSelectionChange: () -> Void

    /// Space between panes, the width of a divider.
    private static let spacing: CGFloat = 1
    /// About the height of a caption, for choosing the arrangement.
    private static let captionHeight: CGFloat = 26

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                panes(in: geometry.size)
            }
            .background(Color(nsColor: .separatorColor))
            Divider()
            toolbar
        }
        .onChange(of: library.selectedImageIDs) { onSelectionChange() }
        .onChange(of: library.selectedImageID) { onSelectionChange() }
    }

    @ViewBuilder
    private func panes(in size: CGSize) -> some View {
        let ids = survey.panes?.ids ?? []
        let grid = SurveyPanes.grid(count: ids.count, in: size, imageAspect: survey.imageAspect,
                                    captionHeight: Self.captionHeight, spacing: Self.spacing)
        let frames = SurveyPanes.frames(count: grid.columns * grid.rows, columns: grid.columns, rows: grid.rows,
                                        in: size, spacing: Self.spacing)
        ZStack(alignment: .topLeading) {
            // A 2 × 2 grid of three leaves a cell empty.
            ForEach(ids.count..<max(ids.count, frames.count), id: \.self) { index in
                prefs.surroundColor
                    .frame(width: frames[index].width, height: frames[index].height)
                    .position(x: frames[index].midX, y: frames[index].midY)
                    .accessibilityHidden(true)
            }
            // By id, so a pane keeps its view (and its Metal layer's
            // callbacks, which name its model) when another pane goes.
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                if let model = survey.model(for: id), index < frames.count {
                    SurveyPaneView(model: model,
                                   record: library.images.first { $0.id == id },
                                   isFocused: survey.panes?.focusedID == id,
                                   position: index + 1, count: ids.count,
                                   onFocus: { focus(id) },
                                   onRemove: { onRemove(id) })
                        .frame(width: frames[index].width, height: frames[index].height)
                        .position(x: frames[index].midX, y: frames[index].midY)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func focus(_ id: Int64) {
        if survey.focus(id) { survey.writeSelection(to: library) }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Toggle("Sync", isOn: $survey.syncsView)
                .toggleStyle(.checkbox)
                .help("Zoom and pan every pane together, matched by position in each picture")
                .accessibilityLabel("Sync zoom and pan")
            Text("← → move the focus · rating and flag keys act on the focused image · \(removeKey) removes it")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Left and right arrow keys move the focus; rating and flag keys act on the focused image; "
                                    + "\(removeKey) removes it from the survey")
            Spacer()
            if let count = survey.panes?.ids.count {
                Text("\(count) images")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var removeKey: String { Shortcuts.shortcut(for: .removeFromSurvey)?.glyphs ?? "" }
}

/// One image in Survey: the image, its caption, an outline while it has
/// the keyboard, and ✕ under the pointer.
private struct SurveyPaneView: View {
    let model: EditorModel
    let record: ImageRecord?
    let isFocused: Bool
    let position: Int
    let count: Int
    let onFocus: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: 0) {
            // Any non-nil mirror hides the viewport's Open button, which a
            // pane has no use for; the pane's views are linked by the model.
            ImageViewport(model: model, mirror: model, allowsTools: false)
            Divider()
            ImageCaption(record: record)
        }
        .background(PaneMouseDownMonitor(onMouseDown: onFocus))
        .overlay {
            if isFocused {
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: contrast == .increased ? 4 : 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(contrast == .increased ? 0.9 : 0.55))
                }
                .buttonStyle(.plain)
                .padding(8)
                .help("Remove from Survey (\(Shortcuts.shortcut(for: .removeFromSurvey)?.glyphs ?? ""))")
                .accessibilityLabel("Remove \(record?.fileName ?? "image") from Survey")
                .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .animation(Motion.animation(.easeOut(duration: 0.12), reduced: reduceMotion), value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Survey pane \(position) of \(count)")
        .accessibilityValue(isFocused ? "Focused" : "")
        .accessibilityAddTraits(isFocused ? .isSelected : [])
        .accessibilityAction(named: "Focus", onFocus)
        .accessibilityAction(named: "Remove from Survey", onRemove)
    }
}

/// Tells its SwiftUI owner about mouse-downs inside its bounds without
/// taking them: the image view under it still pans, zooms and
/// double-clicks. A local event monitor rather than a gesture, which the
/// Metal view would never let through.
private struct PaneMouseDownMonitor: NSViewRepresentable {
    let onMouseDown: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onMouseDown = onMouseDown
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onMouseDown = onMouseDown
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class MonitorView: NSView {
        var onMouseDown: (() -> Void)?
        private var monitor: Any?

        /// Never the target of a click itself.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.offer(event) }
                return event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func offer(_ event: NSEvent) {
            guard let window, event.window === window, window.attachedSheet == nil else { return }
            let point = convert(event.locationInWindow, from: nil)
            if bounds.contains(point) { onMouseDown?() }
        }
    }
}
