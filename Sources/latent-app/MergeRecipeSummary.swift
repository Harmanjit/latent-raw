import Foundation
import MergeKit

/// What the library panel says about a photo Photo Merge made: which photos
/// went into it, how they were merged, and which of them were left out.
///
/// Every merge writes a `latent:Merge` recipe into the result's sidecar and
/// into the DNG (docs/PhotoMerge.md §5), and the catalog keeps it. These
/// rows are that record read back, in the same shape as the metadata rows
/// beside them, so "why are this photo's shadows noisy" and "which frame
/// was dropped" can be answered the next day instead of only in the dialog
/// that has long since closed.
///
/// Anything unreadable gives nil rather than a half-filled panel: a recipe
/// from a newer Latent, or a file someone edited by hand, simply doesn't
/// show a Merged section.
struct MergeRecipeSummary: Equatable {
    /// One label and value, as the metadata grid draws them.
    struct Row: Equatable {
        let label: String
        let value: String
    }

    let rows: [Row]

    /// Nil when `json` is not a recipe this version understands.
    init?(json: String) {
        guard let data = json.data(using: .utf8), let recipe = try? MergeRecipe(jsonData: data) else { return nil }
        self.init(recipe)
    }

    init(_ recipe: MergeRecipe) {
        let names = recipe.sources.map { ($0.path as NSString).lastPathComponent }
        let leftOut = Self.leftOutNames(recipe, names: names)
        var rows: [Row] = [Row(label: "Merged", value: Self.kindText(recipe.kind))]
        if !names.isEmpty {
            rows.append(Row(label: names.count == 1 ? "From" : "From \(names.count)",
                            value: names.joined(separator: ", ")))
        }
        if !leftOut.isEmpty {
            rows.append(Row(label: leftOut.count == 1 ? "Left out" : "\(leftOut.count) left out",
                            value: leftOut.joined(separator: ", ")))
        }
        // The settings that changed the pixels, so the panel says what the
        // dialog was set to. Each engine records its own, so both sets are
        // looked for and the ones that aren't there are skipped.
        if let deghost = Self.string(recipe.options["deghost"]) {
            rows.append(Row(label: "Deghost", value: Self.deghostText(deghost)))
        }
        if let align = Self.bool(recipe.options["autoAlign"]) {
            rows.append(Row(label: "Auto Align", value: align ? "On" : "Off"))
        }
        if let projection = Self.string(recipe.options["projection"]) {
            rows.append(Row(label: "Projection", value: Self.projectionText(projection)))
        }
        if let crop = Self.bool(recipe.options["autoCrop"]) {
            rows.append(Row(label: "Auto Crop", value: crop ? "On" : "Off"))
        }
        self.rows = rows
    }

    /// What VoiceOver reads for the whole section, so it needn't be walked
    /// row by row.
    var spoken: String {
        rows.map { "\($0.label): \($0.value)" }.joined(separator: ", ")
    }

    // MARK: - Which photos were left out

    /// The photos the merge couldn't use, by name.
    ///
    /// An HDR merge and a panorama both record `leftOut` as indices into
    /// `sources`. An HDR panorama can't: its stitch joins *positions*, each
    /// of them a bracket of several photos, so its `leftOut` counts
    /// positions and would name the wrong files. It records
    /// `positionsLeftOut` and `brackets` instead, and a position is
    /// expanded into the photos that made it.
    static func leftOutNames(_ recipe: MergeRecipe, names: [String]) -> [String] {
        guard recipe.kind == .hdrPanorama else {
            return indices(recipe.options["leftOut"]).compactMap { names.indices.contains($0) ? names[$0] : nil }
        }
        guard case .array(let brackets)? = recipe.options["brackets"] else { return [] }
        var left: [String] = []
        for position in indices(recipe.options["positionsLeftOut"]) {
            guard brackets.indices.contains(position), case .object(let bracket) = brackets[position] else { continue }
            left += indices(bracket["frames"]).compactMap { names.indices.contains($0) ? names[$0] : nil }
        }
        return left
    }

    // MARK: - Words

    static func kindText(_ kind: MergeRecipe.Kind) -> String {
        switch kind {
        case .hdr: "HDR"
        case .panorama: "Panorama"
        case .hdrPanorama: "HDR panorama"
        }
    }

    /// The dialog's own names for the deghost amounts.
    static func deghostText(_ raw: String) -> String {
        switch raw {
        case "none": "Off"
        case "low": "Low"
        case "medium": "Medium"
        case "high": "High"
        default: raw
        }
    }

    /// The Panorama dialog's own names, so the panel and the dialog agree.
    static func projectionText(_ raw: String) -> String {
        guard let projection = PanoramaProjection(rawValue: raw) else { return raw }
        return PanoramaMergeSheetModel.name(for: projection)
    }

    // MARK: - Reading the open-ended options

    private static func string(_ value: JSONValue?) -> String? {
        if case .string(let text)? = value { return text }
        return nil
    }

    private static func bool(_ value: JSONValue?) -> Bool? {
        if case .bool(let flag)? = value { return flag }
        return nil
    }

    private static func indices(_ value: JSONValue?) -> [Int] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap { item in
            guard case .number(let index) = item, index >= 0, index < 10_000 else { return nil }
            return Int(index)
        }
    }
}
