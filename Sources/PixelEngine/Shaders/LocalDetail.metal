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
    float4 detail;    // noise, defringe, mask slot, 0
};

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
    }

    output.write(float4(ldFromLinear(lin, isLinear, headroom), 1.0), gid);
}
