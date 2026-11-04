import Foundation
import Catalog
import PixelEngine

/// Photo › Match Total Exposures (⌥⇧⌘M, Lightroom's key): the selected
/// photos' Exposure sliders set so each has the lead photo's total
/// exposure, camera and slider together (`ExposureMatching`).
///
/// Library mode only, on the stored edits, as one Library undo group. The
/// lead keeps its edit; photos without shutter, aperture and ISO are
/// skipped and counted in the message.
@MainActor
enum MatchTotalExposures {
    static func run(library: Library, report: @escaping @MainActor (String) -> Void) {
        let selected = library.selectedImages
        guard selected.count >= 2, let lead = library.selectedImage, let leadID = lead.id,
              let catalog = library.catalog else { return }
        guard let leadCamera = ExposureMatching.cameraExposure(shutter: lead.shutter, aperture: lead.aperture,
                                                               iso: lead.iso.map(Double.init)) else {
            report("Match Total Exposures needs the shutter speed, aperture and ISO of \(lead.fileName)")
            return
        }
        // Inside `perform`, so quitting waits for the write and a failure
        // reaches the status bar as every catalog write's does.
        library.perform("Match Total Exposures") {
            let target = leadCamera + Double(try ExposureMatching.exposure(
                inEditJSON: try await catalog.storedEdit(forImageID: leadID)?.json))
            var edits: [Int64: String?] = [:], expected: [Int64: String?] = [:]
            var unmatched = 0
            for record in selected {
                guard let id = record.id, id != leadID else { continue }
                guard let camera = ExposureMatching.cameraExposure(shutter: record.shutter,
                                                                   aperture: record.aperture,
                                                                   iso: record.iso.map(Double.init)) else {
                    unmatched += 1
                    continue
                }
                let json = try await catalog.storedEdit(forImageID: id)?.json
                let ev = ExposureMatching.matchedExposure(target: target, camera: camera)
                guard try ExposureMatching.exposure(inEditJSON: json) != ev else { continue }
                edits[id] = .some(try ExposureMatching.settingExposure(ev, inEditJSON: json))
                expected[id] = .some(json)
            }
            guard catalog === library.catalog else { return }
            let n = edits.count
            let outcome = try await library.setEdits(edits, expecting: expected,
                                                     schemaVersion: EditStack.schemaVersion,
                                                     processVersion: EditStack.processVersion,
                                                     undoName: "Match Total Exposures (\(n) Image\(n == 1 ? "" : "s"))")
            var message = "Matched the exposure of \(outcome.changed) photo\(outcome.changed == 1 ? "" : "s") to \(lead.fileName)"
            if unmatched > 0 { message += " · \(unmatched) without shutter, aperture or ISO left alone" }
            if !outcome.skipped.isEmpty { message += " · skipped " + outcome.skipped.joined(separator: ", ") }
            report(message)
        }
    }
}
