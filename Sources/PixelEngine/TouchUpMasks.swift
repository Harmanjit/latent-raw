import Foundation
import CoreGraphics
import simd

/// The region masks the touch-up stage works on: per face, a skin, a
/// teeth and an eyes plane at half sensor resolution on the *output*
/// grid (the stage samples them by output position, like local masks).
///
/// MLKit builds a set from Vision's landmarks (`TouchUpRegions`); the
/// session keeps it and composites the enabled faces into one texture
/// (`ImageSession.touchUpMaskTexture`). It is session state, never
/// stored: the sidecar holds the face boxes, and the masks are rebuilt
/// from them on open.
public struct TouchUpMaskSet: Sendable, Equatable {
    public struct Face: Sendable, Equatable {
        public var id: UUID
        /// Half-res pixels on the OUTPUT grid.
        public var origin: SIMD2<Int>
        public var width: Int
        public var height: Int
        /// width × height each.
        public var skin: [UInt8]
        public var teeth: [UInt8]
        /// 255 sclera, 128 iris, 0 pupil.
        public var eyes: [UInt8]

        public init(id: UUID, origin: SIMD2<Int>, width: Int, height: Int,
                    skin: [UInt8], teeth: [UInt8], eyes: [UInt8]) {
            self.id = id
            self.origin = origin
            self.width = width
            self.height = height
            self.skin = skin
            self.teeth = teeth
            self.eyes = eyes
        }
    }

    public var faces: [Face]
    /// ceil(sensor / 2) on each axis.
    public var width: Int
    public var height: Int
    public var modelVersion: String

    public init(faces: [Face], width: Int, height: Int, modelVersion: String) {
        self.faces = faces
        self.width = width
        self.height = height
        self.modelVersion = modelVersion
    }

    /// The half-res size of a sensor.
    public static func size(sensorWidth: Int, sensorHeight: Int) -> (width: Int, height: Int) {
        (max(1, (sensorWidth + 1) / 2), max(1, (sensorHeight + 1) / 2))
    }

    /// The enabled faces composited (max on overlap) into three planes of
    /// width × height: what the mask texture holds. A face's rectangle is
    /// clipped to the set, so a box that reaches past the frame is safe.
    public func composite(enabled: Set<UUID>) -> (skin: [UInt8], teeth: [UInt8], eyes: [UInt8]) {
        let count = width * height
        var skin = [UInt8](repeating: 0, count: count)
        var teeth = [UInt8](repeating: 0, count: count)
        var eyes = [UInt8](repeating: 0, count: count)
        for face in faces where enabled.contains(face.id) {
            guard face.skin.count == face.width * face.height, face.teeth.count == face.skin.count,
                  face.eyes.count == face.skin.count else { continue }
            let x0 = max(0, face.origin.x), y0 = max(0, face.origin.y)
            let x1 = min(width, face.origin.x + face.width), y1 = min(height, face.origin.y + face.height)
            guard x1 > x0, y1 > y0 else { continue }
            for y in y0..<y1 {
                let row = (y - face.origin.y) * face.width - face.origin.x
                let out = y * width
                for x in x0..<x1 {
                    skin[out + x] = max(skin[out + x], face.skin[row + x])
                    teeth[out + x] = max(teeth[out + x], face.teeth[row + x])
                    eyes[out + x] = max(eyes[out + x], face.eyes[row + x])
                }
            }
        }
        return (skin, teeth, eyes)
    }

    /// A deterministic set for tests and goldens, from rectangles in
    /// normalised output-grid coordinates: skin is 255 inside `skin`,
    /// teeth 255 inside `teeth`, and each `eyes` rectangle is a sclera of
    /// 255 with a centred iris disc (128, radius 0.32 of its width) and a
    /// pupil disc (0, radius 0.16 of its width), as the real eyes plane is
    /// laid out. The face covers the union of its rectangles.
    public static func fixture(sensorWidth: Int, sensorHeight: Int,
                               faces: [(id: UUID, skin: CGRect, teeth: CGRect?, eyes: [CGRect])]) -> TouchUpMaskSet {
        let (width, height) = size(sensorWidth: sensorWidth, sensorHeight: sensorHeight)
        let scale = CGSize(width: width, height: height)
        // Whole half-res pixels of a normalised rectangle, clipped to the
        // set. A hair of slack so 0.4 + 0.2 lands on 300, not 301.
        func pixels(_ r: CGRect) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
            let slack = 1e-4
            let x0 = min(max(Int((r.minX * scale.width + slack).rounded(.down)), 0), width)
            let y0 = min(max(Int((r.minY * scale.height + slack).rounded(.down)), 0), height)
            let x1 = min(max(Int((r.maxX * scale.width - slack).rounded(.up)), x0), width)
            let y1 = min(max(Int((r.maxY * scale.height - slack).rounded(.up)), y0), height)
            return (x0, y0, x1, y1)
        }
        var built: [Face] = []
        for face in faces {
            let all = ([face.skin] + [face.teeth].compactMap { $0 } + face.eyes).reduce(CGRect.null) { $0.union($1) }
            let box = pixels(all)
            let w = box.x1 - box.x0, h = box.y1 - box.y0
            guard w > 0, h > 0 else { continue }
            var skin = [UInt8](repeating: 0, count: w * h)
            var teeth = [UInt8](repeating: 0, count: w * h)
            var eyes = [UInt8](repeating: 0, count: w * h)
            func fill(_ plane: inout [UInt8], _ r: CGRect, _ value: UInt8) {
                let p = pixels(r)
                for y in p.y0..<p.y1 {
                    for x in p.x0..<p.x1 { plane[(y - box.y0) * w + (x - box.x0)] = value }
                }
            }
            fill(&skin, face.skin, 255)
            if let t = face.teeth { fill(&teeth, t, 255) }
            for eye in face.eyes {
                fill(&eyes, eye, 255)
                let p = pixels(eye)
                let cx = Double(p.x0 + p.x1) / 2, cy = Double(p.y0 + p.y1) / 2
                let ew = Double(p.x1 - p.x0)
                let iris = 0.32 * ew, pupil = 0.16 * ew
                for y in p.y0..<p.y1 {
                    for x in p.x0..<p.x1 {
                        let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                        let d = (dx * dx + dy * dy).squareRoot()
                        if d <= pupil { eyes[(y - box.y0) * w + (x - box.x0)] = 0 }
                        else if d <= iris { eyes[(y - box.y0) * w + (x - box.x0)] = 128 }
                    }
                }
            }
            built.append(Face(id: face.id, origin: SIMD2(box.x0, box.y0), width: w, height: h,
                              skin: skin, teeth: teeth, eyes: eyes))
        }
        return TouchUpMaskSet(faces: built, width: width, height: height, modelVersion: "fixture")
    }
}
