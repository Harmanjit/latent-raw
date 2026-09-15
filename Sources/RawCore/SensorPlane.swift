import Foundation
import IOSurface

/// The unpacked sensor data, held once, in memory three parties can use
/// without copying it: the decoder service that fills it, the app that
/// receives it, and the GPU that reads it.
///
/// The storage is an IOSurface: page-aligned kernel memory that XPC
/// can hand to another process by reference (a mach port, not bytes)
/// and that Metal can wrap as a shared buffer with
/// `makeBuffer(bytesNoCopy:)`. Before this, a 24 MP plane (~49 MB) was
/// copied four times on the way to the GPU and held twice for as long
/// as the image stayed open.
///
/// The surface stays locked read-only for this object's lifetime, so
/// `pointer` is valid until it is released.
public final class SensorPlane: @unchecked Sendable {
    public let surface: IOSurface
    /// Number of UInt16 samples.
    public let count: Int

    /// Copies `samples` into a new surface. This is the one copy of the
    /// sensor data between LibRaw and the GPU.
    public init?(copying samples: UnsafeBufferPointer<UInt16>) {
        guard let source = samples.baseAddress, !samples.isEmpty else { return nil }
        let bytes = samples.count * MemoryLayout<UInt16>.size
        guard let surface = IOSurface(properties: Self.properties(byteCount: bytes)),
              surface.allocationSize >= bytes else { return nil }
        guard surface.lock(options: [], seed: nil) == kIOReturnSuccess else { return nil }
        surface.baseAddress.copyMemory(from: source, byteCount: bytes)
        surface.unlock(options: [], seed: nil)
        guard surface.lock(options: .readOnly, seed: nil) == kIOReturnSuccess else { return nil }
        self.surface = surface
        self.count = samples.count
    }

    /// Copies the active area out of a whole sensor readout
    /// (`area.fullWidth x area.fullHeight` samples, row by row) into a new
    /// surface, so the plane holds `area.width x area.height`
    /// samples and its (0, 0) is the active area's top-left photosite.
    /// Like `init(copying:)`, this is the one copy between LibRaw and the
    /// GPU; the border is simply never copied. Nil if the rectangle
    /// doesn't lie inside a buffer of that size.
    public init?(copying area: SensorActiveArea, of readout: UnsafeBufferPointer<UInt16>) {
        guard area.isValid, let source = readout.baseAddress,
              readout.count >= area.fullWidth * area.fullHeight else { return nil }
        let count = area.width * area.height
        let rowBytes = area.width * MemoryLayout<UInt16>.size
        guard let surface = IOSurface(properties: Self.properties(byteCount: count * MemoryLayout<UInt16>.size)),
              surface.allocationSize >= count * MemoryLayout<UInt16>.size else { return nil }
        guard surface.lock(options: [], seed: nil) == kIOReturnSuccess else { return nil }
        for row in 0..<area.height {
            let from = source + (area.top + row) * area.fullWidth + area.left
            (surface.baseAddress + row * rowBytes).copyMemory(from: from, byteCount: rowBytes)
        }
        surface.unlock(options: [], seed: nil)
        guard surface.lock(options: .readOnly, seed: nil) == kIOReturnSuccess else { return nil }
        self.surface = surface
        self.count = count
    }

    /// Adopts a surface received from the decoder service. `count` comes
    /// from the service's metadata and is checked against the surface's
    /// real size, so a lying peer can't make us read past the end.
    public init?(surface: IOSurface, count: Int) {
        guard count > 0, count <= surface.allocationSize / MemoryLayout<UInt16>.size,
              surface.lock(options: .readOnly, seed: nil) == kIOReturnSuccess else { return nil }
        self.surface = surface
        self.count = count
    }

    deinit {
        surface.unlock(options: .readOnly, seed: nil)
    }

    public var pointer: UnsafeMutableRawPointer { surface.baseAddress }
    public var samples: UnsafeBufferPointer<UInt16> {
        UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt16.self), count: count)
    }
    /// The whole allocation, a whole number of pages: what Metal wraps.
    public var allocationLength: Int { surface.allocationSize }

    static func properties(byteCount: Int) -> [IOSurfacePropertyKey: Any] {
        let page = Int(getpagesize())
        let rounded = (byteCount + page - 1) / page * page
        // A one-row "image" is the plainest way to ask IOSurface for a
        // byte buffer; nothing ever treats it as pixels.
        return [.width: rounded / 2, .height: 1, .bytesPerElement: 2, .bytesPerRow: rounded,
                .allocSize: rounded, .pixelFormat: UInt32(0x4C30_3136)]  // 'L016'
    }
}
