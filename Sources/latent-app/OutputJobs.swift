import Foundation
import Observation

/// Prints and contact sheets being made. Both render every photo from its
/// file on a thread of their own after their dialog has gone (a print once
/// its panel closes, a contact sheet while its dialog shows progress), so
/// the app has to know about them:
///
/// - each holds an `ExportActivity`, so the Mac doesn't sleep partway
///   through, as for exports;
/// - Rename, Move to Folder and Copy to Folder are unavailable, since a
///   file moved meanwhile prints or lays out as an empty cell;
/// - quitting asks first, stops a contact sheet (its file isn't written)
///   and waits for a print to reach the printing system.
///
/// Observable, so the menus follow it.
@MainActor @Observable
final class OutputJobs {
    static let shared = OutputJobs()

    enum Kind: Equatable {
        case print
        case contactSheet
    }

    struct Job: Identifiable {
        let id = UUID()
        let kind: Kind
        /// The print's title ("12 Photos") or the contact sheet's file name.
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
        let reason = kind == .print ? "Printing \(name)" : "Making the contact sheet \(name)"
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

    /// Stops what can be stopped (contact sheets); prints carry on.
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
        let printing = prints.count == 1 ? "printing “\(prints[0].name)”" : "printing \(prints.count) jobs"
        let stopsSheet = "Quitting now stops the contact sheet\(sheets.count == 1 ? "" : "s"), which "
            + (sheets.count == 1 ? "isn’t" : "aren’t") + " saved"
        let waitsForPrint = "waits for the print\(prints.count == 1 ? "" : "s") to reach the printing system"
        switch (prints.isEmpty, sheets.isEmpty) {
        case (true, _):
            return ("Latent is still making a contact sheet", stopsSheet + ".", "Stop and Quit")
        case (false, true):
            return ("Latent is still \(printing)", "Quitting now " + waitsForPrint + ", then quits.",
                    "Finish Printing and Quit")
        case (false, false):
            return ("Latent is still \(printing) and making a contact sheet",
                    stopsSheet + ", and " + waitsForPrint + ", then quits.", "Finish Printing and Quit")
        }
    }
}
