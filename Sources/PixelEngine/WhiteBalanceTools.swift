import Foundation
import Metal
import simd
import ColorKit

/// Lightroom's White Balance menu. The fixed light sources are colour
/// temperatures (with Latent's own tint, see `ColorKit.WhiteBalance`);
/// As Shot and Auto are worked out per image.
public enum WhiteBalancePreset: String, CaseIterable, Identifiable, Sendable {
    case asShot, auto, daylight, cloudy, shade, tungsten, fluorescent, flash

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .asShot: return "As Shot"
        case .auto: return "Auto"
        case .daylight: return "Daylight"
        case .cloudy: return "Cloudy"
        case .shade: return "Shade"
        case .tungsten: return "Tungsten"
        case .fluorescent: return "Fluorescent"
        case .flash: return "Flash"
        }
    }

    /// The setting for a fixed light source; nil for As Shot and Auto.
    /// Temperatures are Lightroom's. Tints are zero except Fluorescent,
    /// whose tubes run green, so the picture is leaned magenta to cancel
    /// that. The tint describes the light, so a greenish light is a
    /// negative one; the amount, in Latent's tint units, is about the
    /// cast of a typical cool-white tube.
    public var fixed: ColorKit.WhiteBalance? {
        switch self {
        case .asShot, .auto: return nil
        case .daylight: return .init(temperature: 5500, tint: 0)
        case .cloudy: return .init(temperature: 6500, tint: 0)
        case .shade: return .init(temperature: 7500, tint: 0)
        case .tungsten: return .init(temperature: 2850, tint: 0)
        case .fluorescent: return .init(temperature: 3800, tint: -6)
        case .flash: return .init(temperature: 5500, tint: 0)
        }
    }

    /// Which preset a setting is, if any, for the menu to show. Daylight
    /// and Flash share a setting; Daylight wins, as in Lightroom. `auto`
    /// is the last Auto result for this image, if there was one.
    public static func matching(_ wb: ColorKit.WhiteBalance, asShot: ColorKit.WhiteBalance,
                                auto: ColorKit.WhiteBalance? = nil) -> WhiteBalancePreset? {
        func same(_ a: ColorKit.WhiteBalance, _ b: ColorKit.WhiteBalance) -> Bool {
            abs(a.temperature - b.temperature) < 0.5 && abs(a.tint - b.tint) < 0.05
        }
        if wb.isAsShot || same(wb, asShot) { return .asShot }
        if let auto, same(wb, auto) { return .auto }
        return allCases.first { $0.fixed.map { same($0, wb) } ?? false }
    }
}

/// The White Balance Selector: click something that ought to be neutral
/// grey and the temperature and tint change to make it so.
///
/// Works where Auto's grey-world does, in the camera's own colour space
/// with the current multipliers applied, on a small patch around the
/// click. The residual cast there (red over green, blue over green) says
/// how far the multipliers are off; corrected multipliers convert back to
/// a temperature and tint through the camera profile.
public enum WhiteBalancePicker {
    public enum Outcome: Equatable, Sendable {
        case balanced(ColorKit.WhiteBalance)
        /// The patch is near black: its colour is mostly noise.
        case tooDark
        /// A channel is clipped there, so its colour is wrong.
        case clipped
        /// No camera profile: temperature and tint mean nothing.
        case noProfile
    }

    /// Radius of the averaged patch, in analysis pixels (a 5×5 square).
    static let patchRadius = 2
    static let analysisScale = RenderScale.binned(quads: 2)

    /// The setting that neutralises the patch around `point`, a point on
    /// the raw grid in normalised sensor coordinates (lens correction
    /// moves pixels after this stage, so the caller converts the click).
    public static func whiteBalance(at point: SIMD2<Float>, session: ImageSession,
                                    pipeline: RenderPipeline, gpu: GPUContext,
                                    parameters: EditParameters) throws -> Outcome {
        guard let profile = session.profile else { return .noProfile }
        let camera = try pipeline.renderCameraRGB(session, scale: analysisScale, parameters: parameters)
        let w = camera.width, h = camera.height
        let cx = Int((point.x * Float(w)).rounded(.down)), cy = Int((point.y * Float(h)).rounded(.down))
        let x0 = min(max(cx - patchRadius, 0), max(w - 1, 0)), y0 = min(max(cy - patchRadius, 0), max(h - 1, 0))
        let x1 = min(max(cx + patchRadius, 0), w - 1), y1 = min(max(cy + patchRadius, 0), h - 1)
        guard x1 >= x0, y1 >= y0 else { return .tooDark }
        let pixels = try TextureReadback.float16Pixels(of: camera, x: x0, y: y0,
                                                       width: x1 - x0 + 1, height: y1 - y0 + 1, gpu: gpu)
        var sum = SIMD3<Float>(0, 0, 0)
        var peak = SIMD3<Float>(0, 0, 0)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let p = SIMD3<Float>(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]))
            sum += p
            peak = simd_max(peak, p)
        }
        let mean = sum / Float(max(pixels.count / 4, 1))
        let multipliers = session.multipliers(for: parameters.whiteBalance)
        let clip = session.highlightClipLevel(multipliers: multipliers)
        return outcome(mean: mean, peak: peak, clip: clip, multipliers: multipliers, profile: profile)
    }

    /// The arithmetic, apart from the render, for tests.
    static func outcome(mean: SIMD3<Float>, peak: SIMD3<Float>, clip: SIMD3<Float>,
                        multipliers: SIMD4<Float>, profile: ColorKit.CameraColorProfile) -> Outcome {
        // 0.98 of the clip level: highlight reconstruction starts well
        // below it, but only a channel at the ceiling has lost its colour.
        if peak.x >= clip.x * 0.98 || peak.y >= clip.y * 0.98 || peak.z >= clip.z * 0.98 { return .clipped }
        // About eight stops under the clip level.
        if mean.y < clip.y / 256 || mean.x <= 0 || mean.z <= 0 { return .tooDark }
        let corrected = SIMD4<Float>(multipliers.x * mean.y / mean.x, multipliers.y,
                                     multipliers.z * mean.y / mean.z, multipliers.w)
        return .balanced(profile.whiteBalance(fromMultipliers: corrected))
    }
}

extension AutoAdjust {
    /// White balance alone, as the White Balance menu's Auto: Auto
    /// Adjust's grey-world estimate, without touching exposure or contrast.
    public static func suggestWhiteBalance(for session: ImageSession, pipeline: RenderPipeline,
                                           gpu: GPUContext, current: EditParameters) throws -> ColorKit.WhiteBalance? {
        var base = current
        base.exposureEV = 0
        return try greyWorld(session: session, pipeline: pipeline, gpu: gpu, parameters: base)
    }
}

extension TextureReadback {
    /// The pixels of a rectangle of an `rgba16Float` texture, row-major,
    /// four halfs each. Copies only that rectangle, so reading the few
    /// pixels under the pointer costs next to nothing.
    public static func float16Pixels(of texture: MTLTexture, x: Int, y: Int, width: Int, height: Int,
                                     gpu: GPUContext) throws -> [Float16] {
        let x = min(max(x, 0), texture.width - 1), y = min(max(y, 0), texture.height - 1)
        let width = max(1, min(width, texture.width - x)), height = max(1, min(height, texture.height - y))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let readable = gpu.device.makeTexture(descriptor: descriptor),
              let cmdBuffer = gpu.commandQueue.makeCommandBuffer(),
              let blit = cmdBuffer.makeBlitCommandEncoder() else {
            throw ExportError.readbackFailed
        }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: readable, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()
        guard cmdBuffer.status != .error else { throw ExportError.readbackFailed }
        var pixels = [Float16](repeating: 0, count: width * height * 4)
        readable.getBytes(&pixels, bytesPerRow: width * 4 * MemoryLayout<Float16>.size,
                          from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return pixels
    }
}
