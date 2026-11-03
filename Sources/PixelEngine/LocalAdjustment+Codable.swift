import Foundation

/// Stored form of a local adjustment.
///
/// The original ten fields are read and written exactly as the
/// synthesized conformance did (the ranges only when present). Everything
/// added since is read leniently, a missing key meaning the field's
/// default, and written only when it differs from that default. So an edit
/// made before components and the wider slider set loads unchanged, and
/// saving it again writes the same JSON it was read from; and one made
/// with them still loads here after a round trip.
extension LocalAdjustment {
    enum CodingKeys: String, CodingKey {
        case id, name, shape, invert, exposureEV, contrast, saturation, warmth, luminanceRange, hueRange
        case components, invertMask, amount, modelFeather, modelEdge, hidden
        case highlights, shadows, whites, blacks, tint, hue
        case texture, clarity, dehaze, sharpness, noise, defringe
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id),
                  name: try c.decode(String.self, forKey: .name),
                  shape: try c.decode(MaskShape.self, forKey: .shape),
                  invert: try c.decode(Bool.self, forKey: .invert),
                  exposureEV: try c.decode(Float.self, forKey: .exposureEV),
                  contrast: try c.decode(Float.self, forKey: .contrast),
                  saturation: try c.decode(Float.self, forKey: .saturation),
                  warmth: try c.decode(Float.self, forKey: .warmth),
                  luminanceRange: try c.decodeIfPresent(LuminanceRange.self, forKey: .luminanceRange),
                  hueRange: try c.decodeIfPresent(HueRange.self, forKey: .hueRange))
        components = try c.decodeIfPresent([MaskComponent].self, forKey: .components) ?? []
        invertMask = try c.decodeIfPresent(Bool.self, forKey: .invertMask) ?? false
        amount = try c.decodeIfPresent(Float.self, forKey: .amount) ?? 1
        modelFeather = try c.decodeIfPresent(Float.self, forKey: .modelFeather) ?? 0
        modelEdge = try c.decodeIfPresent(Float.self, forKey: .modelEdge) ?? 0
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        func slider(_ key: CodingKeys) throws -> Float { try c.decodeIfPresent(Float.self, forKey: key) ?? 0 }
        highlights = try slider(.highlights); shadows = try slider(.shadows)
        whites = try slider(.whites); blacks = try slider(.blacks)
        tint = try slider(.tint); hue = try slider(.hue)
        texture = try slider(.texture); clarity = try slider(.clarity); dehaze = try slider(.dehaze)
        sharpness = try slider(.sharpness); noise = try slider(.noise); defringe = try slider(.defringe)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(shape, forKey: .shape)
        try c.encode(invert, forKey: .invert)
        try c.encode(exposureEV, forKey: .exposureEV)
        try c.encode(contrast, forKey: .contrast)
        try c.encode(saturation, forKey: .saturation)
        try c.encode(warmth, forKey: .warmth)
        try c.encodeIfPresent(luminanceRange, forKey: .luminanceRange)
        try c.encodeIfPresent(hueRange, forKey: .hueRange)
        if !components.isEmpty { try c.encode(components, forKey: .components) }
        if invertMask { try c.encode(invertMask, forKey: .invertMask) }
        if amount != 1 { try c.encode(amount, forKey: .amount) }
        if modelFeather != 0 { try c.encode(modelFeather, forKey: .modelFeather) }
        if modelEdge != 0 { try c.encode(modelEdge, forKey: .modelEdge) }
        if hidden { try c.encode(hidden, forKey: .hidden) }
        let sliders: [(CodingKeys, Float)] = [
            (.highlights, highlights), (.shadows, shadows), (.whites, whites), (.blacks, blacks),
            (.tint, tint), (.hue, hue), (.texture, texture), (.clarity, clarity), (.dehaze, dehaze),
            (.sharpness, sharpness), (.noise, noise), (.defringe, defringe),
        ]
        for (key, value) in sliders where value != 0 { try c.encode(value, forKey: key) }
    }
}
