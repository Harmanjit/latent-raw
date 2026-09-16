import Foundation

// The words the HDR Panorama dialog and the command line both say, so a
// warning reads the same wherever it appears (as
// MergeKit/Pano/PanoramaMergeWarningText.swift does for the panorama).

public extension HDRPanoramaWarning {
    /// The warning in the dialog's words. `analysis` is what it came from,
    /// for the names of photos and positions.
    func message(_ analysis: HDRPanoramaAnalysis? = nil) -> String {
        switch self {
        case .unevenBrackets(let counts):
            return "The positions don’t all have the same number of photos ("
                + HDRPanoramaGrouping.list(counts.map(String.init))
                + "). Each is merged with what it has, so a position with fewer exposures has less range."
        case .singlePhotoPosition(let position, let fileName):
            return "Position \(position + 1) is one photo, \(fileName), with no bracket around it, "
                + "so it goes into the panorama as it is."
        case .alreadyMergedPosition(let position, let fileName):
            return "Position \(position + 1), \(fileName), is already an HDR merge, "
                + "so Auto Align and Deghost don’t apply to it."
        case .groupingIsAGuess(let evidence):
            return "The positions were worked out \(evidence.text). Check the list before merging."
        case .scratchSpace(let bytes):
            return "The merged brackets need "
                + "\(ByteCountFormatter().string(fromByteCount: bytes)) of temporary space while this runs; "
                + "it is given back when it ends."
        case .panorama(let warning):
            return warning.message(frames: analysis?.panorama.frames ?? [])
        }
    }

    /// True for the warnings the dialog shows as a caution rather than as
    /// something the user must agree to.
    var needsAgreement: Bool {
        if case .panorama(.downsampled) = self { return true }
        return false
    }
}
