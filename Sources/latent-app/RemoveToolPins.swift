import SwiftUI
import simd
import PixelEngine

/// When the Remove tool draws its pins (the patches' circles, strokes and
/// source links), Lightroom's Tool Overlay setting: Auto while the pointer
/// is over the image, Always, only the Selected ones, or Never. Kept
/// across launches. Drawing only: a hidden patch still heals, and a click
/// still grabs it.
enum HealToolOverlay: String, CaseIterable, Identifiable, Sendable {
    case auto, always, selected, never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .always: "Always"
        case .selected: "Selected"
        case .never: "Never"
        }
    }

    static let defaultsKey = "latent.healToolOverlay"

    /// The saved choice; Always (how the tool has always drawn) when none.
    static var saved: HealToolOverlay {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(HealToolOverlay.init(rawValue:)) ?? .always
    }

    func save() { UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey) }

    /// Which of `count` patches to draw, in order, given the selected ones.
    func visibleIndices(count: Int, selected: Set<Int>, pointerOverImage: Bool) -> [Int] {
        switch self {
        case .always: Array(0..<max(count, 0))
        case .auto: pointerOverImage ? Array(0..<max(count, 0)) : []
        case .selected: selected.filter { $0 >= 0 && $0 < count }.sorted()
        case .never: []
        }
    }
}

extension HealPatch.Mode {
    /// The mode's name in the panel and the pin list.
    var title: String {
        switch self {
        case .heal: "Heal"
        case .clone: "Clone"
        case .remove: "Remove"
        }
    }
}

extension EditorModel {
    // MARK: - Opacity

    /// Opacity of the selected patch (or the next one's). Setting it sets
    /// every selected patch's, and the next patch's.
    var activeHealOpacity: Float {
        get { selectedHeal?.effectiveOpacity ?? healOpacity }
        set {
            let v = min(max(newValue, 0), 1)
            healOpacity = v
            let ids = selectedHealIDs
            guard !ids.isEmpty else { return }
            var heals = parameters.heals
            // Fully opaque is stored as no opacity, so the patch encodes as
            // it did before Opacity existed.
            for i in heals.indices where ids.contains(heals[i].id) { heals[i].opacity = v < 1 ? v : nil }
            if heals != parameters.heals { parameters.heals = heals }
        }
    }

    /// `patch` with the next patch's opacity.
    func stampingOpacity(_ patch: HealPatch) -> HealPatch {
        var p = patch
        p.opacity = healOpacity < 1 ? healOpacity : nil
        return p
    }

    // MARK: - Pin selection

    /// The selected patches: the one the sliders edit and any selected
    /// alongside it, ids that are still in the edit only.
    var selectedHealIDs: Set<UUID> {
        var ids = healPinSelection
        if let h = selectedHeal { ids.insert(h.id) }
        guard !ids.isEmpty else { return [] }
        return ids.intersection(parameters.heals.map(\.id))
    }

    var selectedHealIndices: Set<Int> {
        let ids = selectedHealIDs
        return Set(parameters.heals.indices.filter { ids.contains(parameters.heals[$0].id) })
    }

    /// Selects pin `index`, or with `extending` adds it to the selection or
    /// takes it out (⌘- or ⇧-click in the pin list).
    func selectHealPin(_ index: Int, extending: Bool) {
        guard parameters.heals.indices.contains(index) else { return }
        let id = parameters.heals[index].id
        guard extending else {
            selectedHealIndex = index
            healPinSelection = []
            return
        }
        var ids = selectedHealIDs
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        // The sliders edit the pin just added, else the first still selected.
        let primary = ids.contains(id) ? index : parameters.heals.indices.first { ids.contains(parameters.heals[$0].id) }
        selectedHealIndex = primary
        healPinSelection = primary.map { ids.subtracting([parameters.heals[$0].id]) } ?? []
    }

    func selectAllHeals() {
        guard !parameters.heals.isEmpty else { return }
        if selectedHealIndex == nil || selectedHealIndex! >= parameters.heals.count {
            selectedHealIndex = parameters.heals.count - 1
        }
        healPinSelection = Set(parameters.heals.map(\.id))
    }

    /// Deletes the patches with `ids` as one edit, and the selection.
    func deleteHeals(_ ids: Set<UUID>) {
        let kept = parameters.heals.filter { !ids.contains($0.id) }
        let removed = parameters.heals.count - kept.count
        healPinSelection = []
        selectedHealIndex = nil
        guard removed > 0 else { return }
        parameters.heals = kept
        status = removed == 1 ? "Deleted 1 spot" : "Deleted \(removed) spots"
    }

    func deleteHeal(at index: Int) {
        guard parameters.heals.indices.contains(index) else { return }
        deleteHeals([parameters.heals[index].id])
    }

    // MARK: - Option-drag marquee

    /// Where a stored patch point (raw grid) shows on screen, in the
    /// drawable's pixels as the tool's clicks are: through the lens map,
    /// the crop frame and the viewport, as HealOverlay draws it.
    func healScreenPoint(_ raw: SIMD2<Float>) -> CGPoint {
        let n = outputNormalized(raw)
        let sensor = CGPoint(x: CGFloat(n.x) * sensorSize.width, y: CGFloat(n.y) * sensorSize.height)
        let canvas = frame.canvasPoint(fromSensorPoint: sensor)
        return viewport.screenPoint(forSensorPoint: canvas, drawableSize: drawableSize)
    }

    /// The Option-drag ended: every spot whose pin (its target's centre, a
    /// stroke's start) is inside the marquee is deleted, as one edit. An
    /// Option-click, with no real drag, deletes the spot under it.
    func finishHealMarquee(from start: CGPoint) {
        let rect = healMarquee ?? CGRect(origin: start, size: .zero)
        healMarquee = nil
        if rect.width < 4, rect.height < 4 {
            if let hit = hitHeal(rawNormalized(sensorNormalized(start))) {
                deleteHeals([parameters.heals[hit.index].id])
            }
            return
        }
        let ids = parameters.heals.filter { rect.contains(healScreenPoint($0.target)) }.map(\.id)
        guard !ids.isEmpty else { status = "No spots inside the marquee"; return }
        deleteHeals(Set(ids))
    }
}

/// The Remove tool's pins: one row a patch (number, mode, shape and any
/// opacity below 100%), click to select, ⌘- or ⇧-click to select several,
/// × to delete; Select All and Delete All underneath. Rows follow the
/// order patches apply in.
struct HealPinList: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let heals = model.parameters.heals
        let selected = model.selectedHealIndices
        VStack(alignment: .leading, spacing: 4) {
            if !heals.isEmpty {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(Array(heals.enumerated()), id: \.element.id) { i, patch in
                            row(i, patch, selected: selected.contains(i))
                        }
                    }
                }
                .frame(height: min(CGFloat(heals.count) * 19, 133))
            }
            HStack(spacing: 6) {
                Text(heals.isEmpty ? "No patches. Click a dust spot or blemish to remove it."
                     : selected.count > 1 ? "\(heals.count) patches, \(selected.count) selected"
                     : "\(heals.count) patch\(heals.count == 1 ? "" : "es")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if !heals.isEmpty {
                    Button("Select All") {
                        model.healToolActive = true
                        model.selectAllHeals()
                    }
                    .help("Select every patch, to set their Opacity together or delete them (⌫)")
                    Button("Delete All") { model.clearHeals() }
                        .help("Delete every spot patch; Option-drag on the image deletes the spots inside a marquee")
                        .accessibilityLabel("Delete all spot patches")
                }
            }
            .controlSize(.mini)
        }
    }

    private func row(_ i: Int, _ patch: HealPatch, selected: Bool) -> some View {
        let opacity = patch.effectiveOpacity
        let shape = patch.objectMask != nil ? "Object" : patch.isStroke ? "Brush" : "Spot"
        return HStack(spacing: 6) {
            Text("\(i + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
            Text(patch.mode.title)
            Text(shape).foregroundStyle(.secondary)
            if opacity < 1 {
                Text(String(format: "%.0f%%", opacity * 100)).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.deleteHeal(at: i) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Delete this patch")
                .accessibilityLabel("Delete patch \(i + 1)")
        }
        .font(.caption)
        .padding(.horizontal, 4)
        .frame(height: 18)
        .background(selected ? Color.accentColor.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 3))
        .contentShape(Rectangle())
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            model.healToolActive = true
            model.selectHealPin(i, extending: flags.contains(.command) || flags.contains(.shift))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Patch \(i + 1), \(patch.mode.title), \(shape)"
                            + (opacity < 1 ? String(format: ", opacity %.0f%%", opacity * 100) : ""))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Delete") { model.deleteHeal(at: i) }
    }
}

/// Tool Overlay and Visualise Spots for the Remove tool.
struct HealOverlayOptions: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 8) {
            Text("Tool Overlay").font(.subheadline).accessibilityHidden(true)
            Picker("Tool Overlay", selection: $model.healToolOverlay) {
                ForEach(HealToolOverlay.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 96)
            .help("When the patches are drawn: Auto while the pointer is over the image, Always, only the Selected ones, or Never. Hidden patches still apply")
            Spacer()
            Toggle("Visualise Spots", isOn: $model.visualiseSpots)
                .toggleStyle(.checkbox)
                .help("Show faint dark spots as dark marks on a light image, on screen only; Contrast is under Sensor Dust")
        }
        .controlSize(.small)
        .disabled(!model.hasImage)
    }
}
