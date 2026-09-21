import Foundation
import CoreGraphics
import PixelEngine

/// Find Faces and the regeneration of a stored face list into the region
/// masks the touch-up stage samples (docs/Retouch.md §7). Wave 1 (W1-E)
/// fills the bodies in; until then no face is found and a stored face
/// keeps an empty mask, which the stage renders as no change.
public enum TouchUpRegions {
    public struct Found: Sendable {
        /// Raw-grid boxes, left to right.
        public var faces: [TouchUpFace]
        public var tooSmall: Int
        public var masks: TouchUpMaskSet
        /// 40 pt upright crops.
        public var thumbnails: [UUID: SendableImage]

        public init(faces: [TouchUpFace], tooSmall: Int, masks: TouchUpMaskSet, thumbnails: [UUID: SendableImage]) {
            self.faces = faces
            self.tooSmall = tooSmall
            self.masks = masks
            self.thumbnails = thumbnails
        }
    }

    /// Find Faces: detect, map boxes output → raw (rawSensorPoint), refit
    /// from those seeds, build masks.
    public static func find(in render: TouchUpAnalysis.Render, session: ImageSession, pipeline: RenderPipeline,
                            parameters: EditParameters) -> Found {
        Found(faces: [], tooSmall: 0, masks: emptyMasks(for: session), thumbnails: [:])
    }

    /// Regeneration: stored raw boxes → output grid (outputSensorPoint) →
    /// seeded refit → masks; `missing` are faces kept with an empty mask
    /// because Vision could not refit them.
    public static func build(_ touchUp: TouchUp, from render: TouchUpAnalysis.Render, session: ImageSession,
                             pipeline: RenderPipeline, parameters: EditParameters) -> (masks: TouchUpMaskSet, missing: [UUID]) {
        (emptyMasks(for: session), [])
    }

    /// ExportWorker's entry: render + build + session.setTouchUpMasks;
    /// no-op unless touchUp.wantsMasks. Nothing runs yet, so the session
    /// is left as it is and no face is reported missing.
    @discardableResult
    public static func regenerate(_ touchUp: TouchUp, session: ImageSession, pipeline: RenderPipeline, gpu: GPUContext,
                                  parameters: EditParameters, rotation: ImageRotation) throws -> [UUID] {
        []
    }

    /// A set with no faces at the session's half-res size.
    static func emptyMasks(for session: ImageSession) -> TouchUpMaskSet {
        let size = TouchUpMaskSet.size(sensorWidth: Int(session.file.summary.rawWidth),
                                       sensorHeight: Int(session.file.summary.rawHeight))
        return TouchUpMaskSet(faces: [], width: size.width, height: size.height,
                              modelVersion: FaceLandmarker.modelVersion)
    }
}

/// CGImage across a detached task (the public form of the app's wrapper).
/// CGImage is immutable, but the SDK doesn't say it is Sendable.
public struct SendableImage: @unchecked Sendable {
    public let cgImage: CGImage
    public init(cgImage: CGImage) { self.cgImage = cgImage }
}
