import Foundation

// Copy Mask / Paste Mask (wave 4): one mask of a photo, with its
// components and every adjustment slider, added to another photo (or the
// whole selection) as a new mask. Built on mask presets' capture
// (MaskPresets.swift), which already knows which components travel: every
// shape, brush stroke and range is stored resolution-independently, and a
// model mask (Subject, a class, Click to Select) keeps only its kind or
// normalised clicks and is generated again from the target photo's own
// pixels. A linked mask names another mask of the source photo by id, so
// it is left out and the paste says so.

/// A mask on the mask clipboard: what Copy Mask took, ready to be pasted
/// onto any number of photos.
public struct CopiedMask: Equatable, Sendable {
    /// The mask as copied, less the components that can't travel. Its ids
    /// are placeholders: every paste gives fresh ones (`instance()`).
    public var mask: LocalAdjustment
    /// Components left out of the copy, and why.
    public var skipped: [MaskPreset.Skipped]

    /// Copies `local`: its shape, components, ranges and sliders, shown
    /// (not hidden) and under its own name.
    public init(_ local: LocalAdjustment) {
        let captured = MaskPreset.capture(local, name: local.name)
        mask = captured.preset.mask
        skipped = captured.skipped
    }

    /// The mask to add to one photo: the copy with a fresh id for the mask
    /// and each component, so it never collides with a mask the photo
    /// already holds (model-mask pixels are keyed by id).
    public func instance() -> LocalAdjustment {
        MaskPreset(name: mask.name, mask: mask).instantiate(name: mask.name)
    }

    /// Whether the copy has a model-made component (Subject, a class,
    /// Click to Select), which each photo makes again from its own pixels.
    public var hasModelMask: Bool {
        mask.maskElements.contains { $0.shape.isModelGenerated }
    }

    /// The status line after a paste: how many photos took the mask, how
    /// many had no room, what was left out and what is made again.
    public func pasteMessage(added: Int, full: Int, skippedUnreadable: [String] = []) -> String {
        var parts = ["Pasted mask “\(mask.name)” to \(added) photo\(added == 1 ? "" : "s")"]
        if added == 1 && full == 0 && skippedUnreadable.isEmpty { parts = ["Pasted mask “\(mask.name)”"] }
        if full > 0 {
            parts.append("\(full) already had \(LocalAdjustment.maximumCount) masks")
        }
        if !skippedUnreadable.isEmpty {
            parts.append("skipped \(skippedUnreadable.count) with unreadable edits: "
                         + skippedUnreadable.joined(separator: ", "))
        }
        if !skipped.isEmpty {
            parts.append("left out " + skipped.map(\.name).joined(separator: ", ")
                         + " (it uses another mask of the source photo)")
        }
        if hasModelMask && added > 0 {
            parts.append("Subject and Click to Select parts are made again from each photo")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Adding, never replacing

    /// `locals` with `local` added at the end, or nil when the photo
    /// already holds `LocalAdjustment.maximumCount` masks. Existing masks
    /// are never touched.
    public static func adding(_ local: LocalAdjustment, to locals: [LocalAdjustment]) -> [LocalAdjustment]? {
        guard locals.count < LocalAdjustment.maximumCount else { return nil }
        return locals + [local]
    }

    /// What pasting does to one photo's stored edit.
    public enum StoredPaste: Equatable, Sendable {
        /// The new edit JSON, with the mask added.
        case added(String)
        /// The photo has no room for another mask; its edit is left alone.
        case full
    }

    /// Pastes a fresh instance onto a stored edit (nil = no edit yet).
    /// Only the masks change: every other module of the edit is kept as it
    /// was. Throws for an edit that can't be read, which is then never
    /// replaced.
    public func pasted(ontoStored json: String?) throws -> StoredPaste {
        try Self.pasted(instance(), ontoStored: json)
    }

    /// `pasted(ontoStored:)` with a given mask, for tests and for a caller
    /// that wants the same ids on every photo.
    public static func pasted(_ local: LocalAdjustment, ontoStored json: String?) throws -> StoredPaste {
        var stack = try json.map { try EditStack.decode(json: $0) } ?? EditStack()
        guard let locals = adding(local, to: stack.modules.locals ?? []) else { return .full }
        stack.modules.locals = locals
        return .added(try stack.encodeJSON())
    }
}
