import Foundation

/// How hot pixel removal (HotPixels.swift) and the manual chromatic
/// aberration sliders (ManualTCA.swift) are stored. Each is written only
/// when it is on or off zero, so an edit that never touched them encodes
/// byte for byte as before, and an edit from before them reads back with
/// both off.
extension EditStack {
    mutating func storeDetailExtras(from p: EditParameters) {
        modules.hotpixels = p.hotPixels?.sanitized
        let red = ManualTCA.clamped(p.manualTCARed), blue = ManualTCA.clamped(p.manualTCABlue)
        modules.lens?.tcaRed = red == 0 ? nil : red
        modules.lens?.tcaBlue = blue == 0 ? nil : blue
    }

    func restoreDetailExtras(into p: inout EditParameters) {
        p.hotPixels = modules.hotpixels?.sanitized
        // The sliders live in the lens module and follow it: a preset
        // without Lens Corrections leaves `p`'s alone.
        if let lens = modules.lens {
            p.manualTCARed = ManualTCA.clamped(lens.tcaRed ?? 0)
            p.manualTCABlue = ManualTCA.clamped(lens.tcaBlue ?? 0)
        }
    }
}
