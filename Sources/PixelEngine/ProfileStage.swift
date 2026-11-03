import Foundation
import Metal
import simd
import ColorKit

/// What a profile changes in one render, resolved from the edit's
/// `ProfileChoice`, the image and its white balance.
///
/// Inactive (nil) for Latent Standard and for a DCP that isn't on this
/// Mac: the colour kernel then takes exactly the path it always did.
struct ProfileRenderState: Equatable {
    /// Replaces the camera matrix (a DCP's, for this white balance).
    var cameraToWorking: simd_float3x3?
    /// Applied right after the camera matrix (a DCP's HueSatMap).
    var hueSatMap: HueSatTable?
    /// Applied after exposure, mixed in by `amount` (a DCP's LookTable,
    /// or a built-in profile's look).
    var lookTable: HueSatTable?
    /// 256 samples of the profile's tone curve, indexed by display value
    /// in a 2.2-gamma domain; nil when not applied.
    var toneCurve: [Float]?
    /// Multiplies the sigmoid's contrast.
    var contrastScale: Float = 1
    /// Added to exposure, in stops (a DCP's BaselineExposureOffset).
    var exposureOffset: Float = 0
    var amount: Float = 1

    static let toneCurveSamples = 256

    /// nil when the choice changes nothing.
    static func resolve(_ choice: ProfileChoice?, multipliers: SIMD4<Float>,
                        library: CameraProfileLibrary) -> ProfileRenderState? {
        guard let choice = choice?.sanitized else { return nil }
        if let builtIn = choice.builtIn {
            guard let look = builtIn.look else { return nil }
            let amount = choice.effectiveAmount
            return ProfileRenderState(lookTable: look,
                                      contrastScale: powf(builtIn.contrastScale, amount),
                                      amount: amount)
        }
        guard choice.isDCP, let dcp = library.profile(id: choice.id) else { return nil }
        let math = CameraProfileMath(profile: dcp)
        var state = ProfileRenderState()
        state.cameraToWorking = math.cameraToWorking(multipliers: multipliers)
        state.hueSatMap = math.hueSatMap(multipliers: multipliers)
        state.lookTable = dcp.lookTable
        state.exposureOffset = dcp.baselineExposureOffset
        if choice.toneCurve == true, dcp.hasToneCurve {
            state.toneCurve = (0..<toneCurveSamples).map { i in
                let p = Float(i) / Float(toneCurveSamples - 1)
                return dcp.toneCurveValue(powf(p, 2.2))
            }
        }
        return state
    }

    /// The flags word the kernel reads: 1 HueSatMap, 2 look table, 4 tone curve.
    var flags: UInt32 {
        (hueSatMap != nil ? 1 : 0) | (lookTable != nil ? 2 : 0) | (toneCurve != nil ? 4 : 0)
    }
}

/// `ProfileLook` in ColorPipeline.metal. Layout must match it exactly.
struct ProfileLookGPU {
    var workingToProPhoto: simd_float3x3 = ColorKit.workingToProPhoto
    var proPhotoToWorking: simd_float3x3 = ColorKit.proPhotoToWorking
    var hueSatDims = SIMD4<UInt32>(1, 2, 1, 0)
    var lookDims = SIMD4<UInt32>(1, 2, 1, 0)
    var flags: UInt32 = 0
    var amount: Float = 1
    var padding = SIMD2<Float>(0, 0)

    static func dims(_ t: HueSatTable?) -> SIMD4<UInt32> {
        guard let t else { return SIMD4(1, 2, 1, 0) }
        return SIMD4(UInt32(t.hueDivisions), UInt32(t.satDivisions), UInt32(t.valDivisions),
                     t.sRGBValueEncoding ? 1 : 0)
    }
}

/// The profile stage's textures, kept between renders: a slider drag
/// re-renders dozens of times with the same tables.
final class ProfileTextureCache {
    private var hueSat: (table: HueSatTable, texture: MTLTexture)?
    private var look: (table: HueSatTable, texture: MTLTexture)?
    private var tone: (lut: [Float], texture: MTLTexture)?
    private var placeholder3D: MTLTexture?
    private var placeholder1D: MTLTexture?

    func hueSatTexture(_ table: HueSatTable?, device: MTLDevice) -> MTLTexture? {
        guard let table else { return placeholder3D(device) }
        if let hueSat, hueSat.table == table { return hueSat.texture }
        guard let t = Self.makeTexture(table, device: device) else { return placeholder3D(device) }
        hueSat = (table, t)
        return t
    }

    func lookTexture(_ table: HueSatTable?, device: MTLDevice) -> MTLTexture? {
        guard let table else { return placeholder3D(device) }
        if let look, look.table == table { return look.texture }
        guard let t = Self.makeTexture(table, device: device) else { return placeholder3D(device) }
        look = (table, t)
        return t
    }

    func toneTexture(_ lut: [Float]?, device: MTLDevice) -> MTLTexture? {
        guard let lut else { return placeholder1D(device) }
        if let tone, tone.lut == lut { return tone.texture }
        let d = MTLTextureDescriptor()
        d.textureType = .type1D; d.pixelFormat = .r32Float
        d.width = lut.count; d.storageMode = .shared; d.usage = [.shaderRead]
        guard let t = device.makeTexture(descriptor: d) else { return placeholder1D(device) }
        lut.withUnsafeBytes { bytes in
            t.replace(region: MTLRegionMake1D(0, lut.count), mipmapLevel: 0,
                      withBytes: bytes.baseAddress!, bytesPerRow: lut.count * 4)
        }
        tone = (lut, t)
        return t
    }

    /// Width is saturation, height hue, depth value: the DNG storage
    /// order, so the entries copy straight in.
    static func makeTexture(_ table: HueSatTable, device: MTLDevice) -> MTLTexture? {
        let d = MTLTextureDescriptor()
        d.textureType = .type3D; d.pixelFormat = .rgba16Float
        d.width = table.satDivisions; d.height = table.hueDivisions; d.depth = table.valDivisions
        d.storageMode = .shared; d.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        var halves: [Float16] = []
        halves.reserveCapacity(table.entries.count * 4)
        for e in table.entries {
            halves.append(Float16(e.x)); halves.append(Float16(e.y))
            halves.append(Float16(e.z)); halves.append(1)
        }
        halves.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake3D(0, 0, 0, table.satDivisions, table.hueDivisions, table.valDivisions),
                            mipmapLevel: 0, slice: 0, withBytes: bytes.baseAddress!,
                            bytesPerRow: table.satDivisions * 8,
                            bytesPerImage: table.satDivisions * table.hueDivisions * 8)
        }
        return texture
    }

    private func placeholder3D(_ device: MTLDevice) -> MTLTexture? {
        if placeholder3D == nil {
            let d = MTLTextureDescriptor()
            d.textureType = .type3D; d.pixelFormat = .rgba16Float
            d.width = 1; d.height = 1; d.depth = 1
            d.storageMode = .shared; d.usage = [.shaderRead]
            placeholder3D = device.makeTexture(descriptor: d)
        }
        return placeholder3D
    }

    private func placeholder1D(_ device: MTLDevice) -> MTLTexture? {
        if placeholder1D == nil {
            let d = MTLTextureDescriptor()
            d.textureType = .type1D; d.pixelFormat = .r32Float
            d.width = 1; d.storageMode = .shared; d.usage = [.shaderRead]
            placeholder1D = device.makeTexture(descriptor: d)
        }
        return placeholder1D
    }
}

extension RenderPipeline {
    /// The profile's state for this render, nil for Latent Standard.
    func profileState(session: ImageSession, parameters: EditParameters,
                      multipliers: SIMD4<Float>) -> ProfileRenderState? {
        ProfileRenderState.resolve(parameters.profile, multipliers: multipliers, library: profileLibrary)
    }

    /// Binds the profile stage's uniforms (buffer 30) and tables
    /// (textures 14, 15, 16). With no profile the flags are 0 and the
    /// kernel never reads the placeholders bound in their place.
    func encodeProfile(_ encoder: MTLComputeCommandEncoder, state: ProfileRenderState?) {
        var look = ProfileLookGPU()
        if let state {
            look.flags = state.flags
            look.amount = state.amount
            look.hueSatDims = ProfileLookGPU.dims(state.hueSatMap)
            look.lookDims = ProfileLookGPU.dims(state.lookTable)
        }
        encoder.setBytes(&look, length: MemoryLayout<ProfileLookGPU>.stride, index: 29)
        let device = gpu.device
        encoder.setTexture(profileTextures.hueSatTexture(state?.hueSatMap, device: device), index: 14)
        encoder.setTexture(profileTextures.lookTexture(state?.lookTable, device: device), index: 15)
        encoder.setTexture(profileTextures.toneTexture(state?.toneCurve, device: device), index: 16)
    }
}
