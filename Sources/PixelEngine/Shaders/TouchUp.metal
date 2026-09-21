#include <metal_stdlib>
using namespace metal;

// Touch-up (docs/Retouch.md §7): skin smoothing, teeth whitening and
// brighter eyes over the faces' region masks, one stage on the
// display-referred image between the output transform and presence.
//
// The stage (TouchUpStage.swift) prepares perceptual luma with
// LocalContrast's lcPrepare and blurs it twice with its lcDownsample and
// lcBlurH/V passes: a fine blur at 1.5 sensor px and a mid blur at a few
// percent of the face's width. Skin smoothing is the band between the
// two, subtracted where the skin mask says so: pores and fine texture go,
// the shape of the face (everything wider than the mid blur) stays. Eyes
// get the same idea against the mid blur only, so the sclera and a
// catchlight lift and the pupil doesn't, plus a plain gain. Teeth lose
// the yellow that makes them yellow (the red-green mean over blue) and
// gain a little, capped so a tongue or lip caught by the mask isn't
// bleached. The luma work is a ratio on the perceptual scale, where a
// step looks the same size in shadows and highlights, applied to the
// pixel in linear light so its colour keeps.
//
// Helpers are prefixed twins (touchUpPerceptual/ToLinear/FromLinear) of
// LocalContrast's file-local ones: make_app.sh compiles files separately
// while the runtime fallback concatenates them, so reusing or redefining
// the names fails one way or the other.

inline float touchUpPerceptual(float y) { return pow(max(y, 0.0), 1.0 / 2.2); }

// Image -> linear RGB in [0, ~1]: undo the file encoding, or scale the
// EDR buffer down by its headroom.
inline float3 touchUpToLinear(float3 c, bool isLinear, float headroom) {
    return isLinear ? max(c, 0.0) / headroom : pow(max(c, 0.0), 2.2);
}
inline float3 touchUpFromLinear(float3 l, bool isLinear, float headroom) {
    return isLinear ? l * headroom : pow(max(l, 0.0), 1.0 / 2.2);
}

// Mirror of `TouchUpParamsGPU` in TouchUpStage.swift.
struct TouchUpParamsGPU {
    float4 sliders;        // skin, teeth, eyes (0…1), overlay (0 or 1)
    float2 tileOrigin;     // sensor px
    float2 sensorSize;     // sensor px
    float binSpan;         // sensor px per texture px
    uint isLinear;         // 1 for the EDR viewport, 0 for an encoded file
    float headroom;
    float padding;
};

kernel void touchUpApply(
    texture2d<float, access::read>        input   [[texture(0)]],
    texture2d<float, access::write>       output  [[texture(1)]],
    texture2d_array<float, access::sample> masks  [[texture(2)]],   // skin, teeth, eyes
    texture2d<float, access::sample>      fine    [[texture(3)]],   // luma blurred at 1.5 sensor px
    texture2d<float, access::sample>      mid     [[texture(4)]],   // luma blurred at sigmaMid
    constant TouchUpParamsGPU &params             [[buffer(0)]],
    uint2 gid                                     [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 src = input.read(gid);

    // The masks are on the output grid at half sensor resolution, so a
    // pixel finds its mask by its sensor position, whatever tile and
    // binning this render is (like local masks).
    float2 uv = (params.tileOrigin + (float2(gid) + 0.5) * params.binSpan) / params.sensorSize;
    float mSkin = masks.sample(s, uv, 0).r;
    float mTeeth = masks.sample(s, uv, 1).r;
    float mEyes = masks.sample(s, uv, 2).r;
    float skin = params.sliders.x * mSkin;
    float teeth = params.sliders.y * mTeeth;
    float eyes = params.sliders.z * mEyes;
    bool overlay = params.sliders.w != 0.0 && mSkin > 0.0;

    // Nothing to do here: pass the pixel through untouched, so a zero
    // slider, and every pixel outside the masks, is bit-identical to the
    // input rather than a round trip through the encoding.
    if (skin == 0.0 && teeth == 0.0 && eyes == 0.0 && !overlay) {
        output.write(src, gid);
        return;
    }

    bool isLinear = params.isLinear != 0;
    float3 lin = touchUpToLinear(src.rgb, isLinear, params.headroom);
    // The blurs are of the perceptual luma lcPrepare computes; the
    // pixel's own is recomputed here at full precision. The blur textures
    // may be smaller than this one (the mid blur runs on a shrunk copy),
    // so they are sampled by position, not read by pixel.
    float2 tuv = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());
    float bFine = fine.sample(s, tuv).r;
    float bMid = mid.sample(s, tuv).r;
    float y = dot(lin, float3(0.2126, 0.7152, 0.0722));
    float l = max(touchUpPerceptual(y), 1e-3);
    float lOut = l;

    // Skin: take the fine-to-mid band away. Clamped so a hard edge that
    // strayed into the mask (hair, a nostril) is softened, never inverted.
    if (skin > 0.0) {
        float band = clamp(bFine - bMid, -0.25, 0.25);
        lOut -= skin * band;
    }
    // Eyes: lift what is already brighter than its surroundings (the
    // sclera, a catchlight), leave the pupil, then a small gain.
    float gain = 1.0;
    if (eyes > 0.0) {
        lOut += 0.4 * eyes * clamp(l - bMid, -0.2, 0.2);
        gain = 1.0 + 0.3 * eyes;
    }
    lOut = max(lOut, 0.0);
    lin *= clamp(pow(lOut / l, 2.2), 0.25, 4.0) * gain;

    // Teeth: put back the blue the yellow cast took, and brighten a
    // little. Both capped so the mask catching a lip or the tongue shows
    // as a slight change, not a bleach.
    if (teeth > 0.0) {
        float yellow = max(0.0, 0.5 * (lin.r + lin.g) - lin.b);
        lin.b += 0.9 * teeth * yellow;
        lin *= 1.0 + 0.2 * teeth;
    }

    // Show Skin Mask: the skin slice as the red the mask overlay uses
    // (ColorPipeline.metal), mixed in the same light it mixes in.
    if (overlay) {
        float3 red = float3(0.8, 0.05, 0.05) * (isLinear ? 0.6 / params.headroom : 1.0);
        lin = mix(lin, red, 0.4 * mSkin);
    }

    output.write(float4(touchUpFromLinear(lin, isLinear, params.headroom), src.a), gid);
}
