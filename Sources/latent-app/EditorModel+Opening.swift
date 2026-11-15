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
    ///
    /// Decodes on the calling (main) thread unless the file is already in
    /// `decodeCache`; the catalog's opens use the asynchronous
    /// `open(url:userRotation:catalogImageID:readEdit:isCurrent:)` below,
    /// which never blocks main on the decode. Kept for Open File…, a file
    /// opened from Finder, the Compare and Survey panes, and tests, which
    /// expect the image open on return.
    func open(url: URL, userRotation: Int = 0, catalogImageID: Int64? = nil,
              editStackJSON: String? = nil) {
        // Any open still decoding is older than this one.
        openGeneration += 1
        openingPlaceholder = nil
        guard let gpu = gpuForOpeningNow() else {
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
        let file: RawFile
        do {
            file = try decodeCache.decodedFile(for: url) ?? Self.decodeForOpening(url)
        } catch {
            failOpen(url: url, error)
            return
        }
        apply(file, url: url, userRotation: userRotation, catalogImageID: catalogImageID,
              editStackJSON: editStackJSON, gpu: gpu)
    }

    /// How an asynchronous open ended.
    enum OpenOutcome: Equatable {
        /// The photo is open.
        case opened
        /// A newer open or a close came first, or the caller's photo is no
        /// longer wanted (`isCurrent`): nothing changed.
        case superseded
        /// The decode or the GPU failed; the editor says so and has closed
        /// the previous photo.
        case failed
        /// `readEdit` threw: nothing was opened, so that the next save
        /// can't replace the edit that couldn't be read. The caller reports it.
        case editUnreadable
    }

    /// Opens a catalog photo without blocking the main thread on its
    /// decode (plan fixes #7, #9, #17). The decode starts at once on a
    /// background thread, beside `readEdit` (the stored edit's read) and,
    /// at launch, the GPU's start; the photo is laid in place on main once
    /// all three are done. Until then the previous photo stays on screen
    /// and in the editor, with, if `placeholder` is set (Loupe), the
    /// camera's embedded JPEG over it (#18).
    ///
    /// Latest wins: an open, a synchronous `open` or `closeImage` started
    /// meanwhile makes this one return `.superseded` without touching
    /// anything, as does `isCurrent` turning false (the selection moved on
    /// or another catalog opened). Its decode, if it hasn't begun, is
    /// dropped by the newer open.
    func open(url: URL, userRotation: Int = 0, catalogImageID: Int64?,
              placeholder: Bool = false,
              readEdit: @MainActor () async throws -> String?,
              isCurrent: @escaping @MainActor () -> Bool = { true }) async -> OpenOutcome {
        // Already passed by (a held arrow key): don't disturb the newer
        // open's decode.
        guard isCurrent() else { return .superseded }
        openGeneration += 1
        let generation = openGeneration
        let stillWanted: @MainActor () -> Bool = { [weak self] in self?.openGeneration == generation && isCurrent() }
        openingPlaceholder = nil
        let statusBefore = status
        status = "Opening \(url.lastPathComponent)…"
        let job = decodeCache.jobForOpening(url)
        // Not for a photo already decoded (a neighbour kept): it opens at once.
        let placeholderImage = placeholder && !job.isFinished
            ? Self.startPlaceholder(url: url, userRotation: userRotation) : nil
        // Set once the photo is in place: a placeholder decoded later than
        // the raw must not cover the render.
        let applied = OpenProgress()
        // An open that ends here without laying its photo in place takes
        // back what it put up: its "Opening…" status and the camera's JPEG,
        // unless a newer open has replaced them. A placeholder still
        // decoding is never shown (`applied.done`). Without this, a photo
        // filtered out while it decoded left its JPEG over the previous
        // photo until some later open.
        let abandon = { [weak self] in
            applied.done = true
            guard let self, self.openGeneration == generation else { return }
            self.openingPlaceholder = nil
            self.status = statusBefore
        }

        let editStackJSON: String?
        do {
            editStackJSON = try await readEdit()
        } catch {
            abandon()
            return .editUnreadable
        }
        guard stillWanted() else { abandon(); return .superseded }

        // The camera's JPEG matches the render's framing only without a
        // crop or perspective change; with one it would jump, so the
        // previous photo stays until the render instead.
        if let placeholderImage, Self.placeholderMatchesFraming(editStackJSON) {
            Task { [weak self] in
                guard let image = await placeholderImage.value, let self, stillWanted(), !applied.done else { return }
                self.openingPlaceholder = image
            }
        }

        guard let gpu = await gpuForOpening() else {
            let failed = stillWanted()
            abandon()
            return failed ? .failed : .superseded
        }
        guard stillWanted() else { abandon(); return .superseded }
        let file: RawFile
        do {
            file = try await job.value()
        } catch {
            guard stillWanted() else { abandon(); return .superseded }
            applied.done = true
            failOpen(url: url, error)
            return .failed
        }
        guard stillWanted() else { abandon(); return .superseded }
        applied.done = true
        apply(file, url: url, userRotation: userRotation, catalogImageID: catalogImageID,
              editStackJSON: editStackJSON, gpu: gpu)
        return hasImage ? .opened : .failed
    }

    /// Starts decoding `url` for an open about to be asked for from a new
    /// task. A task begins only once the main thread is free, which at
    /// launch is after the window's first layout (about 400 ms); the
    /// decode needn't wait for that. The open picks up the same decode.
    func startDecoding(_ url: URL) {
        _ = decodeCache.jobForOpening(url)
    }

    /// Decodes `urls` (the neighbours of the photo just opened) ahead of
    /// time, so stepping to one needs no decode. Others kept are dropped
    /// past the cache's budget.
    func prefetch(_ urls: [URL]) {
        decodeCache.prefetch(urls, keeping: sourceURL)
    }

    /// The GPU context if it can be had now: the model's own, or the shared
    /// one already built but not yet attached, because the launch task that
    /// attaches it waits behind the first layout of the window (plan fix #9).
    func gpuForOpeningNow() -> GPUContext? {
        if gpuContext == nil, let built = Self.builtSharedGPU() { attachGPU(built) }
        return gpuContext
    }

    /// The shared context if its build has ended; tests stand in a launch
    /// whose build is still running.
    static var builtSharedGPU: () -> Result<GPUContext, any Error>? = { GPUContext.sharedIfBuilt }

    /// The GPU context, waiting for its build if it is still running.
    /// nil if it failed (`setupError`).
    func gpuForOpening() async -> GPUContext? {
        if let gpu = gpuForOpeningNow() { return gpu }
        guard setupError == nil else { return nil }
        do {
            attachGPU(.success(try await GPUContext.shared()))
        } catch {
            attachGPU(.failure(error))
        }
        return gpuContext
    }

    /// The decode or session failed. Nothing of the previous photo may
    /// outlive a failed open: with its id, history or denoise run still
    /// here, Undo or a history load would write that photo's edit onto
    /// this one.
    private func failOpen(url: URL, _ error: any Error) {
        closeImage()
        status = "Could not open: \(error)"
    }

    /// Lays a decoded photo in place: its session, stored edit, history
    /// and tools, then one render.
    private func apply(_ file: RawFile, url: URL, userRotation: Int, catalogImageID: Int64?,
                       editStackJSON: String?, gpu: GPUContext) {
        resetToolStateForNewImage()
        flushPendingSave()
        // The analysis and the tool belong to the image being left.
        dustImageWillChange()
        status = "Opening \(url.lastPathComponent)…"
        do {
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
            // Its didSet keeps its other work (crop, masks, touch-up) but
            // not its render: the one below renders once everything is in
            // place (plan fix #8; it used to render twice).
            applyingOpenedImage = true
            parameters = restored
            applyingOpenedImage = false
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
            // Nothing is being dragged: the high-quality preview, if on,
            // follows this render without the settle delay (plan fix #10).
            highQualityPreviewFollowsOpen = true
            rerender()
            openingPlaceholder = nil
            regenerateMissingAIMasks()
            regenerateTouchUpMasksIfNeeded()
            regenerateDepthMapIfNeeded()
            regenerateReflectionMapIfNeeded()
            regenerateAIDenoiseIfNeeded()
            ensureFlatFieldGainMap()
        } catch {
            applyingOpenedImage = false
            failOpen(url: url, error)
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

/// Whether an asynchronous open has laid its photo in place.
@MainActor
private final class OpenProgress {
    var done = false
}
