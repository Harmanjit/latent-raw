#include <metal_stdlib>
using namespace metal;

// Local detail: texture, clarity, dehaze, sharpness, noise and defringe
// inside a mask (LocalDetailStage.swift). The same ingredients and the
// same arithmetic as presence (LocalContrast.metal), scaled per pixel by
// each mask, which the colour kernel wrote into two RGBA textures (one
// channel per mask) while it built them. Runs only when some mask uses
// one of these sliders.
//
// Sharpness and noise use the same blurs: sharpening adds back the
// difference between the pixel and its ~1 px blur, softening (negative
// sharpness) moves toward it, and noise reduction moves flat areas toward
// the ~4 px blur while leaving edges, where the two differ a lot, alone.
// Both work on luminance, so colours are untouched.

// Names of their own: in the runtime-compiled library every shader file
// shares one namespace with LocalContrast.metal.
inline float ldPerceptual(float y) { return pow(max(y, 0.0), 1.0 / 2.2); }
inline float3 ldToLinear(float3 c, bool isLinear, float headroom) {
    return isLinear ? max(c, 0.0) / headroom : pow(max(c, 0.0), 2.2);
}
inline float3 ldFromLinear(float3 l, bool isLinear, float headroom) {
    return isLinear ? l * headroom : pow(max(l, 0.0), 1.0 / 2.2);
}

inline float2 ldHueSat(float3 c) {
    float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
    float d = mx - mn;
    float sat = mx > 1e-5 ? d / mx : 0.0;
    float h = 0.0;
    if (d > 1e-6) {
        if (mx == c.r)      h = (c.g - c.b) / d;
        else if (mx == c.g) h = 2.0 + (c.b - c.r) / d;
        else                h = 4.0 + (c.r - c.g) / d;
        h = fract(h / 6.0 + 1.0);
    }
    return float2(h, sat);
}

inline float ldHueBand(float h, float lo, float hi, float soft) {
    return smoothstep(lo - soft, lo, h) * (1.0 - smoothstep(hi, hi + soft, h));
}

// Mirror of LocalDetailGPU in LocalDetailStage.swift.
struct LocalDetailParams {
    float4 effects;   // texture, clarity, dehaze, sharpness
    float4 detail;    // noise, defringe, mask slot, flags (1 curve, 2 RGB curves, 4 Point Colour, 8 grain)
    float4 grain;     // amount, size (sensor px), roughness, Point Colour swatch count
    float4 pointTarget[4];   // hue, saturation, value, range
    float4 pointShift[4];    // hue, saturation, luminance, variance
};

// Mirror of LocalDetailFrameGPU in LocalToneColour.swift.
struct LocalDetailFrame {
    float2 tileOrigin;   // sensor px of output (0,0)
    float  binSpan;
    uint   seed;
};

// ---------------------------------------------------------------------
// The tone curve, Point Colour and grain inside a mask
// (LocalToneColour.swift). The curve and Point Colour are the global
// ones' arithmetic (applyCurve, applyChannelCurves, applyPointColours in
// ColorPipeline.metal) on the same gamma 2.2 scale, and the grain is the
// Effects grain's (DetailEffects.metal), copied under names of their own
// because a precompiled library builds each file apart.
// ---------------------------------------------------------------------
inline float ldLookup(float v, device const float *lut) {
    float idx = clamp(v, 0.0, 1.0) * 255.0;
    int i = int(idx);
    return mix(lut[i], lut[min(i + 1, 255)], idx - float(i));
}

inline float3 ldRGBToHSV(float3 c) {
    float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
    float d = mx - mn;
    float h = 0.0;
    if (d > 1e-6) {
        if (mx == c.r)      h = fmod((c.g - c.b) / d, 6.0);
        else if (mx == c.g) h = (c.b - c.r) / d + 2.0;
        else                h = (c.r - c.g) / d + 4.0;
        h *= 60.0;
        if (h < 0.0) h += 360.0;
    }
    return float3(h, mx > 1e-6 ? d / mx : 0.0, mx);
}

inline float3 ldHSVToRGB(float3 hsv) {
    float h = fmod(hsv.x + 360.0, 360.0) / 60.0, s = hsv.y, v = hsv.z;
    float c = v * s, x = c * (1.0 - abs(fmod(h, 2.0) - 1.0)), m = v - c;
    float3 rgb;
    if (h < 1.0) rgb = float3(c, x, 0); else if (h < 2.0) rgb = float3(x, c, 0);
    else if (h < 3.0) rgb = float3(0, c, x); else if (h < 4.0) rgb = float3(0, x, c);
    else if (h < 5.0) rgb = float3(x, 0, c); else rgb = float3(c, 0, x);
    return rgb + m;
}

inline float3 ldPointColours(float3 p, constant LocalDetailParams &e) {
    int count = min(int(e.grain.w), 4);
    for (int i = 0; i < count; i++) {
        float4 t = e.pointTarget[i], s = e.pointShift[i];
        if (all(s == float4(0.0))) continue;
        float3 hsv = ldRGBToHSV(p);
        float r = clamp(t.w, 0.0, 1.0);
        float hueReach = mix(12.0, 70.0, r);
        float satReach = mix(0.12, 0.6, r);
        float valReach = mix(0.15, 0.7, r);
        float dh = fmod(hsv.x - t.x + 540.0, 360.0) - 180.0;
        float hueMatters = smoothstep(0.03, 0.12, t.y) * smoothstep(0.03, 0.12, hsv.y);
        float hueW = mix(1.0, 1.0 - smoothstep(0.5 * hueReach, hueReach, abs(dh)), hueMatters);
        float satW = 1.0 - smoothstep(0.5 * satReach, satReach, abs(hsv.y - t.y));
        float valW = 1.0 - smoothstep(0.5 * valReach, valReach, abs(hsv.z - t.z));
        float m = hueW * satW * valW;
        if (m <= 0.0) continue;
        float spread = max(1.0 + s.w * m, 0.0);
        float h = t.x + dh * mix(1.0, spread, hueMatters);
        float sat = t.y + (hsv.y - t.y) * spread;
        h += s.x * 60.0 * m;
        sat *= 1.0 + s.y * m;
        float v = hsv.z * (1.0 + s.z * 0.5 * m);
        p = ldHSVToRGB(float3(h, clamp(sat, 0.0, 1.0), max(v, 0.0)));
    }
    return p;
}

inline uint ldHash(uint x) {
    x ^= x >> 16; x *= 0x7feb352du;
    x ^= x >> 15; x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}

inline float ldLattice(int2 c, uint seed) {
    uint h = ldHash(uint(c.x) ^ ldHash(uint(c.y) ^ ldHash(seed)));
    return float(h) * (2.0 / 4294967295.0) - 1.0;
}

inline float ldValueNoise(float2 p, uint seed, float smooth_) {
    float2 i = floor(p);
    float2 f = p - i;
    float2 s = f * f * (3.0 - 2.0 * f);
    float2 t = mix(f, s, smooth_);
    int2 c = int2(i);
    float a = ldLattice(c, seed), b = ldLattice(c + int2(1, 0), seed);
    float d = ldLattice(c + int2(0, 1), seed), e = ldLattice(c + int2(1, 1), seed);
    return mix(mix(a, b, t.x), mix(d, e, t.x), t.y);
}

// dfxEffectsApply's grain, at `amount` (the slider times the mask).
inline float3 ldGrain(float3 lin, float2 sensor, float amount, float grainCell, float roughness,
                      float binSpan, uint seed) {
    float cell = max(grainCell, binSpan);
    float coarse = min(1.0, grainCell / binSpan);
    float fineCell = max(grainCell * 0.5, binSpan);
    float fine = min(1.0, grainCell * 0.5 / binSpan);
    float r = roughness;
    float n = ldValueNoise(sensor / cell, seed, 1.0 - 0.6 * r) * coarse
            + r * 0.8 * ldValueNoise(sensor / fineCell + 17.31, seed ^ 0x5bd1e995u, 0.0) * fine;
    n *= 1.9 / sqrt(1.0 + 0.64 * r * r);
    float y = dot(lin, float3(0.2126, 0.7152, 0.0722));
    float l = pow(max(y, 0.0), 1.0 / 2.2);
    float response = 0.3 + 0.7 * clamp(4.0 * l * (1.0 - l), 0.0, 1.0);
    float lNew = max(l + amount * 0.12 * response * n, 0.0);
    return max(lin + (pow(lNew, 2.2) - max(y, 0.0)), 0.0);
}

kernel void localDetailApply(
    texture2d<float, access::read>   image   [[texture(0)]],
    texture2d<float, access::read>   pair    [[texture(1)]],   // unblurred luma / dark
    texture2d<float, access::sample> small   [[texture(2)]],   // ~1 px
    texture2d<float, access::sample> medium  [[texture(3)]],   // ~4 px
    texture2d<float, access::sample> large   [[texture(4)]],   // ~1% of the frame
    texture2d<float, access::read>   maskA   [[texture(5)]],   // slots 0-3
    texture2d<float, access::read>   maskB   [[texture(6)]],   // slots 4-7
    texture2d<float, access::write>  output  [[texture(7)]],
    constant LocalDetailParams *params       [[buffer(0)]],
    constant int &count                      [[buffer(1)]],
    constant uint &inputIsLinear             [[buffer(2)]],
    constant float &headroom                 [[buffer(3)]],
    device const float *curves               [[buffer(4)]],   // per slot: master, red, green, blue
    constant LocalDetailFrame &frame         [[buffer(5)]],
    uint2 gid                                [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    bool isLinear = inputIsLinear != 0;

    float4 a = maskA.read(gid), b = maskB.read(gid);
    float masks[8] = { a.x, a.y, a.z, a.w, b.x, b.y, b.z, b.w };

    float2 uv = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());
    float3 lin = ldToLinear(image.read(gid).rgb, isLinear, headroom);
    float2 base = pair.read(gid).rg;
    float2 bS = small.sample(s, uv).rg;
    float2 bM = medium.sample(s, uv).rg;
    float2 bL = large.sample(s, uv).rg;

    for (int i = 0; i < count && i < 8; i++) {
        constant LocalDetailParams &p = params[i];
        float m = masks[clamp(int(p.detail.z), 0, 7)];
        if (m <= 0.0) continue;

        // Dehaze, as the global slider (dark-channel prior), scaled by the mask.
        float dehaze = p.effects.z * m;
        if (dehaze > 0.0) {
            float t = clamp(1.0 - dehaze * 0.9 * bL.g, 0.15, 1.0);
            lin = max((lin - 1.0) / t + 1.0, 0.0);
        } else if (dehaze < 0.0) {
            lin = mix(lin, float3(1.0), -dehaze * 0.5 * (1.0 - bL.g));
        }

        float y = dot(lin, float3(0.2126, 0.7152, 0.0722));
        float l = ldPerceptual(y);
        float lOut = l;
        float texture_ = p.effects.x * m;
        if (texture_ != 0.0) lOut += texture_ * 1.6 * clamp(bS.r - bM.r, -0.2, 0.2);
        float clarity = p.effects.y * m;
        if (clarity != 0.0) {
            float mid = clamp(4.0 * l * (1.0 - l), 0.0, 1.0);
            lOut += clarity * 1.2 * clamp(bM.r - bL.r, -0.3, 0.3) * (0.35 + 0.65 * mid);
        }
        float sharp = p.effects.w * m;
        if (sharp > 0.0) {
            lOut += sharp * 1.5 * clamp(base.r - bS.r, -0.2, 0.2);
        } else if (sharp < 0.0) {
            lOut = mix(lOut, 0.5 * (bS.r + bM.r), -sharp);
        }
        float noise = p.detail.x * m;
        if (noise > 0.0) {
            float flat = 1.0 - smoothstep(0.02, 0.1, abs(base.r - bM.r));
            lOut = mix(lOut, bM.r, clamp(noise * flat * 0.85, 0.0, 1.0));
        }
        lOut = max(lOut, 0.0);
        if (l > 1e-5 && lOut != l) lin *= pow(lOut / l, 2.2);

        // Defringe: purple and green fringes on strong edges, both at once.
        float defringe = p.detail.y * m;
        if (defringe > 0.0) {
            float edge = smoothstep(0.04, 0.18, abs(base.r - bM.r));
            float2 hs = ldHueSat(lin);
            float band = max(ldHueBand(hs.x, 0.70, 0.92, 0.04), ldHueBand(hs.x, 0.22, 0.44, 0.04));
            float strength = clamp(band * defringe * edge * smoothstep(0.08, 0.3, hs.y), 0.0, 1.0);
            float yl = dot(lin, float3(0.2126, 0.7152, 0.0722));
            lin = mix(lin, float3(yl), strength);
        }

        // The curve and Point Colour, mixed in by the mask.
        uint flags = uint(p.detail.w);
        if ((flags & 7u) != 0) {
            float3 pc = pow(max(lin, 0.0), 1.0 / 2.2);
            float3 before = pc;
            device const float *lut = curves + clamp(int(p.detail.z), 0, 7) * 1024;
            if ((flags & 1u) != 0) pc = float3(ldLookup(pc.r, lut), ldLookup(pc.g, lut), ldLookup(pc.b, lut));
            if ((flags & 2u) != 0) {
                pc = float3(ldLookup(pc.r, lut + 256), ldLookup(pc.g, lut + 512), ldLookup(pc.b, lut + 768));
            }
            if ((flags & 4u) != 0) pc = ldPointColours(pc, p);
            lin = pow(max(mix(before, pc, m), 0.0), 2.2);
        }
        if ((flags & 8u) != 0) {
            float2 sensor = frame.tileOrigin + (float2(gid) + 0.5) * frame.binSpan;
            lin = ldGrain(lin, sensor, p.grain.x * m, p.grain.y, p.grain.z, frame.binSpan,
                          frame.seed ^ uint(int(p.detail.z) * 7919));
        }
    }

    output.write(float4(ldFromLinear(lin, isLinear, headroom), 1.0), gid);
}
