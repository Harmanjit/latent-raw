import SwiftUI
import Catalog

/// "+ DSC_0107.JPG" under a raw's name in the Library panel: the JPEG of
/// its RAW+JPEG pair, hidden from the grid and travelling with it
/// (`RawJPEGPairs`). Nothing when it has none, or when such JPEGs are
/// shown as photos of their own.
struct PairedCompanionLabel: View {
    let companions: [ImageRecord]

    var body: some View {
        if !companions.isEmpty {
            let names = companions.map(\.fileName).joined(separator: ", ")
            Text("+ \(names)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("The JPEG saved with this raw. It is hidden from the grid and moves, copies and renames with the raw. Settings › Library can show it as a photo of its own.")
                .accessibilityLabel("Paired JPEG: \(names)")
        }
    }
}
