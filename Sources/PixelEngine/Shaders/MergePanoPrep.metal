#include <metal_stdlib>
#include "Common.h"
using namespace metal;

// Photo Merge panorama frame preparation (docs/PhotoMerge.md section 4,
// stage 2). MergePanoPrepKernels.swift encodes them; MergeKit/Pano/Prep
// decides which frames to prepare and at what size.
//
// A panorama photo is prepared once, before anything is stitched:
// - `mergePanoPrepBayerWindow` turns a window of the sensor into the CFA
//   plane the pipeline's RCD passes demosaic (full resolution only; reduced
//   sizes average whole blocks with `mergeHDRBinnedAnalysis` instead).
// - `mergePanoPrepLens` resamples the demosaiced window into the finished
//   frame: lens distortion, transverse chromatic aberration and vignetting
//   corrected (LensCorrect.metal's maths), turned upright, white balance
//   divided back out, and alpha 0 wherever the corrected frame reads from
//   outside the photo.
//
// Every helper here starts with `mergePanoPrep`: the runtime compiler joins
// all shader files into one source, so a name must be unique across all of
// them.

// The black level of the photosite at (x, y), counted from the active
// area's corner, as MergeHDR.metal's `mergeHDRBlackAt` reads it (a file
// that labels both greens 1 has its odd-row green counted as the second).
inline float mergePanoPrepBlackAt(float4 channelBlack, uint8_t pattern, uint x, uint y) {
    uint8_t colour = cfaColorAt(pattern, x, y);
    if (colour == 1 && (y & 1) == 1) colour = 3;
    return channelBlack[colour];
}

// Full resolution, step 1: the CFA plane for one window of the sensor.
// Pixel (0, 0) of `cfa` is photosite `origin` of the active area. The origin
// must be even in both directions, so the window's Bayer order is the
// sensor's and the RCD passes can be told the file's own order.
//
// Each colour loses its own black level, is normalised (white = 1), clamped
// at zero (RCD's colour ratios need non-negative input) and multiplied by
// the white balance `camMul`. Every frame of a panorama shares one white
// balance, so RCD sees the same colour balance in each; `mergePanoPrepLens`
// divides it back out.
kernel void mergePanoPrepBayerWindow(
    device const uint16_t *sensor         [[buffer(0)]],
    constant uint32_t &rawWidth           [[buffer(1)]],
    constant uint2 &origin                [[buffer(2)]],
    constant float4 &channelBlack         [[buffer(3)]],
    constant float &invRange              [[buffer(4)]],
    constant float4 &camMul               [[buffer(5)]],
    constant uint8_t &cfaPattern          [[buffer(6)]],
    texture2d<float, access::write> cfa   [[texture(0)]],
    uint2 gid                             [[thread_position_in_grid]])
{
    if (gid.x >= cfa.get_width() || gid.y >= cfa.get_height()) return;

    uint x = gid.x + origin.x, y = gid.y + origin.y;
    uint8_t colour = cfaColorAt(cfaPattern, x, y);
    float raw = float(sensor[y * rawWidth + x]);
    float value = max((raw - mergePanoPrepBlackAt(channelBlack, cfaPattern, x, y)) * invRange, 0.0);
    // The second green shares green's multiplier.
    float multiplier = colour == 0 ? camMul.x : colour == 2 ? camMul.z : camMul.y;
    cfa.write(float4(value * multiplier, 0.0, 0.0, 1.0), gid);
}

// Everything `mergePanoPrepLens` needs, as plain floats so the Swift side
// can fill it without worrying about how Metal pads vectors
// (MergePanoPrepKernels.LensParameters writes the same fields in the same
// order). Whole numbers (the switches, the distortion model) are stored as
// floats too; they are exact.
struct MergePanoPrepLensParameters {
    // The active area, in sensor pixels.
    float sensorWidth, sensorHeight;
    // Upright image point -> sensor point: sensor = (a·x + b·y + c, d·x + e·y + f).
    float a, b, c, d, e, f;
    // Full-resolution pixels per texel, of the output and of the source alike.
    float span;
    // The source texture's texel (0, 0), in source texels from the sensor's
    // corner (a full-resolution window's origin; 0 for a whole binned frame).
    float sourceOriginX, sourceOriginY;
    // The output row the dispatch's first row writes (bands of rows).
    float rowOffset;
    // Lensfun's radius scale (calibration crop factor over the camera's).
    float cropRatio;
    // Distortion: 0 none, 1 ptlens, 2 poly3, 3 poly5, then its terms.
    float distortionType, distortion1, distortion2, distortion3;
    // Transverse chromatic aberration, red and blue: b, c, v.
    float tcaOn, tcaRedB, tcaRedC, tcaRedV, tcaBlueB, tcaBlueC, tcaBlueV;
    // Vignetting (pa model): k1, k2, k3.
    float vignettingOn, vignetting1, vignetting2, vignetting3;
    // Divides the white balance the source was demosaiced with back out.
    float inverseMultiplierR, inverseMultiplierG, inverseMultiplierB;
    // 1: the source's alpha is its clipped share; carry it into `clipShare`.
    float carryClip;
};

inline float mergePanoPrepDistortionFactor(int type, float t1, float t2, float t3, float ru) {
    float ru2 = ru * ru;
    switch (type) {
        case 1: return t1 * ru2 * ru + t2 * ru2 + t3 * ru + (1.0 - t1 - t2 - t3); // ptlens
        case 2: return 1.0 - t1 + t1 * ru2;                                         // poly3
        case 3: return 1.0 + t1 * ru2 + t2 * ru2 * ru2;                             // poly5
        default: return 1.0;
    }
}

// A bilinear read at `q`, in source texel units with texel i's centre at
// i + 0.5, edges repeated (as LensCorrect.metal's `bilinearAt`, without
// its region offset, which `sourceOrigin` already takes out).
inline float4 mergePanoPrepBilinear(texture2d<float, access::read> tex, float2 q) {
    float2 p = clamp(q - 0.5, float2(-1.0e6), float2(1.0e6));
    float2 cell = floor(p);
    float2 fraction = p - cell;
    int2 last = int2(tex.get_width(), tex.get_height()) - 1;
    int2 lo = clamp(int2(cell), int2(0), last);
    int2 hi = clamp(int2(cell) + 1, int2(0), last);
    float4 t00 = tex.read(uint2(lo.x, lo.y)), t10 = tex.read(uint2(hi.x, lo.y));
    float4 t01 = tex.read(uint2(lo.x, hi.y)), t11 = tex.read(uint2(hi.x, hi.y));
    return mix(mix(t00, t10, fraction.x), mix(t01, t11, fraction.x), fraction.y);
}

// Full resolution step 2, or the only step for a reduced frame: one band of
// the finished frame.
//
// For each output texel, the inverse map, as in LensCorrect.metal: the
// texel's centre in the upright image, the sensor point it is, where the
// lens put that point in the uncorrected photo (distortion, then TCA for red
// and blue), and a bilinear read there. Vignetting is undone with the
// profile's gain. Unlike the editor's lens pass there is no auto scale (the
// corrected frame keeps the photo's own scale at its centre, so the camera
// model's focal length stays the photo's) and no perspective.
//
// **Alpha is coverage.** Where the green read falls outside the photo, the
// texel has no picture: it is written as 0 with alpha 0, so the stitcher
// leaves it out. The editor instead repeats the edge pixels, which in a
// panorama would smear streaks into the neighbouring frame. Red and blue
// reads a fraction of a pixel outside (TCA) just repeat the edge.
//
// `clipShare` receives the source's clipped share (its alpha) read the same
// way, 1 outside the photo, when `carryClip` is 1; the thumbnails the
// geometry measures need it, the full-size frames don't.
kernel void mergePanoPrepLens(
    texture2d<float, access::read> source      [[texture(0)]],
    texture2d<float, access::write> output     [[texture(1)]],
    texture2d<float, access::write> clipShare  [[texture(2)]],
    constant MergePanoPrepLensParameters &p    [[buffer(0)]],
    uint2 gid                                  [[thread_position_in_grid]])
{
    uint row = gid.y + uint(p.rowOffset);
    if (gid.x >= output.get_width() || row >= output.get_height()) return;

    // The texel's centre in the upright image, then on the sensor.
    float2 image = (float2(float(gid.x), float(row)) + 0.5) * p.span;
    float2 sensor = float2(p.a * image.x + p.b * image.y + p.c, p.d * image.x + p.e * image.y + p.f);

    float2 sensorSize = float2(p.sensorWidth, p.sensorHeight);
    float halfShort = min(sensorSize.x, sensorSize.y) * 0.5;
    float halfDiagonal = length(sensorSize) * 0.5;
    float2 centre = sensorSize * 0.5;

    // Distortion: where the undistorted point sits in the photo.
    float2 cu = sensor - centre;
    float ru = length(cu) / halfShort * p.cropRatio;
    float2 cd = cu * mergePanoPrepDistortionFactor(int(p.distortionType), p.distortion1, p.distortion2,
                                                   p.distortion3, ru);
    float2 green = cd + centre;

    bool inside = green.x >= 0.0 && green.y >= 0.0 && green.x <= sensorSize.x && green.y <= sensorSize.y;
    if (!inside) {
        output.write(float4(0.0), uint2(gid.x, row));
        if (p.carryClip == 1.0) clipShare.write(float4(1.0, 0.0, 0.0, 1.0), uint2(gid.x, row));
        return;
    }

    float2 origin = float2(p.sourceOriginX, p.sourceOriginY);
    float4 g = mergePanoPrepBilinear(source, green / p.span - origin);
    float3 colour = g.rgb;
    if (p.tcaOn == 1.0) {
        float rd = length(cd) / halfShort * p.cropRatio;
        float fr = p.tcaRedB * rd * rd + p.tcaRedC * rd + p.tcaRedV;
        float fb = p.tcaBlueB * rd * rd + p.tcaBlueC * rd + p.tcaBlueV;
        colour.r = mergePanoPrepBilinear(source, (cd * fr + centre) / p.span - origin).r;
        colour.b = mergePanoPrepBilinear(source, (cd * fb + centre) / p.span - origin).b;
    }

    // Vignetting: the lens darkened this point of the photo; undo it.
    float gain = 1.0;
    if (p.vignettingOn == 1.0) {
        float rv = length(cd) / halfDiagonal * p.cropRatio;
        float rv2 = rv * rv;
        float k = 1.0 + p.vignetting1 * rv2 + p.vignetting2 * rv2 * rv2 + p.vignetting3 * rv2 * rv2 * rv2;
        gain = 1.0 / max(k, 0.05);
    }
    float3 inverse = float3(p.inverseMultiplierR, p.inverseMultiplierG, p.inverseMultiplierB);
    // Clamped at zero: a reduced frame's block means aren't (noise around
    // black averages out there), but the stitcher blends in log space.
    output.write(float4(max(colour * inverse * gain, float3(0.0)), 1.0), uint2(gid.x, row));
    if (p.carryClip == 1.0) clipShare.write(float4(saturate(g.a), 0.0, 0.0, 1.0), uint2(gid.x, row));
}
