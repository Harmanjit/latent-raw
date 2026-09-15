#include <metal_stdlib>
using namespace metal;

// Lens corrections (DESIGN.md §8.1 stage 7, §9.2): distortion, transverse
// chromatic aberration and vignetting, from a Lensfun profile and/or
// manual amounts. Runs on the demosaiced camera-space image, before the
// colour matrix, as one resampling pass.
//
// It's an *inverse* map: for each clean output pixel, work out where in
// the crooked source it came from and sample there. The Lensfun models
// are written in exactly that direction (undistorted radius in,
// distorted radius out), which is why they can be applied directly.
//
// Coordinates are done in full-sensor pixels whatever the render scale,
// so a binned preview and a full-resolution tile agree on where every
// pixel lands. Radii are normalized the way the database expects: half
// the short side for distortion and TCA, half the diagonal for
// vignetting, both scaled by the calibration/camera crop ratio.

inline float distortionFactor(int type, float3 t, float ru) {
    float ru2 = ru * ru;
    switch (type) {
        case 1: return t.x * ru2 * ru + t.y * ru2 + t.z * ru + (1.0 - t.x - t.y - t.z); // ptlens
        case 2: return 1.0 - t.x + t.x * ru2;                                          // poly3
        case 3: return 1.0 + t.x * ru2 + t.y * ru2 * ru2;                              // poly5
        default: return 1.0;
    }
}

// A bilinear read at `q`, a point in texel units of the render's grid
// (texel i's centre at i + 0.5), from a texture whose texel 0 is grid
// texel `offset`. Done by hand rather than with a linear sampler for two
// reasons. The sampler keeps only a few bits of sub-texel position, and
// works from coordinates normalized by the texture's size, so the same
// point read from a region-sized and a full-size texture blended its four
// texels slightly differently; here the weights come from `q` alone, so a
// region render reads exactly what the full render reads. And edges clamp
// the way `clamp_to_edge` does.
inline float4 bilinearAt(texture2d<float, access::sample> tex, float2 q, int2 offset) {
    // Clamped first so a wild read (a keystone point near the horizon)
    // can't overflow the integer conversion; far outside is clamped anyway.
    float2 p = clamp(q - 0.5, float2(-1.0e6), float2(1.0e6));
    float2 cell = floor(p);
    float2 f = p - cell;
    int2 last = int2(tex.get_width(), tex.get_height()) - 1;
    int2 a = int2(cell) - offset;
    int2 lo = clamp(a, int2(0), last);
    int2 hi = clamp(a + 1, int2(0), last);
    float4 t00 = tex.read(uint2(lo.x, lo.y)), t10 = tex.read(uint2(hi.x, lo.y));
    float4 t01 = tex.read(uint2(lo.x, hi.y)), t11 = tex.read(uint2(hi.x, hi.y));
    return mix(mix(t00, t10, f.x), mix(t01, t11, f.x), f.y);
}

kernel void lensCorrect(
    texture2d<float, access::sample> input   [[texture(0)]],
    texture2d<float, access::write>  output  [[texture(1)]],
    constant float2 &sensorSize              [[buffer(0)]],
    constant float2 &tileOrigin              [[buffer(1)]],   // sensor px of output (0,0)
    constant float  &binSpan                 [[buffer(2)]],   // sensor px per output px
    constant float  &cropRatio               [[buffer(3)]],
    constant float  &autoScale               [[buffer(4)]],
    constant int    &distortionType          [[buffer(5)]],
    constant float3 &distortionTerms         [[buffer(6)]],
    constant float  &manualDistortion        [[buffer(7)]],   // extra poly3 k1
    constant int    &tcaEnabled              [[buffer(8)]],
    constant float3 &tcaRed                  [[buffer(9)]],   // b, c, v
    constant float3 &tcaBlue                 [[buffer(10)]],
    constant int    &vignettingEnabled       [[buffer(11)]],
    constant float3 &vignettingTerms         [[buffer(12)]],  // k1, k2, k3
    constant float  &manualVignetting        [[buffer(13)]],  // + brightens corners
    constant float3x3 &perspectiveInverse    [[buffer(14)]],  // keystone, output -> source, normalized
    constant float2 &sourceOrigin            [[buffer(15)]],  // sensor px of input (0,0)
    uint2 gid                                [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float halfShort = min(sensorSize.x, sensorSize.y) * 0.5;
    float halfDiag  = length(sensorSize) * 0.5;

    // Output pixel -> centred sensor coordinates of the corrected frame.
    float2 sensor = tileOrigin + (float2(gid) + 0.5) * binSpan;
    float2 cu = (sensor - sensorSize * 0.5) * autoScale;

    // Perspective: a homography in the undistorted frame, normalized by
    // half the short side so the slider means the same at every size.
    {
        float3 q = perspectiveInverse * float3(cu / halfShort, 1.0);
        cu = q.xy / max(q.z, 1e-4) * halfShort;
    }

    // Distortion: where the undistorted point sits in the source.
    float ru = length(cu) / halfShort * cropRatio;
    float f = distortionFactor(distortionType, distortionTerms, ru);
    if (manualDistortion != 0.0) f *= (1.0 - manualDistortion + manualDistortion * ru * ru);
    float2 cd = cu * f;

    // TCA: red and blue land at slightly different radii than green.
    float rd = length(cd) / halfShort * cropRatio;
    float fr = 1.0, fb = 1.0;
    if (tcaEnabled != 0) {
        fr = tcaRed.x * rd * rd + tcaRed.y * rd + tcaRed.z;
        fb = tcaBlue.x * rd * rd + tcaBlue.y * rd + tcaBlue.z;
    }

    // Source sensor coordinates -> texel units of this render's grid,
    // then into the input texture, which may start before the output
    // does: a region render demosaics a wider window so these reads stay
    // on real pixels (RenderPipeline.lensSourceWindow). Its origin is a
    // whole number of grid texels (0 for whole-frame renders).
    float2 centre = sensorSize * 0.5;
    int2 offset = int2(round(sourceOrigin / binSpan));
    float4 g = bilinearAt(input, (cd + centre) / binSpan, offset);
    float3 c = g.rgb;
    if (tcaEnabled != 0) {
        c.r = bilinearAt(input, (cd * fr + centre) / binSpan, offset).r;
        c.b = bilinearAt(input, (cd * fb + centre) / binSpan, offset).b;
    }

    // Vignetting: the source pixel was darkened by the lens; undo it.
    float rv = length(cd) / halfDiag * cropRatio;
    float rv2 = rv * rv;
    float gain = 1.0;
    if (vignettingEnabled != 0) {
        float k = 1.0 + vignettingTerms.x * rv2 + vignettingTerms.y * rv2 * rv2
                      + vignettingTerms.z * rv2 * rv2 * rv2;
        gain /= max(k, 0.05);
    }
    if (manualVignetting != 0.0) gain *= max(1.0 + manualVignetting * rv2, 0.05);

    output.write(float4(c * gain, 1.0), gid);
}
