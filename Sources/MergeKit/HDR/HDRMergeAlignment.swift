// Auto Align inside the HDR merge: what the analysis measured about how the
// frames moved, and how the merge turns that into one warp per frame.

import Foundation
import simd

/// What Auto Align decided for one frame of a merge.
public enum HDRFrameAlignment: Sendable, Equatable {
    /// The frame everything is lined up with; it never moves.
    case reference
    /// Lined up with the reference; its corners move by up to this many
    /// full-resolution pixels (under 0.1 px it isn't resampled at all).
    case aligned(shiftPixels: Double)
    /// Couldn't be lined up, but looks within a pixel or so of where it
    /// belongs: merged where it is (or, when frames further along were
    /// lined up with it, carried along with them).
    case unaligned
    /// Couldn't be lined up and looks several pixels out: left out of the
    /// merge, because it would double every edge it contributes to.
    case leftOut
}

/// How a bracket's frames moved relative to each other, as `HDRMerger.analyse`
/// measured it with Auto Align on.
///
/// **Neighbours, then a chain.** Frames are aligned neighbour to neighbour
/// in exposure order, because very dark and very bright frames share almost
/// nothing both recorded well, while neighbours share the most
/// (`FrameAligner.chain` has the details). The analysis keeps only these
/// links, not the frames, so the merge can carry them to whichever frame is
/// the reference, including one the user picked after the analysis.
public struct HDRMergeAlignment: Sendable, Equatable {
    /// `links[p]` aligns the frame at chain position p (moving) onto the
    /// frame at position p + 1 (reference). One fewer than the frames.
    public let links: [AlignmentResult]
    /// The analysis's frame index at each chain position. The chain follows
    /// the EXIF exposure order the frames were read in; the analysis lists
    /// frames by measured brightness, which only differs when EXIF lied
    /// about frames a fraction of a stop apart.
    public let chainOrder: [Int]
    /// Per link the aligner rejected, the shift phase correlation found
    /// between the same two frames (`HDRAlignmentCheck`), in full-resolution
    /// pixels: a second opinion, by which a frame that looks within a pixel
    /// or so is merged unaligned and one further out is left out. Nil for
    /// accepted links (not measured) and where phase correlation couldn't judge.
    public let neighbourShiftPixels: [Double?]
    /// The frames' full-resolution size.
    public let width: Int
    public let height: Int

    public init(links: [AlignmentResult], chainOrder: [Int], neighbourShiftPixels: [Double?], width: Int, height: Int) {
        precondition(links.count + 1 == chainOrder.count && neighbourShiftPixels.count == links.count,
                     "one link and one shift between each pair of neighbouring frames")
        self.links = links
        self.chainOrder = chainOrder
        self.neighbourShiftPixels = neighbourShiftPixels
        self.width = width
        self.height = height
    }

    /// A rejected link whose phase-correlation shift is at most this (in
    /// full-resolution pixels) counts as "didn't move": the same limit the
    /// misalignment warning uses when Auto Align is off.
    public static let unalignedLimitPixels = 1.5

    /// What the merge does with each frame, for one reference frame.
    public struct Plan: Sendable, Equatable {
        /// Per frame, in the analysis's order.
        public let frames: [HDRFrameAlignment]
        /// Per frame, what to warp it by: moving -> reference, in
        /// full-resolution pixels (see `Homography`). Exactly the identity
        /// for frames that don't move, and for frames left out.
        public let homographies: [simd_double3x3]

        /// Whether the frame goes into the merge.
        public func includes(_ frame: Int) -> Bool { frames[frame] != .leftOut }
        /// Whether any frame is resampled.
        public var warps: Bool { homographies.contains { !Homography.isIdentity($0) } }
        /// The largest shift of a frame that was lined up; 0 when none moved.
        public var largestShiftPixels: Double {
            frames.reduce(0) { largest, frame in
                if case .aligned(let shift) = frame { return max(largest, shift) }
                return largest
            }
        }
    }

    /// Carries the links to `reference` (an index into the analysis's frames).
    ///
    /// **When a link was rejected.** The aligner rejects a pair it can't
    /// match well enough to trust (NCC under 0.9, too little shared detail,
    /// a scale change no bracket has). What happens to the frames on the far
    /// side of that link from the reference depends on the second opinion:
    /// - phase correlation says the pair is within `unalignedLimitPixels`
    ///   (or can't tell): the link is taken as "no movement", so those
    ///   frames are merged where they are, still lined up with each other
    ///   through the links that were accepted (`.unaligned`);
    /// - it says they're further apart: those frames are left out
    ///   (`.leftOut`). A frame several pixels out would double every edge
    ///   it contributes to, which looks worse than the few highlights or
    ///   shadows it would have added.
    ///
    /// A merge always keeps at least two frames: if leaving frames out
    /// would leave only the reference, they are merged unaligned instead.
    public func plan(reference: Int) -> Plan {
        let count = chainOrder.count
        guard let referencePosition = chainOrder.firstIndex(of: reference) else {
            return Plan(frames: (0..<count).map { $0 == reference ? .reference : .unaligned },
                        homographies: Array(repeating: Homography.identity, count: count))
        }
        // Rejected links that phase correlation says barely moved become
        // "no movement", so the chain carries on through them.
        var guessed = [Bool](repeating: false, count: links.count)
        let usable = links.enumerated().map { index, link -> AlignmentResult in
            guard !link.accepted, (neighbourShiftPixels[index] ?? 0) <= Self.unalignedLimitPixels else { return link }
            guessed[index] = true
            return .identity
        }
        let chained = FrameAligner.chain(usable, reference: referencePosition, width: width, height: height)

        var frames = [HDRFrameAlignment](repeating: .reference, count: count)
        var homographies = [simd_double3x3](repeating: Homography.identity, count: count)
        for position in 0..<count {
            let frame = chainOrder[position]
            guard position != referencePosition else { continue }
            let path = position < referencePosition ? position..<referencePosition : referencePosition..<position
            let result = chained[position]
            if !result.accepted {
                frames[frame] = .leftOut
            } else if path.contains(where: { guessed[$0] }) {
                frames[frame] = .unaligned
                homographies[frame] = result.homography
            } else {
                frames[frame] = .aligned(shiftPixels: result.maxCornerShift)
                homographies[frame] = result.homography
            }
        }
        if frames.filter({ $0 != .leftOut }).count < 2 {
            frames = frames.map { $0 == .leftOut ? .unaligned : $0 }
        }
        return Plan(frames: frames, homographies: homographies)
    }
}
