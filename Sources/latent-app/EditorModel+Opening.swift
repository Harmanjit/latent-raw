import SwiftUI
import UniformTypeIdentifiers
import RawCore
import PixelEngine

extension EditorModel {
    // MARK: - Opening

    /// True when a file was chosen and is being opened; false on Cancel.
    @discardableResult
    func showOpenPanel() -> Bool {
        guard isReady else { return false }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a raw file or a JPEG, HEIC, TIFF or PNG"
        // Raw formats mostly lack registered UTTypes, so filter loosely and
        // let RawFile reject anything LibRaw can't read.
        panel.allowedContentTypes = [UTType.image]
        panel.allowsOtherFileTypes = true

        guard panel.runModal() == .OK, let url = panel.url else { return false }
        open(url: url)
        return true
    }

    /// `userRotation` and `editStackJSON` are the catalog's stored state
    /// for this image, if it came from one; `catalogImageID` lets edits
    /// made here be saved back.
    func open(url: URL, userRotation: Int = 0, catalogImageID: Int64? = nil,
              editStackJSON: String? = nil) {
        guard let gpu = gpuContext else {
            if setupError == nil {
                // The caller reads this image's history next and finds no
                // open image to give it to: it is parked and loaded after
                // the open (`loadHistory(steps:snapshots:forImage:)`).
                deferredOpenCatalogImageID = catalogImageID
                deferredHistory = nil
                openWhenGPUReady = { [weak self] in
                    self?.open(url: url, userRotation: userRotation, catalogImageID: catalogImageID,
                               editStackJSON: editStackJSON)
                    self?.loadDeferredHistory()
                }
            }
            return
        }
        resetToolStateForNewImage()
        flushPendingSave()
        // The analysis and the tool belong to the image being left.
        dustImageWillChange()
        status = "Opening \(url.lastPathComponent)…"
        do {
            let file = try RawFile(path: url.path)
            let newSession = try ImageSession(file: file, gpu: gpu)
            // Only once the image has opened: until then the parameters and
            // history on hand are the previous photo's.
            self.catalogImageID = catalogImageID
            session = newSession
            resetTouchUpForNewImage()
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
            newerEditImageID = nil
            if let editStackJSON {
                do {
                    let stack = try newSession.stackForThisImage(EditStack.decode(json: editStackJSON))
                    restored = stack.parameters(defaults: fresh)
                    if restored.whiteBalance.isAsShot { restored.whiteBalance = fresh.whiteBalance }
                } catch EditStack.DecodeError.newerSchema(let found) {
                    // Saving would overwrite the newer edit with this
                    // build's format, so this image is not saved back.
                    newerEditImageID = catalogImageID
                    reportFailure("Reading the stored edit for \(url.lastPathComponent) (showing defaults; "
                                  + "changes here won't be saved)", EditStack.DecodeError.newerSchema(found))
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
            } else if let rendered = file.summary.renderedImage {
                status = Self.renderedImageStatus(rendered, summary: file.summary)
            } else {
                status = "\(file.summary.cameraMake) \(file.summary.cameraModel) · " +
                         "\(file.summary.rawWidth)×\(file.summary.rawHeight)"
            }
            // The last image's encodings, per model, answer nothing here.
            resetPromptSessions()
            modelMaskGeometryTask?.cancel()
            modelMaskGeometryTask = nil
            modelMaskGeometry = [:]
            modelMaskShapes = [:]
            history = EditHistory(initial: EditStack(parameters: parameters))
            snapshots = []
            // Nothing of this image's stored history is on hand until
            // ContentView's read of it arrives (`loadHistory`).
            storedHistoryLoaded = false
            undecodableHistorySteps = []
            undecodableSnapshots = []
            stopAIDenoise()
            aiDenoiseReleasedUnderPressure = false
            dustImageDidOpen()
            rerender()
            regenerateMissingAIMasks()
            regenerateTouchUpMasksIfNeeded()
            regenerateAIDenoiseIfNeeded()
        } catch {
            // Nothing of the previous photo may outlive a failed open: with
            // its id, history or denoise run still here, Undo or a history
            // load would write that photo's edit onto this one.
            closeImage()
            status = "Could not open: \(error)"
        }
    }

    /// What the tools hold about the photo being left: the selected patch,
    /// spot and local (an index into that photo's lists, which would pick
    /// whatever sits at the same index on the next), a drag or stroke in
    /// progress (which would be committed onto the next photo at the old
    /// one's coordinates), the mask tool aimed at the old local, and the
    /// crop the straighten slider started from. The heal, red-eye and crop
    /// tools themselves stay armed, as before.
    func resetToolStateForNewImage() {
        selectedHealIndex = nil
        selectedRedEyeIndex = nil
        selectedPointColour = nil
        pointColourPicking = false
        if selectedLocalIndex != nil { selectedLocalIndex = nil }
        maskTool = .none
        isDraggingMask = false
        lastDab = nil
        healDrag = nil
        redEyeDrag = nil
        paintingHealStroke = []
        straightenBase = nil
    }
}
