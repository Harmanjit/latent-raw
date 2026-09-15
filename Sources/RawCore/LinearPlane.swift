import Accelerate
import Foundation
import IOSurface

/// The pixels of a linear source: a DNG whose image is already
/// demosaiced (LinearRaw), such as a Photo Merge result. The counterpart
/// of `SensorPlane`, and shared the same way: an IOSurface the decoder
/// service fills, the app receives by reference and the GPU reads in place.
///
/// Layout, the contract the render pipeline relies on:
/// - `width x height` pixels, row by row, four `Float16` each: red,
///   green, blue and an unused alpha of 1. The layout of an `rgba16Float`
///   texture, so every later stage already speaks it.
/// - Camera RGB, linear, at unit white balance: nothing has been
///   multiplied by the white balance yet, which is what lets the white
///   balance sliders work on these files as they do on a raw.
/// - Scaled so the file's white level is 1.0: each sample has the file's
///   black subtracted and is divided by white minus black. A Latent merge
///   writes black 0 and white 1, so its values arrive unchanged.
/// - Always finite and never negative. NaN, infinities and negative
///   values become 0, and anything above 65504 (the largest `Float16`)
///   becomes 65504, so a damaged or hostile file can't poison the
///   pipeline's arithmetic.
///
/// Float16 rather than Float32 halves the memory (a 45 MP image is
/// 360 MB rather than 720 MB) and loses nothing for our own files, which
/// are stored as Float16 in the first place.
public final class LinearPlane: @unchecked Sendable {
    public let surface: IOSurface
    public let width: Int
    public let height: Int

    /// Four Float16 values per pixel.
    public static let channels = 4
    public static let bytesPerPixel = channels * MemoryLayout<Float16>.size

    /// The largest finite Float16.
    public static let maximumValue: Float = 65504

    /// A new surface for `width x height` pixels, filled by `fill` with the
    /// surface unlocked for writing. Nil if the surface can't be made.
    init?(width: Int, height: Int, fill: (UnsafeMutableBufferPointer<Float16>) -> Void) {
        guard width > 0, height > 0 else { return nil }
        let bytes = width * height * Self.bytesPerPixel
        guard let surface = IOSurface(properties: SensorPlane.properties(byteCount: bytes)),
              surface.allocationSize >= bytes,
              surface.lock(options: [], seed: nil) == kIOReturnSuccess else { return nil }
        let samples = surface.baseAddress.bindMemory(to: Float16.self, capacity: width * height * Self.channels)
        fill(UnsafeMutableBufferPointer(start: samples, count: width * height * Self.channels))
        surface.unlock(options: [], seed: nil)
        guard surface.lock(options: .readOnly, seed: nil) == kIOReturnSuccess else { return nil }
        self.surface = surface
        self.width = width
        self.height = height
    }

    /// Adopts a surface received from the decoder service. The size comes
    /// from the service's metadata and is checked against the surface's
    /// real size, so a lying peer can't make us read past the end.
    public init?(surface: IOSurface, width: Int, height: Int) {
        guard width > 0, height > 0,
              width.multipliedReportingOverflow(by: height).overflow == false,
              width * height <= surface.allocationSize / Self.bytesPerPixel,
              surface.lock(options: .readOnly, seed: nil) == kIOReturnSuccess else { return nil }
        self.surface = surface
        self.width = width
        self.height = height
    }

    deinit {
        surface.unlock(options: .readOnly, seed: nil)
    }

    public var pointer: UnsafeMutableRawPointer { surface.baseAddress }
    /// Every sample, `width x height x 4` of them.
    public var samples: UnsafeBufferPointer<Float16> {
        UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: Float16.self),
                            count: width * height * Self.channels)
    }
    /// The bytes the pixels take (the surface itself is rounded up to a page).
    public var byteCount: Int { width * height * Self.bytesPerPixel }
    /// The whole allocation, a whole number of pages: what Metal wraps.
    public var allocationLength: Int { surface.allocationSize }

    /// The value a sample is stored as: finite, not negative, and no
    /// larger than a Float16 can hold.
    @inline(__always)
    static func clean(_ value: Float) -> Float {
        // `value >= 0` is false for NaN, so NaN lands on 0 with the
        // negatives; +infinity is refused explicitly.
        guard value >= 0, value.isFinite else { return 0 }
        return min(value, maximumValue)
    }
}

// MARK: - Copying LibRaw's linear image

extension LinearPlane {
    /// How LibRaw stored the samples it unpacked.
    enum SourceFormat {
        /// Three Float32 per pixel: a floating-point DNG.
        case float3
        /// `count` UInt16 per pixel, of which the first three are colours:
        /// integer LinearRaw DNGs from other applications.
        case uint16(count: Int)

        var bytesPerPixel: Int {
            switch self {
            case .float3: 3 * MemoryLayout<Float>.size
            case .uint16(let count): count * MemoryLayout<UInt16>.size
            }
        }
    }

    /// Copies the active area of a linear image LibRaw unpacked
    /// (`area.fullWidth x area.fullHeight` pixels, row by row) into a new
    /// plane, applying the contract above on the way: black subtracted per
    /// channel, divided by `white - black`, cleaned, alpha added. This is
    /// the one copy between LibRaw and the GPU.
    ///
    /// Rows run in parallel. Each is scaled into a Float32 row and then
    /// converted to Float16 with vImage, which rounds exactly as the file's
    /// own Float16 values were stored, so a merge's samples come through
    /// bit for bit.
    convenience init?(copying area: SensorActiveArea, of source: UnsafeRawBufferPointer, format: SourceFormat,
                      channelBlack: SIMD3<Float>, white: Float) {
        let bytesPerPixel = format.bytesPerPixel
        guard area.isValid, let start = source.baseAddress,
              source.count >= area.fullWidth * area.fullHeight * bytesPerPixel else { return nil }
        // A file whose white doesn't sit above its black would divide by
        // zero or flip every value; such a file gets its values unscaled.
        let ranges = SIMD3<Float>(repeating: white) - channelBlack
        let scale = SIMD3<Float>(ranges.x > 0 ? 1 / ranges.x : 1,
                                 ranges.y > 0 ? 1 / ranges.y : 1,
                                 ranges.z > 0 ? 1 / ranges.z : 1)
        let width = area.width
        // Every row reads and writes its own bytes, so sharing the two
        // pointers across the concurrent rows is safe; the compiler can't
        // see that for raw pointers, hence nonisolated(unsafe).
        nonisolated(unsafe) let base = start
        self.init(width: area.width, height: area.height) { destination in
            nonisolated(unsafe) let destination = destination
            DispatchQueue.concurrentPerform(iterations: area.height) { row in
                var scaled = [Float](repeating: 1, count: width * Self.channels)
                let rowStart = base + ((area.top + row) * area.fullWidth + area.left) * bytesPerPixel
                scaled.withUnsafeMutableBufferPointer { out in
                    switch format {
                    case .float3:
                        let pixels = rowStart.assumingMemoryBound(to: Float.self)
                        for x in 0..<width {
                            for c in 0..<3 {
                                out[x * 4 + c] = Self.clean((pixels[x * 3 + c] - channelBlack[c]) * scale[c])
                            }
                        }
                    case .uint16(let count):
                        let pixels = rowStart.assumingMemoryBound(to: UInt16.self)
                        for x in 0..<width {
                            for c in 0..<3 {
                                out[x * 4 + c] = Self.clean((Float(pixels[x * count + c]) - channelBlack[c]) * scale[c])
                            }
                        }
                    }
                    // vImage converts a "planar" run of values; one row of
                    // RGBA is simply width x 4 of them.
                    var from = vImage_Buffer(data: out.baseAddress, height: 1, width: vImagePixelCount(width * 4),
                                             rowBytes: width * 4 * MemoryLayout<Float>.size)
                    var to = vImage_Buffer(data: destination.baseAddress! + row * width * 4, height: 1,
                                           width: vImagePixelCount(width * 4),
                                           rowBytes: width * 4 * MemoryLayout<Float16>.size)
                    vImageConvert_PlanarFtoPlanar16F(&from, &to, vImage_Flags(kvImageDoNotTile))
                }
            }
        }
    }
}
