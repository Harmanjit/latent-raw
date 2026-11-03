#include <metal_stdlib>
using namespace metal;

// The finer detail controls and the Effects panel (DetailEffects.swift):
//
//   dfxDenoiseRefine   noise reduction's Contrast and Smoothness, a second
//                      pass after the bilateral filter, in camera space
//   dfxSharpenApply    sharpening with Detail (halo suppression) and
//                      Masking (edges only), and the Option-drag preview
//                      of the mask
//   dfxEffectsApply    post-crop vignetting, then grain, on the
//                      display-referred image after sharpening
//
// Each runs only when its controls are away from their defaults; the
// render skips the dispatch otherwise, so an untouched edit renders
// exactly as before. Names carry a `dfx` prefix because the runtime
// compiler sees every shader file as one source.

inline float dfxCameraLuma(float3 c) { return dot(c, float3(0.25, 0.5, 0.25)); }

// ---------------------------------------------------------------------
// Noise reduction, second pass.
//
// Contrast: what the bilateral filter took away is mostly noise, which
// changes sign from pixel to pixel, plus some real texture, which doesn't.
// Averaging the removed part over a small neighbourhood cancels the noise
// and keeps the texture, and adding that back restores contrast the filter
// flattened without bringing the noise with it.
//
// Smoothness: the bilateral filter is seven pixels wide, too small to see
// colour blotches (mottling) larger than that. A wider average of the
// colour ratios, weighted against crossing a brightness edge, evens them
// out. Colour only: luminance is left as the first pass made it.
// ---------------------------------------------------------------------
struct DfxDenoiseParams {
    float contrast;      // 0…1
    float smoothness;    // 0…1
    float reach;         // smoothness radius in this render's pixels
    float noiseScale;    // as the bilateral pass: 1 / binSpan
};

kernel void dfxDenoiseRefine(
    texture2d<float, access::read>  original [[texture(0)]],   // before noise reduction
    texture2d<float, access::read>  denoised [[texture(1)]],   // after the bilateral pass
    texture2d<float, access::write> output   [[texture(2)]],
    constant DfxDenoiseParams &p             [[buffer(0)]],
    uint2 gid                                [[thread_position_in_grid]])
{
    int w = int(denoised.get_width()), h = int(denoised.get_height());
    if (gid.x >= uint(w) || gid.y >= uint(h)) return;

    float3 centre = denoised.read(gid).rgb;
    float yc = max(dfxCameraLuma(centre), 0.0);
    float lumaOut = yc;

    if (p.contrast > 0.0) {
        float removed = 0.0, weight = 0.0;
        for (int dy = -2; dy <= 2; dy++) {
            for (int dx = -2; dx <= 2; dx++) {
                uint2 q = uint2(clamp(int(gid.x) + dx, 0, w - 1), clamp(int(gid.y) + dy, 0, h - 1));
                float wgt = exp(-float(dx * dx + dy * dy) / 4.5);
                removed += wgt * (dfxCameraLuma(original.read(q).rgb) - dfxCameraLuma(denoised.read(q).rgb));
                weight += wgt;
            }
        }
        lumaOut = max(yc + p.contrast * removed / weight, 0.0);
    }

    float3 chroma = centre / max(yc, 1e-4);
    if (p.smoothness > 0.0) {
        // Brightness tolerance like the bilateral pass's colour one, so
        // the average stops at real edges but not at noise.
        float noise = sqrt(yc + 1e-4) * p.noiseScale;
        float sigma = max(0.5 * noise, 1e-4);
        float inv = 1.0 / (2.0 * sigma * sigma);
        float3 sum = 0.0; float wsum = 0.0;
        float step_ = max(p.reach / 4.0, 1.0);
        for (int j = -4; j <= 4; j++) {
            for (int i = -4; i <= 4; i++) {
                int2 q = int2(round(float2(gid) + float2(i, j) * step_));
                q = clamp(q, int2(0), int2(w - 1, h - 1));
                float3 n = denoised.read(uint2(q)).rgb;
                float yn = max(dfxCameraLuma(n), 0.0);
                float d = yn - yc;
                float wgt = exp(-float(i * i + j * j) / 8.0) * exp(-d * d * inv);
                sum += wgt * (n / max(yn, 1e-4)); wsum += wgt;
            }
        }
        chroma = mix(chroma, sum / max(wsum, 1e-6), p.smoothness);
    }
    output.write(float4(lumaOut * chroma, 1.0), gid);
}

// ---------------------------------------------------------------------
// Sharpening with Detail and Masking (Detail.metal has the plain one).
//
// Detail: an unsharp mask overshoots on both sides of an edge, which is
// what a halo is. At Detail 1 nothing changes; below it the sharpened
// value is pulled back towards the range of its 3×3 neighbourhood, so
// edges get crisper without bright or dark rims. Fine texture, whose
// sharpened values stay inside that range anyway, is barely touched.
//
// Masking: the gradient of the blurred luminance says where the edges
// are. Masking raises the gradient needed before sharpening applies, so
// at high values skies and skin are left alone and only edges sharpen.
// The preview writes the mask itself, white where sharpening applies.
// ---------------------------------------------------------------------
struct DfxSharpenParams {
    float amount;
    float threshold;
    float detail;        // 0…1, 1 = plain unsharp mask
    float masking;       // 0…1, 0 = everywhere
    float binSpan;       // sensor pixels per render pixel
    uint  inputIsLinear;
    uint  showMask;
    uint  padding;
};

inline float dfxPerceptualLuma(float3 c, bool isLinear) {
    float y = dot(max(c, 0.0), float3(0.2126, 0.7152, 0.0722));
    return isLinear ? pow(y, 1.0 / 2.2) : y;
}

kernel void dfxSharpenApply(
    texture2d<float, access::read>  image   [[texture(0)]],
    texture2d<float, access::read>  blurred [[texture(1)]],
    texture2d<float, access::write> output  [[texture(2)]],
    constant DfxSharpenParams &p            [[buffer(0)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    int w = int(output.get_width()), h = int(output.get_height());
    if (gid.x >= uint(w) || gid.y >= uint(h)) return;
    bool isLinear = p.inputIsLinear != 0;
    float3 c = image.read(gid).rgb;
    float l = dfxPerceptualLuma(c, isLinear);
    float detail = l - blurred.read(gid).r;

    float mag = abs(detail);
    float pass = smoothstep(p.threshold, p.threshold * 2.0 + 1e-4, mag);

    // The edge mask, from the blurred luminance's slope per sensor pixel.
    float mask = 1.0;
    if (p.masking > 0.0) {
        uint2 xm = uint2(max(int(gid.x) - 1, 0), gid.y), xp = uint2(min(int(gid.x) + 1, w - 1), gid.y);
        uint2 ym = uint2(gid.x, max(int(gid.y) - 1, 0)), yp = uint2(gid.x, min(int(gid.y) + 1, h - 1));
        float2 g = float2(blurred.read(xp).r - blurred.read(xm).r,
                          blurred.read(yp).r - blurred.read(ym).r) * 0.5 / max(p.binSpan, 1.0);
        float t = p.masking * p.masking * 0.04;
        mask = smoothstep(0.5 * t, 1.5 * t + 1e-5, length(g));
    }
    if (p.showMask != 0) {
        float v = isLinear ? pow(mask, 2.2) : mask;
        output.write(float4(v, v, v, 1.0), gid);
        return;
    }

    float lSharp = max(l + p.amount * detail * pass * mask, 0.0);
    if (p.detail < 1.0) {
        float lo = l, hi = l;
        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                uint2 q = uint2(clamp(int(gid.x) + dx, 0, w - 1), clamp(int(gid.y) + dy, 0, h - 1));
                float n = dfxPerceptualLuma(image.read(q).rgb, isLinear);
                lo = min(lo, n); hi = max(hi, n);
            }
        }
        lSharp = mix(clamp(lSharp, lo, hi), lSharp, p.detail);
    }

    float ratio = (l > 1e-5) ? lSharp / l : 1.0;
    if (isLinear) ratio = pow(ratio, 2.2);
    output.write(float4(c * ratio, 1.0), gid);
}

// ---------------------------------------------------------------------
// Effects: post-crop vignetting, then grain.
//
// Both work out where each render pixel sits on the sensor, the way the
// lens pass does, so a binned preview, a 100 % tile and the export agree.
// The vignette measures that point in the crop's own frame (centre, size,
// straighten angle); the grain reads a fixed pattern at it.
// ---------------------------------------------------------------------
struct DfxEffectsParams {
    float2 tileOrigin;       // sensor px of output (0,0)
    float2 cropCentre;       // sensor px
    float2 cropHalfSize;     // sensor px, in the crop's frame
    float  binSpan;
    float  headroom;
    uint   inputIsLinear;
    // Post-crop vignette.
    uint   vignetteOn;
    uint   vignetteStyle;    // 0 highlight priority, 1 colour priority
    float  vignetteAmount;
    float  vignetteMidpoint;
    float  vignetteRoundness;
    float  vignetteFeather;
    float  vignetteHighlights;
    float  cropCos;
    float  cropSin;
    float  cropAspect;
    // Grain.
    uint   grainOn;
    float  grainAmount;
    float  grainCell;        // sensor px per grain
    float  grainRoughness;
    uint   grainSeed;
};

inline float3 dfxToLinear(float3 c, bool isLinear, float headroom) {
    return isLinear ? max(c, 0.0) / headroom : pow(max(c, 0.0), 2.2);
}
inline float3 dfxFromLinear(float3 l, bool isLinear, float headroom) {
    return isLinear ? max(l, 0.0) * headroom : pow(max(l, 0.0), 1.0 / 2.2);
}
inline float dfxLumaY(float3 lin) { return dot(lin, float3(0.2126, 0.7152, 0.0722)); }

// PostCropVignette.distance in DetailEffects.swift.
inline float dfxVignetteDistance(float2 u, float aspect, float r) {
    float2 q = u;
    if (r > 0.0) {
        float a = max(aspect, 1e-3);
        float norm = sqrt((a * a + 1.0) * 0.5);
        float2 circle = float2(u.x * a, u.y) / norm;
        q = u + (circle - u) * r;
    }
    float n = r < 0.0 ? 2.0 + 6.0 * (-r) : 2.0;
    float2 aq = abs(q);
    float d = pow(pow(aq.x, n) + pow(aq.y, n), 1.0 / n);
    return d * pow(2.0, 0.5 - 1.0 / n);
}

// PostCropVignette.mask.
inline float dfxVignetteMask(float2 u, constant DfxEffectsParams &p) {
    float d = dfxVignetteDistance(u, p.cropAspect, p.vignetteRoundness);
    float centre = 0.45 + 0.95 * p.vignetteMidpoint;
    float width = max(0.02, 1.4 * p.vignetteFeather);
    return smoothstep(centre - width * 0.5, centre + width * 0.5, d);
}

// A soft shoulder towards 1 for brightening, so a lightened corner rolls
// into white instead of clipping flat.
inline float dfxShoulder(float x) {
    const float k = 0.8;
    return x <= k ? x : k + (1.0 - k) * (1.0 - exp(-(x - k) / (1.0 - k)));
}

// Integer hash (lowbias32), the grain's only source of randomness.
inline uint dfxHash(uint x) {
    x ^= x >> 16; x *= 0x7feb352du;
    x ^= x >> 15; x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}

inline float dfxLattice(int2 c, uint seed) {
    uint h = dfxHash(uint(c.x) ^ dfxHash(uint(c.y) ^ dfxHash(seed)));
    return float(h) * (2.0 / 4294967295.0) - 1.0;
}

// Value noise: random values on a lattice, blended between. `smooth`
// picks the blend: 1 is a smooth (soft, round) grain, 0 a linear one
// whose grains have harder, more irregular edges.
inline float dfxValueNoise(float2 p, uint seed, float smooth_) {
    float2 i = floor(p);
    float2 f = p - i;
    float2 s = f * f * (3.0 - 2.0 * f);
    float2 t = mix(f, s, smooth_);
    int2 c = int2(i);
    float a = dfxLattice(c, seed), b = dfxLattice(c + int2(1, 0), seed);
    float d = dfxLattice(c + int2(0, 1), seed), e = dfxLattice(c + int2(1, 1), seed);
    return mix(mix(a, b, t.x), mix(d, e, t.x), t.y);
}

kernel void dfxEffectsApply(
    texture2d<float, access::read>  image  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant DfxEffectsParams &p           [[buffer(0)]],
    uint2 gid                              [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    bool isLinear = p.inputIsLinear != 0;
    float3 lin = dfxToLinear(image.read(gid).rgb, isLinear, p.headroom);
    float2 sensor = p.tileOrigin + (float2(gid) + 0.5) * p.binSpan;

    if (p.vignetteOn != 0) {
        float2 d = sensor - p.cropCentre;
        float2 f = float2(p.cropCos * d.x - p.cropSin * d.y, p.cropSin * d.x + p.cropCos * d.y);
        float2 u = f / max(p.cropHalfSize, float2(1.0));
        float v = dfxVignetteMask(u, p);
        float a = p.vignetteAmount;
        float y = dfxLumaY(lin);
        float l = pow(max(y, 0.0), 1.0 / 2.2);
        // How much a bright pixel keeps its brightness when darkening.
        float keep = a < 0.0 ? p.vignetteHighlights * smoothstep(0.5, 1.0, l) : 0.0;
        if (p.vignetteStyle == 0) {
            if (a < 0.0) {
                lin *= exp2(2.0 * a * v * (1.0 - keep));
            } else {
                float3 g = lin * exp2(1.5 * a * v);
                lin = float3(dfxShoulder(g.r), dfxShoulder(g.g), dfxShoulder(g.b));
            }
        } else {
            float target = a < 0.0 ? l * (1.0 + a * v * (1.0 - keep)) : l + (1.0 - l) * a * v;
            target = max(target, 0.0);
            if (l > 1e-5) {
                float ratio = pow(target / l, 2.2);
                float peak = max(lin.r, max(lin.g, lin.b));
                if (a > 0.0 && peak > 0.0) ratio = max(1.0, min(ratio, 1.0 / peak));
                lin *= ratio;
            } else if (a > 0.0) {
                lin += pow(target, 2.2);
            }
        }
    }

    if (p.grainOn != 0) {
        // A grain smaller than a render pixel averages out over it: the
        // pattern is read at the pixel's own scale, weaker by the ratio,
        // so a zoomed-out preview shows the export's grain as softened
        // texture rather than as noise of the wrong size.
        float cell = max(p.grainCell, p.binSpan);
        float coarse = min(1.0, p.grainCell / p.binSpan);
        float fineCell = max(p.grainCell * 0.5, p.binSpan);
        float fine = min(1.0, p.grainCell * 0.5 / p.binSpan);
        float r = p.grainRoughness;
        float n = dfxValueNoise(sensor / cell, p.grainSeed, 1.0 - 0.6 * r) * coarse
                + r * 0.8 * dfxValueNoise(sensor / fineCell + 17.31, p.grainSeed ^ 0x5bd1e995u, 0.0) * fine;
        n *= 1.9 / sqrt(1.0 + 0.64 * r * r);
        float y = dfxLumaY(lin);
        float l = pow(max(y, 0.0), 1.0 / 2.2);
        // Film shows grain most in the midtones, less in deep shadow and
        // bright highlights.
        float response = 0.3 + 0.7 * clamp(4.0 * l * (1.0 - l), 0.0, 1.0);
        float lNew = max(l + p.grainAmount * 0.12 * response * n, 0.0);
        float dy = pow(lNew, 2.2) - max(y, 0.0);
        lin = max(lin + dy, 0.0);
    }

    output.write(float4(dfxFromLinear(lin, isLinear, p.headroom), 1.0), gid);
}
