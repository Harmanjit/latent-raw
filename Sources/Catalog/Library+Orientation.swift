import Foundation

extension Library {
    /// Photo › Reset to Camera Orientation: takes away the quarter turns
    /// the user added to each selected image, so each shows as the camera
    /// recorded it. One undo step puts every image back as it was, even
    /// when the selection was turned different ways: the images are
    /// turned back in groups by how far they had been turned, and the
    /// groups' undos are filed together.
    public func resetRotationOfSelected(onlyPrimary: Bool = false) async throws {
        let written = catalog
        let targets = metadataTargets(onlyPrimary: onlyPrimary).filter { $0.userRotation != 0 }
        guard !targets.isEmpty else { return }
        let groups = Dictionary(grouping: targets, by: \.userRotation)
        var turned: [(turns: Int, ids: [Int64])] = []
        defer { fileResetUndo(turned, in: written) }
        for (rotation, records) in groups.sorted(by: { $0.key < $1.key }) {
            let ledger = UndoLedger<Bool>()
            defer {
                let ids = Array(ledger.recorded.keys)
                if !ids.isEmpty { turned.append((-rotation, ids)) }
            }
            try await change(records) { catalog, id, _ in
                try await catalog.rotate(by: -rotation, forImageID: id)
                ledger.record(id, true)
            }
        }
    }

    private func fileResetUndo(_ turned: [(turns: Int, ids: [Int64])], in catalog: Catalog?) {
        guard !turned.isEmpty else { return }
        let count = turned.reduce(0) { $0 + $1.ids.count }
        let manager = undoManager
        let group = manager.map { $0.groupingLevel == 0 && !$0.isUndoing && !$0.isRedoing } ?? false
        let groupsByEvent = manager?.groupsByEvent ?? true
        if group, let manager {
            manager.groupsByEvent = false
            manager.beginUndoGrouping()
        }
        for (turns, ids) in turned {
            fileFreshUndo("Reset Orientation", count: count, in: catalog,
                          undo: .rotation(ids, quarterTurns: -turns), redo: .rotation(ids, quarterTurns: turns))
        }
        if group, let manager {
            manager.endUndoGrouping()
            manager.groupsByEvent = groupsByEvent
        }
    }
}
