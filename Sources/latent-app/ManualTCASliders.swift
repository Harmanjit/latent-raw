import SwiftUI
import PixelEngine

/// Lens Corrections' manual chromatic aberration (ManualTCA.swift): Red
/// and Blue, under the profile and automatic switches, added on top of
/// whichever of those is on.
struct ManualTCASliders: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        DetailSliderRow(title: "Red", value: $model.parameters.manualTCARed, range: ManualTCA.range,
                        format: "%+.2f%%",
                        help: "Scales the red image against green, in percent of the radius: positive pulls in red fringes on the outer side of edges towards the corners, negative pushes red out.",
                        label: "Chromatic aberration red")
        DetailSliderRow(title: "Blue", value: $model.parameters.manualTCABlue, range: ManualTCA.range,
                        format: "%+.2f%%",
                        help: "Scales the blue image against green, in percent of the radius: positive pulls in blue fringes on the outer side of edges towards the corners, negative pushes blue out.",
                        label: "Chromatic aberration blue")
    }
}
