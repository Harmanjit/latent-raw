import Foundation
import simd

/// Linked mask components: a component that uses another mask of the same
/// edit as it is now (darktable's "use a drawn mask from another module").
///
/// The link stores only the other mask's id (`MaskComponentSource.mask`).
/// When the locals are packed for the colour kernel (`LocalsGPUPlan`), the
/// linked mask's shape, components, Invert mask and ranges are copied in
/// place of the link as a group, so the kernel evaluates nothing new:
/// it builds the group in its own accumulator and joins the result to the
/// mask so far with the link's mode, exactly as the linked mask would be
/// built on its own. Editing the linked mask therefore changes every mask
/// that uses it on the next render. Brush and model pixels are shared too:
/// the linked mask's elements already have their slices.
///
/// Links are one level deep: a mask that uses another cannot itself be
/// used, and a link to itself, to a mask that is gone or to one with links
/// of its own packs as nothing. The panel's menu never offers those, nor a
/// mask whose group would take the mask past `MaskComponent.maximumPerMask`
/// packed entries.
enum MaskLinks {
    // Flags in `MaskComponentGPU.info.z`, above bit 0 (the component's
    // own Invert). The colour kernel reads them in `combinedLocalMask`.

    /// This entry starts a group: the mask so far is set aside, with this
    /// entry's mode, and the group starts from this entry's value.
    static let groupStart: Int32 = 2
    /// After this entry, the group is inverted (the linked mask's Invert
    /// mask, which comes before its ranges).
    static let groupInvert: Int32 = 4
    /// After this entry, the group closes: it joins the set-aside mask
    /// with the mode the start entry carried.
    static let groupEnd: Int32 = 8
    /// At the close, the group is inverted first (the link's own Invert).
    static let groupEndInvert: Int32 = 16
    /// A hue range component, as a local's own `hueRange` (type 7).
    static let hueRangeType: Int32 = 7

    /// The packed entries for `local`'s components, each linked mask
    /// inlined, stopping at the first component whose entries would take
    /// the total past `limit` (components after it depend on it).
    static func packedComponents(of local: LocalAdjustment, in locals: [LocalAdjustment],
                                 slices: [UUID: Int32], limit: Int) -> [MaskComponentGPU] {
        var out: [MaskComponentGPU] = []
        for component in local.components {
            let entries: [MaskComponentGPU]
            if let id = component.linkedMaskID {
                guard let target = target(id, of: local, in: locals) else { continue }
                entries = group(target, link: component, slices: slices)
            } else {
                entries = [MaskComponentGPU(component, slice: slices[component.id] ?? -1)]
            }
            if out.count + entries.count > limit { break }
            out += entries
        }
        return out
    }

    /// The mask a link in `local` uses, when the link is usable.
    static func target(_ id: UUID, of local: LocalAdjustment, in locals: [LocalAdjustment]) -> LocalAdjustment? {
        guard id != local.id, let target = locals.first(where: { $0.id == id }),
              !target.hasLinkedComponents else { return nil }
        return target
    }

    /// The linked mask as a group of packed entries.
    static func group(_ target: LocalAdjustment, link: MaskComponent, slices: [UUID: Int32]) -> [MaskComponentGPU] {
        var start = MaskComponentGPU(MaskComponent(id: target.id, mode: link.mode, source: .shape(target.shape),
                                                   invert: target.invert),
                                     slice: slices[target.id] ?? -1)
        start.info.z |= groupStart
        var entries = [start]
        entries += target.components.map { MaskComponentGPU($0, slice: slices[$0.id] ?? -1) }
        if target.invertMask { entries[entries.count - 1].info.z |= groupInvert }
        if let band = target.luminanceRange {
            entries.append(MaskComponentGPU(MaskComponent(mode: .intersect, source: .luminance(band)), slice: -1))
        }
        if let hue = target.hueRange {
            var entry = MaskComponentGPU()
            entry.geometry0 = SIMD4(hue.centre, hue.width, hue.minimumSaturation, 0)
            entry.info = SIMD4(hueRangeType, -1, 0, MaskCombineMode.intersect.gpuCode)
            entries.append(entry)
        }
        entries[entries.count - 1].info.z |= groupEnd | (link.invert ? groupEndInvert : 0)
        return entries
    }

    /// How many packed entries a linked mask takes.
    static func groupSize(_ target: LocalAdjustment) -> Int {
        1 + target.components.count + (target.luminanceRange == nil ? 0 : 1) + (target.hueRange == nil ? 0 : 1)
    }
}

extension LocalAdjustment {
    /// Whether any component uses another mask.
    public var hasLinkedComponents: Bool { components.contains { $0.linkedMaskID != nil } }
}

extension EditParameters {
    /// The packed entries `locals[index]`'s components take, a linked mask
    /// counting its whole group and an unusable link nothing.
    public func packedComponentCount(ofLocal index: Int) -> Int {
        guard locals.indices.contains(index) else { return 0 }
        let local = locals[index]
        return local.components.reduce(0) { count, c in
            guard let id = c.linkedMaskID else { return count + 1 }
            return count + (MaskLinks.target(id, of: local, in: locals).map(MaskLinks.groupSize) ?? 0)
        }
    }

    /// Indices of the masks with a component that uses mask `id`.
    public func localsLinking(to id: UUID) -> [Int] {
        locals.indices.filter { locals[$0].components.contains { $0.linkedMaskID == id } }
    }

    /// Whether `locals[index]` may gain a component that uses mask
    /// `target`: not itself, not a mask with links of its own, not while
    /// another mask uses this one (links stay one level deep, so there is
    /// never a cycle), and only if the group fits.
    public func canLink(mask target: UUID, intoLocal index: Int) -> Bool {
        guard locals.indices.contains(index), let other = locals.first(where: { $0.id == target }) else { return false }
        let local = locals[index]
        guard other.id != local.id, !other.hasLinkedComponents, localsLinking(to: local.id).isEmpty else { return false }
        return packedComponentCount(ofLocal: index) + MaskLinks.groupSize(other) <= MaskComponent.maximumPerMask
    }

    /// The name a linked component shows: the mask it uses, or that the
    /// mask is gone.
    public func linkedMaskName(_ id: UUID) -> String {
        locals.first { $0.id == id }?.name ?? "Missing Mask"
    }
}
