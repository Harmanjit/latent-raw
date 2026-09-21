import CoreGraphics
import Foundation
import simd
import PixelEngine
import MLKit

// Touch-up in the editor (docs/Retouch.md §7): Find Faces, the region
// masks' regeneration, blemishes, and the touch-up tool's clicks.
//
// The analysis render is made on the main actor, as red-eye's is: one
// binned render and a readback, well under the time the status line
// takes to say "Looking for faces…". The Vision pass and the mask
// building, which take a second or more, run in a detached task, and
// what comes back is applied only if the same image is still open.
extension EditorModel {
    // MARK: - What runs off the main actor

    /// The open image as the face passes need it off the main actor. The
    /// session and the pipeline are not Sendable; the passes only read
    /// the file's summary and the lens map, which are fixed once the
    /// image is open, and the completion checks the image is still the
    /// one open before it touches anything.
    struct TouchUpContext: @unchecked Sendable {
        let session: ImageSession
        let pipeline: RenderPipeline
        let parameters: EditParameters
    }

    /// The three passes, as one replaceable value so TouchUpToolTests can
    /// stand drawn faces in for Vision.
    struct TouchUpPasses: Sendable {
        var find: @Sendable (TouchUpAnalysis.Render, TouchUpContext) -> TouchUpRegions.Found
        var build: @Sendable (TouchUp, TouchUpAnalysis.Render, TouchUpContext) -> (masks: TouchUpMaskSet, missing: [UUID])
        var blemishes: @Sendable (TouchUpAnalysis.Render, TouchUpMaskSet, TouchUp, [HealPatch], TouchUpContext) -> [HealPatch]

        static let live = TouchUpPasses(
            find: { render, image in
                TouchUpRegions.find(in: render, session: image.session, pipeline: image.pipeline,
                                    parameters: image.parameters)
            },
            build: { touchUp, render, image in
                TouchUpRegions.build(touchUp, from: render, session: image.session, pipeline: image.pipeline,
                                     parameters: image.parameters)
            },
            blemishes: { render, masks, touchUp, existing, image in
                BlemishFinder.find(in: render, masks: masks, touchUp: touchUp, existing: existing,
                                   session: image.session, pipeline: image.pipeline, parameters: image.parameters)
            })
    }

    /// Vision and the blob detector; a test swaps in its own faces.
    static var touchUpPasses = TouchUpPasses.live

    /// How long a geometry slider rests before the masks are built again.
    static let touchUpGeometryDebounce: Duration = .milliseconds(300)

    /// The analysis render of the open image, or nil with the failure in
    /// the status bar.
    private func touchUpRender(_ what: String) -> (TouchUpAnalysis.Render, TouchUpContext)? {
        guard let session, let pipeline, let gpu = gpuContext else { return nil }
        do {
            let render = try TouchUpAnalysis.render(session: session, pipeline: pipeline, gpu: gpu,
                                                    parameters: parameters, rotation: rotation)
            return (render, TouchUpContext(session: session, pipeline: pipeline, parameters: parameters))
        } catch {
            status = "\(what) failed: \(error)"
            touchUpStatus = ""
            return nil
        }
    }

    // MARK: - Find Faces

    /// Finds the faces on this Mac and replaces the module's list with
    /// them, as one history step; the region masks and a thumbnail per
    /// face come with them. With `thenBlemishes`, Find Blemishes follows
    /// on the faces found (a pasted edit that removes blemishes).
    func findFaces(thenBlemishes: Bool = false) {
        guard hasImage, !findingFaces else { return }
        // A slider moved a moment ago is its own history step; the faces
        // are one of their own.
        flushPendingSave()
        guard let (render, image) = touchUpRender("Finding faces") else { return }
        touchUpMaskTask?.cancel()
        touchUpMaskTask = nil
        findingFaces = true
        status = "Looking for faces…"
        touchUpStatus = status
        let session = image.session
        let passes = Self.touchUpPasses
        Task { @MainActor [weak self] in
            let found = await Task.detached(priority: .userInitiated) { passes.find(render, image) }.value
            guard let self else { return }
            self.findingFaces = false
            // The user may have moved to another image meanwhile.
            guard self.session === session else { return }
            session.setTouchUpMasks(found.masks)
            self.faceThumbnails = found.thumbnails.mapValues(\.cgImage)
            self.touchUpGeometryKey = Self.touchUpGeometryKey(of: self.parameters)
            self.touchUpReleasedUnderPressure = false
            var touchUp = self.parameters.touchUp
            touchUp.faces = found.faces
            touchUp.modelVersion = FaceLandmarker.modelVersion
            self.parameters.touchUp = touchUp
            self.flushPendingSave()   // the one step, "Touch-up"
            self.status = SpokenText.facesFound(found: found.faces.count, tooSmall: found.tooSmall)
            self.touchUpStatus = self.status
            Announcement.post(self.status)
            if thenBlemishes, !found.faces.isEmpty { self.findBlemishes(using: render, image: image) }
        }
    }

    /// A pasted or preset touch-up keeps its sliders but not the faces
    /// they were found on (they belong to the other photo), so an edit
    /// that would retouch looks for this photo's faces at once. The lead
    /// calls this at the end of `apply`.
    func findFacesIfPastedTouchUpNeedsThem() {
        guard hasImage, FaceFindJob.needsFaces(parameters.touchUp) else { return }
        findFaces(thenBlemishes: parameters.touchUp.blemishRemoval)
    }

    // MARK: - Regeneration

    /// The lens and keystone settings the masks were built for. A change
    /// moves every pixel of the output grid the masks are sampled on, so
    /// they are built again from the stored raw-grid boxes; a face toggle
    /// or a slider is not in it and only rebuilds the texture.
    static func touchUpGeometryKey(of p: EditParameters) -> String {
        "\(p.lensDistortion) \(p.lensTCA) \(p.manualDistortion) \(p.perspective.vertical) \(p.perspective.horizontal)"
    }

    /// Builds the region masks for the stored faces when the stage needs
    /// them (an enabled face and a slider) and the session has none: on
    /// open, when a slider first leaves zero, and when memory recovers.
    /// `force` builds them again although the session has some: the
    /// geometry changed. A face Vision cannot find again keeps its box
    /// with an empty mask and is named in the status bar.
    func regenerateTouchUpMasksIfNeeded(force: Bool = false) {
        guard let session, parameters.touchUp.wantsMasks, !findingFaces, !touchUpReleasedUnderPressure else { return }
        guard force || (!session.hasTouchUpMasks && touchUpMaskTask == nil) else { return }
        guard let (render, image) = touchUpRender("Touch-up masks") else { return }
        touchUpMaskTask?.cancel()
        let touchUp = parameters.touchUp
        let key = Self.touchUpGeometryKey(of: parameters)
        let passes = Self.touchUpPasses
        touchUpMaskTask = Task { @MainActor [weak self] in
            let built = await Task.detached(priority: .userInitiated) { passes.build(touchUp, render, image) }.value
            guard let self, !Task.isCancelled, self.session === session else { return }
            self.touchUpMaskTask = nil
            session.setTouchUpMasks(built.masks)
            self.touchUpGeometryKey = key
            if self.faceThumbnails.isEmpty {
                self.faceThumbnails = Self.faceThumbnails(for: touchUp.faces, render: render, image: image)
            }
            self.rerender()
            for id in built.missing {
                let number = (touchUp.faces.firstIndex { $0.id == id } ?? 0) + 1
                self.status = "Face \(number) could not be found again"
                self.touchUpStatus = self.status
                Announcement.post(self.status)
            }
        }
    }

    /// Called from `parameters`' didSet with the previous value (the lead
    /// wires it). A slider leaving zero with no masks on the session
    /// builds them; a geometry change builds them again 300 ms after the
    /// last change, so a drag doesn't rebuild on every tick.
    func touchUpParametersDidChange(from old: EditParameters) {
        guard let session, hasImage else { return }
        let touchUp = parameters.touchUp
        if touchUp.wantsMasks, !session.hasTouchUpMasks {
            regenerateTouchUpMasksIfNeeded()
            return
        }
        let key = Self.touchUpGeometryKey(of: parameters)
        guard key != Self.touchUpGeometryKey(of: old), touchUp.wantsMasks, key != touchUpGeometryKey else { return }
        touchUpMaskTask?.cancel()
        touchUpMaskTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.touchUpGeometryDebounce)
            guard let self, !Task.isCancelled else { return }
            self.touchUpMaskTask = nil
            guard Self.touchUpGeometryKey(of: self.parameters) != self.touchUpGeometryKey else { return }
            self.regenerateTouchUpMasksIfNeeded(force: true)
        }
    }

    /// Critical memory pressure dropped the session's mask set (the lead
    /// calls this after `session.releaseMemory(for:)`). Nothing is built
    /// in the middle of the shortage; `touchUpMemoryDidRecover` does.
    func touchUpMemoryDidDrop() {
        guard let session, session.droppedTouchUpMasks else { return }
        touchUpMaskTask?.cancel()
        touchUpMaskTask = nil
        touchUpReleasedUnderPressure = true
        if parameters.touchUp.wantsMasks {
            status = "Memory is low: touch-up will show again when memory recovers"
            touchUpStatus = status
        }
    }

    /// Memory pressure is back to normal (the lead calls this at
    /// `.normal`): the masks pressure took are built again.
    func touchUpMemoryDidRecover() {
        guard touchUpReleasedUnderPressure else { return }
        touchUpReleasedUnderPressure = false
        regenerateTouchUpMasksIfNeeded()
    }

    /// Nothing of the previous photo's touch-up may outlive it (the lead
    /// calls this from `open` and `closeImage`): a build under way for it
    /// is dropped, and the thumbnails, the tool and the captions go.
    func resetTouchUpForNewImage() {
        touchUpMaskTask?.cancel()
        touchUpMaskTask = nil
        touchUpGeometryKey = nil
        touchUpReleasedUnderPressure = false
        selectedBlemishIndex = nil
        faceThumbnails = [:]
        touchUpStatus = ""
        if showSkinMask { showSkinMask = false }
    }

    /// Show Skin Mask: the display pass tints the skin the sliders work
    /// on (`RenderOutput.touchUpOverlay`, set from `displayOutput` by the
    /// lead). The stage only runs with an enabled face and a slider up,
    /// so the tint needs the same.
    var touchUpOverlayWanted: Bool { showSkinMask && parameters.touchUp.wantsMasks }

    // MARK: - Blemishes

    /// Looks for spots on the enabled faces' skin and replaces the
    /// blemish list with them, as one history step, switching Remove
    /// Blemishes on so they show.
    func findBlemishes() {
        guard hasImage, !findingBlemishes, !findingFaces else { return }
        guard !parameters.touchUp.enabledFaceIDs.isEmpty else {
            status = "Find Faces first: there is no face to look for blemishes on"
            return
        }
        flushPendingSave()
        guard let (render, image) = touchUpRender("Finding blemishes") else { return }
        findBlemishes(using: render, image: image)
    }

    private func findBlemishes(using render: TouchUpAnalysis.Render, image: TouchUpContext) {
        let session = image.session
        findingBlemishes = true
        status = "Looking for blemishes…"
        touchUpStatus = status
        let touchUp = parameters.touchUp
        // The user's patches and the dust spots: a blob under one of them
        // is healed already.
        let existing = parameters.heals + parameters.dust
        let masks = session.touchUpMasks
        let passes = Self.touchUpPasses
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (masks: TouchUpMaskSet, blemishes: [HealPatch]) in
                // Without masks on the session (sliders at zero since the
                // image opened) they are built here, and kept.
                let set = masks ?? passes.build(touchUp, render, image).masks
                return (set, passes.blemishes(render, set, touchUp, existing, image))
            }.value
            guard let self else { return }
            self.findingBlemishes = false
            guard self.session === session else { return }
            if !session.hasTouchUpMasks {
                session.setTouchUpMasks(result.masks)
                self.touchUpGeometryKey = Self.touchUpGeometryKey(of: self.parameters)
            }
            var touchUp = self.parameters.touchUp
            touchUp.blemishes = result.blemishes
            touchUp.blemishRemoval = true
            self.selectedBlemishIndex = nil
            self.parameters.touchUp = touchUp
            self.flushPendingSave()
            self.status = SpokenText.blemishesFound(result.blemishes.count)
            self.touchUpStatus = self.status
            Announcement.post(self.status)
        }
    }

    func clearBlemishes() {
        parameters.touchUp.blemishes = []
        selectedBlemishIndex = nil
    }

    var selectedBlemish: HealPatch? {
        guard let i = selectedBlemishIndex, i < parameters.touchUp.blemishes.count else { return nil }
        return parameters.touchUp.blemishes[i]
    }

    var hasSelectedBlemish: Bool { selectedBlemish != nil }

    /// Keeps the selected spot: its patch goes (⌫, and VoiceOver's "Keep
    /// selected spot").
    func deleteSelectedBlemish() {
        guard let i = selectedBlemishIndex, i < parameters.touchUp.blemishes.count else { return }
        removeBlemish(at: i)
    }

    private func removeBlemish(at i: Int) {
        parameters.touchUp.blemishes.remove(at: i)
        let count = parameters.touchUp.blemishes.count
        selectedBlemishIndex = count == 0 ? nil : min(i, count - 1)
    }

    // MARK: - The touch-up tool

    /// The blemish whose ring is under `p` (normalised sensor): the
    /// selected one first, then the most recent on top, grabbed within
    /// its radius or the usual few screen pixels.
    private func hitBlemish(_ p: SIMD2<Float>) -> Int? {
        let size = SIMD2(Float(sensorSize.width), Float(sensorSize.height))
        let short = min(size.x, size.y)
        let grab = HealStrokeHandle.minimumGrabPixels / Float(max(viewport.zoom, 1e-6))
        let blemishes = parameters.touchUp.blemishes
        var order = Array(blemishes.indices.reversed())
        if let s = selectedBlemishIndex, let k = order.firstIndex(of: s) { order.remove(at: k); order.insert(s, at: 0) }
        for i in order {
            let patch = blemishes[i]
            if simd_length((p - patch.target) * size) <= max(patch.radius * short, grab) { return i }
        }
        return nil
    }

    /// The enabled face whose box holds `p` (raw grid, as the viewport's
    /// sensor coordinates are taken for the spot tools too).
    private func face(containing p: SIMD2<Float>) -> TouchUpFace? {
        parameters.touchUp.faces.first { face in
            let b = face.boundingBox
            return face.enabled && p.x >= b.x && p.y >= b.y && p.x <= b.x + b.z && p.y <= b.y + b.w
        }
    }

    /// Whether `p` is on the face's skin as the mask set has it; inside
    /// the box counts when no set has been built.
    private func isOnSkin(_ p: SIMD2<Float>, of face: TouchUpFace) -> Bool {
        guard let set = session?.touchUpMasks, let plane = set.faces.first(where: { $0.id == face.id }),
              plane.skin.count == plane.width * plane.height else { return true }
        let x = Int(p.x * Float(set.width)) - plane.origin.x, y = Int(p.y * Float(set.height)) - plane.origin.y
        guard x >= 0, y >= 0, x < plane.width, y < plane.height else { return false }
        return plane.skin[y * plane.width + x] > 127
    }

    /// A click with the touch-up tool armed: a ring keeps that spot (its
    /// patch goes), skin adds a patch 0.3 % of the face's width across
    /// with its source beside it on the skin.
    func touchUpToolBegan(at screen: CGPoint) {
        guard hasImage else { return }
        let p = sensorNormalized(screen)
        if let i = hitBlemish(p) {
            removeBlemish(at: i)
            return
        }
        guard let face = face(containing: p), isOnSkin(p, of: face) else { return }
        guard parameters.touchUp.blemishes.count < HealPatch.maximumBlemishCount else {
            status = "At most \(HealPatch.maximumBlemishCount) blemishes per image"
            return
        }
        let size = SIMD2(Float(sensorSize.width), Float(sensorSize.height))
        let short = min(size.x, size.y)
        let radius = max(0.003 * face.boundingBox.z * size.x, 1) / short
        // The source: 2.5 radii away on the skin, to the right first, as
        // Find Blemishes places one; beside it whatever is there when no
        // direction is on skin.
        let step = 2.5 * radius * short
        let directions: [SIMD2<Float>] = [
            SIMD2(1, 0), SIMD2(-1, 0), SIMD2(0, 1), SIMD2(0, -1),
            SIMD2(0.7071, 0.7071), SIMD2(-0.7071, 0.7071), SIMD2(0.7071, -0.7071), SIMD2(-0.7071, -0.7071)]
        let candidates = directions.map { simd_clamp(p + $0 * step / size, SIMD2(0, 0), SIMD2(1, 1)) }
        let source = candidates.first { self.face(containing: $0)?.id == face.id && isOnSkin($0, of: face) }
            ?? candidates[p.x + step / size.x > 1 ? 1 : 0]
        var touchUp = parameters.touchUp
        touchUp.blemishes.append(HealPatch(target: p, source: source, radius: radius, feather: 0.5, mode: .heal))
        touchUp.blemishRemoval = true
        parameters.touchUp = touchUp
        selectedBlemishIndex = touchUp.blemishes.count - 1
    }

    // MARK: - Thumbnails

    /// A 40 pt upright crop per stored face from the analysis render, for
    /// a photo opened with faces already found: the box goes to the output
    /// grid through the lens map, as the masks do.
    static func faceThumbnails(for faces: [TouchUpFace], render: TouchUpAnalysis.Render,
                               image: TouchUpContext) -> [UUID: CGImage] {
        let summary = image.session.file.summary
        let rawSize = SIMD2<Float>(Float(summary.rawWidth), Float(summary.rawHeight))
        let span = Float(render.span)
        var thumbnails: [UUID: CGImage] = [:]
        for face in faces {
            let b = face.boundingBox
            let corners = [SIMD2(b.x, b.y), SIMD2(b.x + b.z, b.y), SIMD2(b.x, b.y + b.w), SIMD2(b.x + b.z, b.y + b.w)]
                .map { corner in
                    image.pipeline.outputSensorPoint(forRawPoint: corner * rawSize, session: image.session,
                                                     parameters: image.parameters) / span
                }
            var lo = corners[0], hi = corners[0]
            for c in corners.dropFirst() { lo = simd_min(lo, c); hi = simd_max(hi, c) }
            let box = CGRect(x: CGFloat(lo.x), y: CGFloat(lo.y), width: CGFloat(hi.x - lo.x), height: CGFloat(hi.y - lo.y))
            if let thumbnail = faceThumbnail(from: render, box: box) { thumbnails[face.id] = thumbnail }
        }
        return thumbnails
    }

    /// The pixel side of a face row's 40 pt thumbnail at the Retina scale.
    static let faceThumbnailSide = 80

    /// A square around `box` (analysis px) turned the way the photo is
    /// shown and fitted into the thumbnail, as `TouchUpRegions` makes
    /// Find Faces' ones.
    static func faceThumbnail(from render: TouchUpAnalysis.Render, box: CGRect) -> CGImage? {
        let image = render.image
        let size = CGSize(width: image.width, height: image.height)
        let side = max(box.width, box.height) * 1.2
        let square = CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
            .intersection(CGRect(origin: .zero, size: size)).integral
        guard square.width >= 1, square.height >= 1, let crop = image.cropping(to: square),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: faceThumbnailSide, height: faceThumbnailSide, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let w = CGFloat(crop.width), h = CGFloat(crop.height)
        let upright = render.rotation.imageSize(forSensorSize: CGSize(width: w, height: h))
        let scale = CGFloat(faceThumbnailSide) / max(upright.width, upright.height)
        let drawn = CGSize(width: upright.width * scale, height: upright.height * scale)
        // Centre the upright crop, then turn the crop into it: the
        // transforms place the crop's top-left pixel where
        // `ImageRotation.imagePoint` puts it, in a y-up context.
        context.translateBy(x: (CGFloat(faceThumbnailSide) - drawn.width) / 2, y: (CGFloat(faceThumbnailSide) - drawn.height) / 2)
        context.scaleBy(x: scale, y: scale)
        switch render.rotation {
        case .none: break
        case .cw90: context.concatenate(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w))
        case .cw180: context.concatenate(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h))
        case .cw270: context.concatenate(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0))
        }
        context.interpolationQuality = .high
        context.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }
}
