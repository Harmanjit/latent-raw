#include <metal_stdlib>
using namespace metal;

// Presence: texture, clarity, dehaze and defringe, one stage on the
// display-referred image just before sharpening.
//
// All four want the same ingredients — the image's luminance blurred at
// a few scales — so they share one set of passes:
//
//   lcPrepare     image -> (perceptual luma, linear dark channel)
//   lcDownsample  box-shrink that pair for the large blurs
//   lcBlurH/V     separable Gaussian on the pair
//   lcApply       texture, clarity, dehaze, defringe from the blurs
//
// Texture boosts the band between about 1 and 4 sensor pixels (finer
// than that is mostly noise, so it's left out). Clarity boosts the band
// between 4 pixels and ~1% of the frame, weighted to the midtones so
// highlights and shadows don't clip. Both are unsharp masks on perceptual
// luminance, the domain where "how much contrast" means the same thing
// in shadows and highlights. Dehaze uses the dark-channel prior: haze
// adds light, so the darkest channel in a neighbourhood measures how
// much; subtracting it in linear light removes it. Defringe desaturates
// purple or green colour that sits on strong luminance edges, which is
// what residual chromatic aberration looks like.

inline float lcPerceptual(float y) { return pow(max(y, 0.0), 1.0 / 2.2); }

// Image -> linear RGB in [0, ~1]: undo the file encoding, or scale the
// EDR buffer down by its headroom.
inline float3 lcToLinear(float3 c, bool isLinear, float headroom) {
    return isLinear ? max(c, 0.0) / headroom : pow(max(c, 0.0), 2.2);
}
inline float3 lcFromLinear(float3 l, bool isLinear, float headroom) {
    return isLinear ? l * headroom : pow(max(l, 0.0), 1.0 / 2.2);
}

kernel void lcPrepare(
    texture2d<float, access::read>  image   [[texture(0)]],
    texture2d<float, access::write> pair    [[texture(1)]],   // r: perceptual luma, g: linear dark channel
    constant uint &inputIsLinear            [[buffer(0)]],
    constant float &headroom                [[buffer(1)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    if (gid.x >= image.get_width() || gid.y >= image.get_height()) return;
    float3 lin = lcToLinear(image.read(gid).rgb, inputIsLinear != 0, headroom);
    float y = dot(lin, float3(0.2126, 0.7152, 0.0722));
    float dark = min(lin.r, min(lin.g, lin.b));
    pair.write(float4(lcPerceptual(y), dark, 0, 1), gid);
}

kernel void lcDownsample(
    texture2d<float, access::read>  source  [[texture(0)]],
    texture2d<float, access::write> dest    [[texture(1)]],
    constant int &factor                    [[buffer(0)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    if (gid.x >= dest.get_width() || gid.y >= dest.get_height()) return;
    int w = int(source.get_width()), h = int(source.get_height());
    float2 sum = 0.0; float n = 0.0;
    for (int dy = 0; dy < factor; dy++) {
        for (int dx = 0; dx < factor; dx++) {
            int x = min(int(gid.x) * factor + dx, w - 1);
            int y = min(int(gid.y) * factor + dy, h - 1);
            sum += source.read(uint2(x, y)).rg; n += 1.0;
        }
    }
    dest.write(float4(sum / n, 0, 1), gid);
}

constant int kLCMaxTaps = 65;

kernel void lcBlurH(
    texture2d<float, access::read>  input   [[texture(0)]],
    texture2d<float, access::write> output  [[texture(1)]],
    constant float *weights                 [[buffer(0)]],
    constant int &taps                      [[buffer(1)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    int w = int(input.get_width()), h = int(input.get_height());
    if (gid.x >= uint(w) || gid.y >= uint(h)) return;
    int half_ = taps / 2;
    float2 sum = 0.0;
    for (int i = 0; i < taps && i < kLCMaxTaps; i++) {
        int x = clamp(int(gid.x) + i - half_, 0, w - 1);
        sum += weights[i] * input.read(uint2(x, gid.y)).rg;
    }
    output.write(float4(sum, 0, 1), gid);
}

kernel void lcBlurV(
    texture2d<float, access::read>  input   [[texture(0)]],
    texture2d<float, access::write> output  [[texture(1)]],
    constant float *weights                 [[buffer(0)]],
    constant int &taps                      [[buffer(1)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    int w = int(input.get_width()), h = int(input.get_height());
    if (gid.x >= uint(w) || gid.y >= uint(h)) return;
    int half_ = taps / 2;
    float2 sum = 0.0;
    for (int i = 0; i < taps && i < kLCMaxTaps; i++) {
        int y = clamp(int(gid.y) + i - half_, 0, h - 1);
        sum += weights[i] * input.read(uint2(gid.x, y)).rg;
    }
    output.write(float4(sum, 0, 1), gid);
}

// Hue of a linear RGB triple in turns (0…1), and its saturation.
inline float2 lcHueSat(float3 c) {
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

// Smooth membership of hue `h` (turns) in [lo, hi], with soft edges.
inline float lcHueBand(float h, float lo, float hi, float soft) {
    return smoothstep(lo - soft, lo, h) * (1.0 - smoothstep(hi, hi + soft, h));
}

kernel void lcApply(
    texture2d<float, access::read>   image   [[texture(0)]],
    texture2d<float, access::read>   pair    [[texture(1)]],   // unblurred luma / dark
    texture2d<float, access::sample> small   [[texture(2)]],   // ~1 px
    texture2d<float, access::sample> medium  [[texture(3)]],   // ~4 px
    texture2d<float, access::sample> large   [[texture(4)]],   // ~1% of the frame
    texture2d<float, access::write>  output  [[texture(5)]],
    constant float &texture_                 [[buffer(0)]],
    constant float &clarity                  [[buffer(1)]],
    constant float &dehaze                   [[buffer(2)]],
    constant float &defringePurple           [[buffer(3)]],
    constant float &defringeGreen            [[buffer(4)]],
    constant uint  &inputIsLinear            [[buffer(5)]],
    constant float &headroom                 [[buffer(6)]],
    uint2 gid                                [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    bool isLinear = inputIsLinear != 0;

    float2 uv = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());
    float3 lin = lcToLinear(image.read(gid).rgb, isLinear, headroom);
    float2 base = pair.read(gid).rg;
    float2 bS = small.sample(s, uv).rg;
    float2 bM = medium.sample(s, uv).rg;
    float2 bL = large.sample(s, uv).rg;

    // Dehaze first, in linear light. Atmospheric light is taken as white
    // (haze is bright and neutral); transmission from the blurred dark
    // channel. Negative amounts add haze by blending toward that light.
    if (dehaze > 0.0) {
        float t = clamp(1.0 - dehaze * 0.9 * bL.g, 0.15, 1.0);
        lin = (lin - 1.0) / t + 1.0;
        lin = max(lin, 0.0);
    } else if (dehaze < 0.0) {
        lin = mix(lin, float3(1.0), -dehaze * 0.5 * (1.0 - bL.g));
    }

    // Local contrast on perceptual luma. Recompute after dehaze so the
    // two agree; the blurs are of the un-dehazed image, close enough.
    float y = dot(lin, float3(0.2126, 0.7152, 0.0722));
    float l = lcPerceptual(y);
    float lOut = l;
    if (texture_ != 0.0) {
        float band = clamp(bS.r - bM.r, -0.2, 0.2);
        lOut += texture_ * 1.6 * band;
    }
    if (clarity != 0.0) {
        float band = clamp(bM.r - bL.r, -0.3, 0.3);
        float mid = clamp(4.0 * l * (1.0 - l), 0.0, 1.0);   // protect the ends
        lOut += clarity * 1.2 * band * (0.35 + 0.65 * mid);
    }
    lOut = max(lOut, 0.0);
    if (l > 1e-5 && lOut != l) {
        lin *= pow(lOut / l, 2.2);
    }

    // Defringe: purple or green colour on a strong luminance edge is
    // fringing; pull it toward neutral in proportion to edge strength.
    if (defringePurple > 0.0 || defringeGreen > 0.0) {
        float edge = smoothstep(0.04, 0.18, abs(base.r - bM.r));
        float2 hs = lcHueSat(lin);
        float purple = lcHueBand(hs.x, 0.70, 0.92, 0.04) * defringePurple;
        float green  = lcHueBand(hs.x, 0.22, 0.44, 0.04) * defringeGreen;
        float strength = clamp((purple + green) * edge * smoothstep(0.08, 0.3, hs.y), 0.0, 1.0);
        float yl = dot(lin, float3(0.2126, 0.7152, 0.0722));
        lin = mix(lin, float3(yl), strength);
    }

    output.write(float4(lcFromLinear(lin, isLinear, headroom), 1.0), gid);
}
