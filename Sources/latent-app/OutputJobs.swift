import Foundation
import Observation

/// Prints, contact sheets and Photo Merges being made. Each renders photos
/// from their files in the background after its dialog has gone (a print
/// once its panel closes, a contact sheet while its dialog shows progress,
/// a merge from the library panel), so the app has to know about them:
///
/// - each holds an `ExportActivity`, so the Mac doesn't sleep partway
///   through, as for exports;
/// - Rename, Move to Folder and Copy to Folder are unavailable, since a
///   file moved meanwhile prints or lays out as an empty cell, or is
///   missing from a merge;
/// - quitting asks first, stops a contact sheet (its file isn't written),
///   a merge (neither its DNG nor its sidecar is left) and a dust removal
///   or face search (the photos already done are kept), and waits for a
///   print to reach the printing system.
///
/// Dust removal and Find Faces (SelectionJobQueue) are jobs too: they read
/// every selected photo from its file.
///
/// Observable, so the menus follow it.
@MainActor @Observable
final class OutputJobs {
    static let shared = OutputJobs()

    enum Kind: Equatable {
        case print
        case contactSheet
        /// Photo › Photo Merge › HDR (PhotoMergeQueue).
        case photoMerge
        /// Photo › Photo Merge › Panorama (PhotoMergeQueue). Its own kind
        /// only so the quit alert can name it; one merge runs at a time.
        case panoramaMerge
        /// An HDR panorama: brackets merged, then stitched (experimental).
        case hdrPanoramaMerge
        /// Photo › Remove Dust… over the selection (SelectionJobQueue).
        /// Stopping it keeps the photos already done.
        case dustRemoval
        /// Find Faces over the selection, for touch-up (SelectionJobQueue).
        /// Stopping it keeps the photos already done too.
        case findFaces
    }

    struct Job: Identifiable {
        let id = UUID()
        let kind: Kind
        /// The print's title ("12 Photos"), the contact sheet's file name,
        /// or the merge's first photo ("DSC_0107.NEF").
        let name: String
        /// Stops the job early; nil when it can only be waited for (a print).
        let cancel: (() -> Void)?
        let activity: ExportActivity
    }

    private(set) var running: [Job] = []
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    var isRunning: Bool { !running.isEmpty }

    /// Registers a job that has started; call `end` with the id when it
    /// has finished, however it finished.
    func begin(_ kind: Kind, name: String, cancel: (() -> Void)? = nil) -> UUID {
        let reason = switch kind {
        case .print: "Printing \(name)"
        case .contactSheet: "Making the contact sheet \(name)"
        case .photoMerge: "Merging photos with \(name)"
        case .panoramaMerge: "Stitching a panorama from \(name)"
        case .hdrPanoramaMerge: "Merging an HDR panorama from \(name)"
        case .dustRemoval: "Removing dust from \(name)"
        case .findFaces: "Finding faces in \(name)"
        }
        let job = Job(kind: kind, name: name, cancel: cancel, activity: ExportActivity(reason: reason))
        running.append(job)
        return job.id
    }

    func end(_ id: UUID) {
        guard let index = running.firstIndex(where: { $0.id == id }) else { return }
        running.remove(at: index).activity.end()
        guard running.isEmpty else { return }
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }

    /// Stops what can be stopped (contact sheets, merges, dust removal,
    /// face searches); prints carry on.
    func cancelAll() {
        for job in running { job.cancel?() }
    }

    /// Returns once nothing is running.
    func waitUntilDone() async {
        guard isRunning else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// The quit alert's wording for `jobs`: what is under way, what
    /// quitting does to it, and the button that quits.
    static func quitAlert(for jobs: [Job]) -> (message: String, information: String, button: String) {
        let prints = jobs.filter { $0.kind == .print }
        let sheets = jobs.filter { $0.kind == .contactSheet }
        let merges = jobs.filter { $0.kind == .photoMerge || $0.kind == .panoramaMerge
            || $0.kind == .hdrPanoramaMerge }
        let dust = jobs.filter { $0.kind == .dustRemoval }
        let faces = jobs.filter { $0.kind == .findFaces }
        // One merge runs at a time, so "merge" below is one kind's word
        // unless a future queue runs two.
        let mergeWord = merges.allSatisfy { $0.kind == .panoramaMerge } ? "panorama merge"
            : merges.allSatisfy { $0.kind == .hdrPanoramaMerge } ? "HDR panorama merge" : "HDR merge"
        // What is under way, in the order the message names it.
        var underWay: [String] = []
        if !prints.isEmpty {
            underWay.append(prints.count == 1 ? "printing “\(prints[0].name)”" : "printing \(prints.count) jobs")
        }
        if !sheets.isEmpty { underWay.append("making a contact sheet") }
        if !merges.isEmpty {
            underWay.append(merges.count == 1 ? "making \(mergeWord.hasPrefix("HDR") ? "an" : "a") \(mergeWord)"
                                              : "making \(mergeWord)s")
        }
        // One selection job runs at a time, so each of these is one job.
        if !dust.isEmpty { underWay.append("removing sensor dust from photos") }
        if !faces.isEmpty { underWay.append("finding faces for touch-up") }
        // What quitting stops, then what it waits for.
        var stopped: [String] = []
        if !sheets.isEmpty {
            stopped.append("the contact sheet\(sheets.count == 1 ? "" : "s"), which "
                           + (sheets.count == 1 ? "isn’t" : "aren’t") + " saved")
        }
        if !merges.isEmpty {
            stopped.append(merges.count == 1 ? "the \(mergeWord), which leaves no photo"
                                             : "the \(mergeWord)s, which leave no photos")
        }
        if !dust.isEmpty { stopped.append("the dust removal, which keeps the photos already done") }
        if !faces.isEmpty { stopped.append("the face search, which keeps the photos already done") }
        var information = stopped.isEmpty ? "" : "Quitting now stops " + stopped.joined(separator: ", and ")
        if !prints.isEmpty {
            information += (information.isEmpty ? "Quitting now " : ", and ")
                + "waits for the print\(prints.count == 1 ? "" : "s") to reach the printing system, then quits"
        }
        return ("Latent is still " + spokenList(underWay), information + ".",
                prints.isEmpty ? "Stop and Quit" : "Finish Printing and Quit")
    }

    /// "a", "a and b", "a, b and c".
    private static func spokenList(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }
}
