#if DEBUG
import AppKit
import Catalog
import PixelEngine

/// The snapshot harness's Print and Contact Sheet steps (SnapshotHarness.swift
/// lists them): open the dialog or the print panel over the window, or save
/// a contact sheet into the snapshot folder and picture its first page.
/// Debug builds only, like the harness.
@MainActor
enum SheetSnapshots {
    /// The PDF the `contactSheetFile` step saved, until it is pictured.
    private static var savedSheet: URL?
    private static var saveProblem: String?

    /// Puts the window in the step's state; returns the window to picture,
    /// nil when the sheet didn't open.
    static func enter(_ step: SnapshotPlan.Step, window: NSWindow, library: Library, perform: (KeyCommand) -> Bool,
                      outputFolder: URL) async -> NSWindow? {
        // A sheet of every photo in the folder says more than one.
        if step != .print { library.selectAllVisible() }
        switch step {
        case .contactSheet, .contactSheetFile:
            _ = perform(.contactSheet)
            guard await wait(upTo: 20, until: { ContactSheetPresenter.current != nil && window.attachedSheet?.isVisible == true }),
                  let presenter = ContactSheetPresenter.current else { return nil }
            // Thumbnails arrive and the preview is drawn again.
            _ = await wait(upTo: 10, until: { presenter.model.preview != nil })
            guard step == .contactSheetFile else { return window }
            var settings = presenter.model.settings
            settings.format = .pdf
            presenter.model.settings = settings
            presenter.debugDestination = outputFolder
            savedSheet = outputFolder.appendingPathComponent(
                ContactSheetNaming.fileName(title: presenter.model.title, format: .pdf))
            saveProblem = nil
            presenter.saveForSnapshot()
            let finished = await wait(upTo: 120, until: { !presenter.model.isSaving && ContactSheetPresenter.current == nil
                || presenter.model.errorMessage != nil })
            if let error = presenter.model.errorMessage { saveProblem = error } else if !finished { saveProblem = "save timed out" }
            return window
        case .print:
            _ = perform(.print)
            guard await wait(upTo: 20, until: { window.attachedSheet?.isVisible == true }) else { return nil }
            return window
        default:
            return window
        }
    }

    static func leave(_ step: SnapshotPlan.Step, window: NSWindow) {
        switch step {
        case .contactSheet, .contactSheetFile:
            ContactSheetPresenter.current?.close()
        case .print:
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
        default:
            break
        }
    }

    /// Page 1 of the saved PDF, drawn at 1.5 px per point, written to `url`.
    /// Returns what went wrong, or nil.
    static func pictureContactSheetFile(to url: URL) async -> String? {
        if let saveProblem { return saveProblem }
        guard let pdf = savedSheet, let document = CGPDFDocument(pdf as CFURL), let page = document.page(at: 1) else {
            return "no saved PDF to picture"
        }
        let box = page.getBoxRect(.mediaBox)
        let scale = 1.5
        guard let context = CGContext(data: nil, width: Int(box.width * scale), height: Int(box.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return "no bitmap" }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.scaleBy(x: scale, y: scale)
        context.drawPDFPage(page)
        guard let image = context.makeImage(), SnapshotHarness.write(image, to: url) else { return "could not write \(url.path)" }
        return nil
    }

    private static func wait(upTo seconds: Double, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }
}
#endif
