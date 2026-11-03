import Foundation

extension LibraryFileOperations {
    /// Moves or copies the JPEGs of RAW+JPEG pairs after their raws
    /// (`RawJPEGPairs`). Each goes to the folder its raw went to, under
    /// the raw's final name with its own extension, so a raw numbered to
    /// "A 2.NEF" on arrival or renamed takes "A 2.JPG" with it and the
    /// pair stays a pair. A raw that failed or was skipped keeps its JPEG
    /// where it is. The result is merged into the raws' report, so one
    /// Undo puts both back.
    ///
    /// - Parameter companions: raw file URL (standardised) → its companions,
    ///   read before the raws moved (`Library.companionURLsTravelling`).
    func transferCompanions(_ companions: [URL: [URL]], following completed: [CompletedTransfer],
                            mode: TransferMode, title: String) async -> TransferReport {
        guard !companions.isEmpty else { return TransferReport() }
        let requests = Self.companionRequests(companions, following: completed)
        guard !requests.isEmpty else { return TransferReport() }
        return await execute(.transfer(requests, mode), title: title)
    }

    /// The requests `transferCompanions` makes, separate so tests can check
    /// the naming without moving anything.
    nonisolated static func companionRequests(_ companions: [URL: [URL]],
                                              following completed: [CompletedTransfer]) -> [TransferRequest] {
        completed.flatMap { item -> [TransferRequest] in
            guard item.kind != .trash, let followers = companions[item.source.standardizedFileURL] else { return [] }
            let rawName = item.destination.lastPathComponent
            return followers.map { companion in
                TransferRequest(source: companion, folder: item.destination.deletingLastPathComponent(),
                                name: RawJPEGPairs.companionName(forRawName: rawName,
                                                                 companion: companion.lastPathComponent))
            }
        }
    }
}
