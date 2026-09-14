import Foundation

/// The sequence of edits an image has passed through, with a cursor for
/// undo and redo. Pure value type; the editor owns one per open image
/// and the catalog persists it.
///
/// A step is recorded when an edit *settles*, not on every slider tick,
/// so a drag is one step. Undo moves the cursor back without discarding
/// the steps ahead; recording a new step after undoing discards them,
/// the way every editor's history behaves.
public struct EditHistory: Equatable, Sendable, Codable {
    public struct Step: Equatable, Sendable, Codable, Identifiable {
        public var id: UUID
        public var stack: EditStack
        /// What changed relative to the previous step, for the list.
        public var label: String
        public var date: Date
        public init(stack: EditStack, label: String, date: Date = Date()) {
            self.id = UUID(); self.stack = stack; self.label = label; self.date = date
        }
    }

    public static let maximumSteps = 30

    public private(set) var steps: [Step]
    /// Index of the current state in `steps`.
    public private(set) var cursor: Int

    public init(initial: EditStack) {
        steps = [Step(stack: initial, label: "Original")]
        cursor = 0
    }

    public init(steps: [Step], cursor: Int) {
        self.steps = steps.isEmpty ? [Step(stack: EditStack(), label: "Original")] : steps
        self.cursor = min(max(cursor, 0), self.steps.count - 1)
    }

    public var current: EditStack { steps[cursor].stack }
    public var canUndo: Bool { cursor > 0 }
    public var canRedo: Bool { cursor < steps.count - 1 }

    /// Records `stack` as the new current state if it differs from the
    /// current one. Anything past the cursor is discarded; the oldest
    /// steps drop off beyond the cap.
    @discardableResult
    public mutating func record(_ stack: EditStack) -> Bool {
        guard stack != current else { return false }
        steps.removeSubrange((cursor + 1)...)
        steps.append(Step(stack: stack, label: Self.describeChange(from: current, to: stack)))
        if steps.count > Self.maximumSteps {
            steps.removeFirst(steps.count - Self.maximumSteps)
        }
        cursor = steps.count - 1
        return true
    }

    public mutating func undo() -> EditStack? {
        guard canUndo else { return nil }
        cursor -= 1
        return current
    }

    public mutating func redo() -> EditStack? {
        guard canRedo else { return nil }
        cursor += 1
        return current
    }

    public mutating func jump(to index: Int) -> EditStack? {
        guard steps.indices.contains(index) else { return nil }
        cursor = index
        return current
    }

    /// "Exposure", "Tone, Colour", "Local Adjustments"…
    public static func describeChange(from a: EditStack, to b: EditStack) -> String {
        var names: [String] = []
        if a.modules.whitebalance != b.modules.whitebalance { names.append("White Balance") }
        if a.modules.exposure != b.modules.exposure { names.append("Exposure") }
        if a.modules.tone != b.modules.tone { names.append("Tone") }
        if a.modules.highlights != b.modules.highlights { names.append("Highlight Recovery") }
        names += toneRangeChanges(from: a.modules.toneranges ?? .neutral, to: b.modules.toneranges ?? .neutral)
        if a.modules.curve != b.modules.curve { names.append("Curve") }
        if a.modules.hsl != b.modules.hsl { names.append("HSL") }
        if a.modules.splittoning != b.modules.splittoning { names.append("Split Toning") }
        if a.modules.sharpen != b.modules.sharpen { names.append("Sharpening") }
        if a.modules.denoise != b.modules.denoise { names.append("Noise Reduction") }
        if a.modules.demosaic != b.modules.demosaic { names.append("Demosaic") }
        if a.modules.lens != b.modules.lens { names.append("Lens") }
        if a.modules.locals != b.modules.locals { names.append("Local Adjustments") }
        return names.isEmpty ? "Edit" : names.joined(separator: ", ")
    }

    /// Each of the four sliders by its own name, in panel order.
    private static func toneRangeChanges(from a: ToneRanges, to b: ToneRanges) -> [String] {
        var names: [String] = []
        if a.highlights != b.highlights { names.append("Highlights") }
        if a.shadows != b.shadows { names.append("Shadows") }
        if a.whites != b.whites { names.append("Whites") }
        if a.blacks != b.blacks { names.append("Blacks") }
        return names
    }
}

/// A named copy of an edit, kept with the image.
public struct EditSnapshot: Equatable, Sendable, Codable, Identifiable {
    public var name: String
    public var stack: EditStack
    public var id: String { name }
    public init(name: String, stack: EditStack) { self.name = name; self.stack = stack }
}
