import SwiftUI
import UniformTypeIdentifiers
import RawCore
import PixelEngine

extension EditorModel {
    // MARK: - Opening

    func showOpenPanel() {
        guard isReady else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a raw file"
        // Raw formats mostly lack registered UTTypes, so filter loosely and
        // let RawFile reject anything LibRaw can't read.
        panel.allowedContentTypes = [UTType.image]
        panel.allowsOtherFileTypes = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    /// `userRotation` and `editStackJSON` are the catalog's stored state
    /// for this image, if it came from one; `catalogImageID` lets edits
    /// made here be saved back.
    func open(url: URL, userRotation: Int = 0, catalogImageID: Int64? = nil,
              editStackJSON: String? = nil) {
        guard let gpu = gpuContext else {
            if setupError == nil {
                openWhenGPUReady = { [weak self] in
                    self?.open(url: url, userRotation: userRotation, catalogImageID: catalogImageID,
                               editStackJSON: editStackJSON)
                }
            }
            return
        }
        flushPendingSave()
        self.catalogImageID = catalogImageID
        status = "Opening \(url.lastPathComponent)…"
        do {
            let file = try RawFile(path: url.path)
            let newSession = try ImageSession(file: file, gpu: gpu)
            session = newSession
            sourceURL = url
            imageTitle = url.lastPathComponent
            asShotWhiteBalance = newSession.asShotWhiteBalance
            preview = nil
            tile = nil
            previewQuads = 0
            tileSize = .zero
            cameraRotation = ImageRotation(libRawFlip: file.summary.orientation)
            self.userRotation = ((userRotation % 4) + 4) % 4

            // A new image always opens fitted.
            fitMode = true
            viewport = .fit(imageSize: imageSize, drawableSize: drawableSize)

            // Start from the camera's own white balance, expressed as
            // temperature and tint so the sliders show something meaningful
            // rather than a default the photo was never shot under. Then
            // lay the stored edit, if any, over that.
            var fresh = EditParameters()
            fresh.whiteBalance = newSession.asShotWhiteBalance
            defaultParameters = fresh
            var restored = fresh
            if let editStackJSON {
                do {
                    let stack = try EditStack.decode(json: editStackJSON)
                    restored = stack.parameters(defaults: fresh)
                    if restored.whiteBalance.isAsShot { restored.whiteBalance = fresh.whiteBalance }
                } catch {
                    // Showing defaults is the only option, but the user must
                    // know the stored edit exists and wasn't applied.
                    reportFailure("Reading the stored edit for \(url.lastPathComponent) (showing defaults; editing will replace it)", error)
                }
            }
            pendingSave?.cancel()   // the assignment below must not save
            pendingSave = nil
            parameters = restored   // triggers rerender via didSet
            pendingSave?.cancel()
            pendingSave = nil
            joinLinkedPane()   // after the crop is restored: it sets the canvas

            if newSession.profile == nil {
                status = "No colour profile for \(file.summary.cameraModel) — cannot render"
            } else {
                status = "\(file.summary.cameraMake) \(file.summary.cameraModel) · " +
                         "\(file.summary.rawWidth)×\(file.summary.rawHeight)"
            }
            sam2Session = nil
            sam2Encoding?.cancel()
            sam2Encoding = nil
            sam2Status = ""
            history = EditHistory(initial: EditStack(parameters: parameters))
            snapshots = []
            aiDenoiseTask?.cancel()
            aiDenoiseRunning = false
            aiDenoiseStatus = ""
            rerender()
            regenerateMissingAIMasks()
            regenerateAIDenoiseIfNeeded()
        } catch {
            session = nil
            sourceURL = nil
            preview = nil
            tile = nil
            histogram = nil
            imageTitle = nil
            status = "Could not open: \(error)"
        }
    }
}
