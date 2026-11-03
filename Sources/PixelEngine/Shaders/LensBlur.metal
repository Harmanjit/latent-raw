#include <metal_stdlib>
using namespace metal;

// Lens Blur (docs/wiki/Develop.md, "Lens Blur"): a shallow depth of field
// over the session's depth map, on the graded, display-referred image
// right after the colour stage (so after the local adjustments).
//
// Three passes (LensBlurStage.swift):
//
// 1. lensBlurPrepare shrinks the picture by `factor` into linear light,
//    with Boost Highlights applied, and stores each pixel's blur radius
//    (the "circle of confusion", from its depth and the focus range) in
//    alpha. Shrinking keeps the largest blur to at most 16 pixels, so the
//    gather below costs the same at any zoom.
// 2. lensBlurGather blurs that copy by scattering-as-gathering: each
//    pixel looks at a fixed disc of taps and takes a neighbour wherever
//    the neighbour's own blur disc (in the bokeh's shape) reaches it,
//    weighted by one over that disc's area so a large disc spreads its
//    light thinner. A neighbour behind this pixel may not spread over it
//    further than this pixel's own blur, so a sharp subject does not get
//    the background smeared across it; a neighbour in front may (a blurred
//    foreground does overlap what is behind it). Alpha keeps how much of
//    the result came from such nearer neighbours.
// 3. lensBlurComposite mixes the full-resolution picture with the blur by
//    the pixel's own blur radius, or by the foreground's overlap where
//    that is larger. A pixel inside the focus range with nothing nearer
//    blurred over it is written back untouched, bit for bit.
//
// lensBlurDepthView is the viewport's Show Depth pass.
//
// Helpers are prefixed (lensBlur…): make_app.sh compiles each .metal file
// on its own while the runtime fallback concatenates them all, so names
// shared with another file fail one way or the other.

// Mirror of `LensBlurParamsGPU` in LensBlurStage.swift.
struct LensBlurParamsGPU {
    float2 tileOrigin;     // sensor px
    float2 sensorSize;     // sensor px
    float binSpan;         // sensor px per render px
    float factor;          // render px per shrunk px
    float maxRadius;       // shrunk px
    float focusFar;        // depth 0…1
    float focusNear;
    float fullBlurDepth;
    float boost;           // 0…1
    uint isLinear;         // 1 for the EDR viewport, 0 for an encoded file
    float headroom;
    uint shape;            // 0 circle, 1 bubble, 2 five blades
    uint tapCount;
    float padding;
};

constant float lensBlurPi = 3.14159265;

inline float3 lensBlurToLinear(float3 c, bool isLinear, float headroom) {
    return isLinear ? max(c, 0.0) / headroom : pow(max(c, 0.0), 2.2);
}
inline float3 lensBlurFromLinear(float3 l, bool isLinear, float headroom) {
    return isLinear ? l * headroom : pow(max(l, 0.0), 1.0 / 2.2);
}

// Where a render pixel (its centre, in render px) sits on the depth map.
inline float2 lensBlurSensorUV(float2 renderPx, constant LensBlurParamsGPU &p) {
    return (p.tileOrigin + renderPx * p.binSpan) / p.sensorSize;
}

inline float lensBlurDepthAt(texture2d<float, access::sample> depth, float2 uv) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    return depth.sample(s, uv).r;
}

// 0 inside the focus range, rising to 1 at fullBlurDepth beyond it. The
// Swift twin is LensBlur.blurFraction(atDepth:).
inline float lensBlurFraction(float d, constant LensBlurParamsGPU &p) {
    float distance = max(max(p.focusFar - d, d - p.focusNear), 0.0);
    return min(distance / p.fullBlurDepth, 1.0);
}

// Boost Highlights: up to 16x the light of the brightest pixels, rising
// steeply through the highlights. A lamp or a glint was far brighter than
// the white it was clipped to, and spread over a disc a hundred times its
// size it would otherwise fade to grey; with the boost it opens into a
// visible disc. Midtones are left alone.
inline float lensBlurBoostGain(float3 lin, float boost) {
    float y = dot(lin, float3(0.2126, 0.7152, 0.0722));
    float s = smoothstep(0.6, 1.0, pow(max(y, 0.0), 1.0 / 2.2));
    return 1.0 + 15.0 * boost * s * s * s;
}

// How far `offset` lies from a disc's centre in the bokeh's own measure:
// the plain length for a circle, the pentagon's norm for five blades (1
// on a pentagon whose corners touch the unit circle, a corner upward).
inline float lensBlurShapeDistance(float2 offset, uint shape) {
    float len = length(offset);
    if (shape != 2 || len <= 0.0) return len;
    float sector = 2.0 * lensBlurPi / 5.0;
    float a = atan2(offset.x, -offset.y);
    float t = fmod(a + 10.0 * lensBlurPi, sector) - sector * 0.5;
    return len * cos(t) / cos(lensBlurPi / 5.0);
}

kernel void lensBlurPrepare(
    texture2d<float, access::read>         input   [[texture(0)]],
    texture2d<float, access::write>        reduced [[texture(1)]],
    texture2d<float, access::sample>       depth   [[texture(2)]],
    constant LensBlurParamsGPU &p                  [[buffer(0)]],
    uint2 gid                                      [[thread_position_in_grid]])
{
    if (gid.x >= reduced.get_width() || gid.y >= reduced.get_height()) return;
    bool isLinear = p.isLinear != 0;
    uint f = uint(p.factor);
    uint w = input.get_width(), h = input.get_height();
    float3 sum = float3(0.0);
    float n = 0.0;
    for (uint dy = 0; dy < f; dy++) {
        for (uint dx = 0; dx < f; dx++) {
            uint2 q = gid * f + uint2(dx, dy);
            if (q.x >= w || q.y >= h) continue;
            float3 lin = lensBlurToLinear(input.read(q).rgb, isLinear, p.headroom);
            sum += lin * lensBlurBoostGain(lin, p.boost);
            n += 1.0;
        }
    }
    float3 colour = sum / max(n, 1.0);
    float d = lensBlurDepthAt(depth, lensBlurSensorUV((float2(gid) + 0.5) * p.factor, p));
    reduced.write(float4(colour, lensBlurFraction(d, p) * p.maxRadius), gid);
}

kernel void lensBlurGather(
    texture2d<float, access::sample>       reduced  [[texture(0)]],
    texture2d<float, access::write>        gathered [[texture(1)]],
    texture2d<float, access::sample>       depth    [[texture(2)]],
    constant LensBlurParamsGPU &p                   [[buffer(0)]],
    constant float2 *taps                           [[buffer(1)]],
    uint2 gid                                       [[thread_position_in_grid]])
{
    if (gid.x >= gathered.get_width() || gid.y >= gathered.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 size = float2(reduced.get_width(), reduced.get_height());
    float2 centre = float2(gid) + 0.5;
    float centreRadius = reduced.sample(s, centre / size).a;
    float centreDepth = lensBlurDepthAt(depth, lensBlurSensorUV(centre * p.factor, p));

    float3 sum = float3(0.0);
    float weights = 0.0, nearer = 0.0;
    for (uint i = 0; i < p.tapCount; i++) {
        float2 offset = taps[i] * p.maxRadius;
        float2 q = centre + offset;
        float4 tap = reduced.sample(s, q / size);
        float sampleDepth = lensBlurDepthAt(depth, lensBlurSensorUV(q * p.factor, p));
        float radius = tap.a;
        // Behind this pixel: it spreads over it no further than this
        // pixel's own blur, so a sharp subject keeps its outline.
        if (sampleDepth < centreDepth - 0.02) radius = min(radius, centreRadius);
        float distance = lensBlurShapeDistance(offset, p.shape);
        float cover = saturate(radius - distance + 1.0);
        if (cover <= 0.0) continue;
        float r = max(radius, 0.5);
        float weight = cover / (r * r);
        // Bubble: the disc's rim carries more light than its middle.
        if (p.shape == 1 && radius > 2.0) {
            weight *= 0.4 + 1.2 * smoothstep(0.55, 1.0, distance / radius);
        }
        sum += tap.rgb * weight;
        weights += weight;
        // Only a nearer neighbour that is itself blurred overlaps this
        // pixel; a sharp one a pixel away is just the edge of the subject.
        if (sampleDepth > centreDepth + 0.02 && radius >= 0.5) nearer += weight;
    }
    // The centre tap always covers itself, so `weights` is never zero.
    gathered.write(float4(sum / max(weights, 1e-6), nearer / max(weights, 1e-6)), gid);
}

kernel void lensBlurComposite(
    texture2d<float, access::read>         input    [[texture(0)]],
    texture2d<float, access::write>        output   [[texture(1)]],
    texture2d<float, access::sample>       gathered [[texture(2)]],
    texture2d<float, access::sample>       depth    [[texture(3)]],
    constant LensBlurParamsGPU &p                   [[buffer(0)]],
    uint2 gid                                       [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 src = input.read(gid);
    float2 centre = float2(gid) + 0.5;
    float d = lensBlurDepthAt(depth, lensBlurSensorUV(centre, p));
    // The pixel's own blur in shrunk pixels: one shrunk pixel or more
    // takes the blurred copy whole, less mixes it with the sharp picture.
    float own = lensBlurFraction(d, p) * p.maxRadius;
    float2 guv = centre / p.factor / float2(gathered.get_width(), gathered.get_height());
    float4 blurred = gathered.sample(s, guv);
    float t = max(smoothstep(0.0, 1.0, own), saturate(blurred.a));
    if (t <= 0.0) {
        output.write(src, gid);
        return;
    }
    bool isLinear = p.isLinear != 0;
    float3 lin = lensBlurToLinear(src.rgb, isLinear, p.headroom);
    float3 mixed = clamp(mix(lin, blurred.rgb, t), 0.0, 1.0);
    output.write(float4(lensBlurFromLinear(mixed, isLinear, p.headroom), src.a), gid);
}

// Show Depth: far blue through teal to near amber, the focus range washed
// toward white so the part that stays sharp is plain to see.
kernel void lensBlurDepthView(
    texture2d<float, access::read>         input  [[texture(0)]],
    texture2d<float, access::write>        output [[texture(1)]],
    texture2d<float, access::sample>       depth  [[texture(2)]],
    constant LensBlurParamsGPU &p                 [[buffer(0)]],
    uint2 gid                                     [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float d = lensBlurDepthAt(depth, lensBlurSensorUV(float2(gid) + 0.5, p));
    float3 farColour = float3(0.10, 0.16, 0.50), midColour = float3(0.10, 0.62, 0.60), nearColour = float3(1.00, 0.72, 0.18);
    float3 colour = d < 0.5 ? mix(farColour, midColour, d * 2.0) : mix(midColour, nearColour, d * 2.0 - 1.0);
    bool inFocus = d >= p.focusFar && d <= p.focusNear;
    colour = inFocus ? mix(colour, float3(1.0), 0.6) : colour * 0.8;
    float3 lin = pow(colour, 2.2);
    bool isLinear = p.isLinear != 0;
    output.write(float4(isLinear ? lin : colour, input.read(gid).a), gid);
}
