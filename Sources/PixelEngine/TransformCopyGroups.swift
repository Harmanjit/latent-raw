import Foundation

/// Copy, Sync and Paste Settings for Upright and the Transform panel, the
/// way Lightroom offers them: four choices over the one `perspective`
/// module rather than one all-or-nothing group.
///
/// - Upright Mode: the mode alone. Its matrix is left behind, and the app
///   runs the analysis again on each photo it lands on
///   (`EditStack.wantsUprightAnalysis`), so every frame of a building
///   gets its own correction.
/// - Upright Transforms: the exact correction, matrix and guides, as Crop
///   used to carry it. Wins over Upright Mode when both are chosen.
/// - Transform Adjustments: the sliders (vertical, horizontal, rotate,
///   aspect, scale, offsets) and the flips.
/// - Constrain Crop.
///
/// Guided Upright travels whole under either Upright choice: its guides
/// are lines the user drew, and there is nothing to analyse again.
extension EditGroup {
    /// The four groups that share the perspective module.
    public static let transformGroups: Set<EditGroup> = [.uprightMode, .uprightTransforms, .transformSliders,
                                                         .constrainCrop]

    /// `groups` as a set saved before the split means it: Crop then
    /// carried the whole transform, so a set with Crop and none of the
    /// four gets the three that reproduce that exactly.
    public static func upgradingLegacy(_ groups: Set<EditGroup>) -> Set<EditGroup> {
        guard groups.contains(.crop), groups.isDisjoint(with: transformGroups) else { return groups }
        return groups.union([.uprightTransforms, .transformSliders, .constrainCrop])
    }
}

extension EditStack {
    /// `own` with the chosen parts of `other` laid over it; nil when the
    /// result changes nothing. With none of the four chosen, `own` as it is.
    static func mergedPerspective(_ own: Perspective?, _ other: Perspective?, groups: Set<EditGroup>) -> Perspective? {
        let parts = groups.intersection(EditGroup.transformGroups)
        guard !parts.isEmpty else { return own }
        let empty = Perspective(vertical: 0, horizontal: 0)
        var r = own ?? empty
        let o = other ?? empty
        if parts.contains(.transformSliders) {
            r.vertical = o.vertical; r.horizontal = o.horizontal
            r.rotate = o.rotate; r.aspect = o.aspect; r.scale = o.scale
            r.offsetX = o.offsetX; r.offsetY = o.offsetY
            r.flipHorizontal = o.flipHorizontal; r.flipVertical = o.flipVertical
        }
        if parts.contains(.uprightTransforms) {
            r.upright = o.upright
        } else if parts.contains(.uprightMode) {
            r.upright = o.upright.map { $0.mode == .guided ? $0 : UprightCorrection(mode: $0.mode) }
        }
        if parts.contains(.constrainCrop) {
            r.constrainCrop = o.constrainCrop
        }
        return r.correction.isNeutral ? nil : r
    }

    /// Which of the four groups `perspective` has something for.
    static func presentTransformGroups(_ perspective: Perspective?) -> Set<EditGroup> {
        guard let p = perspective else { return [] }
        var groups: Set<EditGroup> = []
        if !p.correction.isIdentity { groups.insert(.transformSliders) }
        if p.upright != nil { groups.formUnion([.uprightMode, .uprightTransforms]) }
        if p.constrainCrop == true { groups.insert(.constrainCrop) }
        return groups
    }

    /// Whether pasting this stack with `groups` leaves an Upright mode to
    /// be analysed on each photo: a mode that reads the picture's lines,
    /// with Upright Mode chosen without Upright Transforms, or with no
    /// matrix to copy (a clipboard copied with Upright Mode alone).
    public func wantsUprightAnalysis(groups: Set<EditGroup>) -> Bool {
        guard !groups.isDisjoint(with: [.uprightMode, .uprightTransforms]),
              let upright = modules.perspective?.upright, upright.mode != .guided else { return false }
        return !groups.contains(.uprightTransforms) || upright.matrix == nil
    }
}
