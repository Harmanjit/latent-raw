import Foundation

/// Edit Capture Time… and Geotag from GPX Track… on the selection, each one
/// undo step, like the other metadata changes (GeoTime.swift for what is
/// stored where).
extension Library {
    /// Moves the capture time of every photo of `records` by the same
    /// amount (`CaptureTimeEdit`). Photos without a capture time are left
    /// alone. Returns how many photos changed.
    @discardableResult
    public func editCaptureTime(_ edit: CaptureTimeEdit, for records: [ImageRecord]) async throws -> Int {
        guard let delta = edit.delta(forCaptureTimes: records.compactMap(\.captureTime)), delta != 0 else { return 0 }
        return try await changeGeoTime(records.filter { $0.captureTime != nil }, action: "Edit Capture Time") { _, state in
            state.shiftCaptureTime(by: delta)
        }
    }

    /// Puts each position of `positions` (image id → place, from a
    /// `GeotagPlan`) on its photo as a geotag. Returns how many changed.
    @discardableResult
    public func applyGeotags(_ positions: [Int64: GeoPosition], for records: [ImageRecord]) async throws -> Int {
        let wanted = records.filter { $0.id.map { positions[$0] != nil } ?? false }
        return try await changeGeoTime(wanted, action: "Geotag from GPX Track") { id, state in
            if let position = positions[id] { state.setGeotag(position) }
        }
    }

    /// Runs `transform` on each record's `GeoTimeState` and files one undo
    /// step that puts back what each changed photo had.
    private func changeGeoTime(_ records: [ImageRecord], action: String,
                               _ transform: @escaping @Sendable (Int64, inout GeoTimeState) -> Void) async throws -> Int {
        let written = catalog
        let before = UndoLedger<GeoTimeState>(), after = UndoLedger<GeoTimeState>()
        defer { fileGeoTimeUndo(action, in: written, before: before.recorded, after: after.recorded) }
        try await change(records) { catalog, id, _ in
            guard let outcome = try await catalog.exchangeGeoTime(forImageID: id, { transform(id, &$0) }),
                  outcome.before != outcome.after else { return }
            before.record(id, outcome.before)
            after.record(id, outcome.after)
        }
        return before.recorded.count
    }

    private func fileGeoTimeUndo(_ action: String, in catalog: Catalog?,
                                 before: [Int64: GeoTimeState], after: [Int64: GeoTimeState]) {
        guard let catalog, !before.isEmpty else { return }
        let name = Self.undoActionName(action, count: before.count)
        undoRegistration(name, in: catalog) { library, catalog in
            library.restoreGeoTime(before, opposite: after, named: name, in: catalog)
        }(true)
    }

    /// Runs as an undo or redo, as `restoreMetadata` does: files the
    /// opposite at once, then puts the states back after any restore
    /// asked for before it.
    func restoreGeoTime(_ values: [Int64: GeoTimeState], opposite: [Int64: GeoTimeState],
                        named name: String, in catalog: Catalog) {
        let verb = undoManager?.isRedoing == true ? "Redo" : "Undo"
        let done = undoRegistration(name, in: catalog) { library, catalog in
            library.restoreGeoTime(opposite, opposite: values, named: name, in: catalog)
        }
        let previous = undoRestores
        let restoring = Task { @MainActor [weak self] in
            _ = await previous?.result
            guard let self, catalog === self.catalog else { return }
            let wanted = Set(values.keys)
            let records = self.images.filter { $0.id.map(wanted.contains) ?? false }
            try await self.change(records) { catalog, id, _ in
                guard let state = values[id] else { return }
                try await catalog.exchangeGeoTime(forImageID: id) { $0 = state }
            }
        }
        undoRestores = restoring
        perform("\(verb) \(name)") {
            try await restoring.value
            done(true)
        }
    }
}
