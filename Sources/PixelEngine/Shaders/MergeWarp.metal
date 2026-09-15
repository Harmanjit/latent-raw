#include <metal_stdlib>
using namespace metal;

// Photo Merge's frame alignment kernels (docs/PhotoMerge.md section 2c).
// MergeWarpKernels.swift encodes them; MergeKit/Align decides what to
// align and by how much.
//
// - `mergeAlignReduce` shrinks a frame for the aligner: luminance and the
//   share of clipped pixels, through a Gaussian prefilter.
// - `mergeWarpRGBA` moves a frame onto the reference frame's pixel grid by
//   a homography, with Catmull-Rom (bicubic) sampling.
// - `mergeWarpMask` does the same for a one-channel mask, such as the HDR
//   merge's clip mask.
//
// Every helper here starts with `mergeWarp` or `mergeAlign`: the runtime
// compiler joins all shader files into one source, so a name must be
// unique across all of them.

// MARK: - Reduction for alignment

// One output pixel of the aligner's reduced frame. The output pixel's
// centre sits at (x + 0.5) / factor in the source (top-left origin, pixel
// centres at half-integers), and every source pixel within 3 sigma of it
// counts, weighted by a Gaussian of sigma = 0.5 / factor source pixels:
// half an output pixel, enough to stop fine detail aliasing into false
// edges that would mislead the aligner. Weights are renormalised where the
// window runs off the image, so edges don't darken.
//
// r: the weighted mean luminance of camera RGB, (R + 2G + B) / 4, after
//    multiplying by `channelScale` (the caller's way to take a white
//    balance back out).
// g: the weighted share of pixels that were clipped: any channel at or
//    above `channelClip` (already multiplied by the saturation fraction),
//    or marked in `clipMask` when `hasClipMask` is 1.
kernel void mergeAlignReduce(
    texture2d<float, access::read> source   [[texture(0)]],
    texture2d<float, access::read> clipMask [[texture(1)]],
    texture2d<float, access::write> reduced [[texture(2)]],
    constant float2 &factor                 [[buffer(0)]],
    constant float2 &sigma                  [[buffer(1)]],
    constant float4 &channelScale           [[buffer(2)]],
    constant float4 &channelClip            [[buffer(3)]],
    constant uint32_t &hasClipMask          [[buffer(4)]],
    constant uint32_t &rowOffset            [[buffer(5)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    uint outY = gid.y + rowOffset;
    if (gid.x >= reduced.get_width() || outY >= reduced.get_height()) return;

    int width = int(source.get_width()), height = int(source.get_height());
    // Index coordinates: pixel centres on integers.
    float2 centre = (float2(float(gid.x), float(outY)) + 0.5) / factor - 0.5;
    int radiusX = int(ceil(3.0 * sigma.x)), radiusY = int(ceil(3.0 * sigma.y));
    int x0 = max(int(floor(centre.x)) - radiusX, 0), x1 = min(int(ceil(centre.x)) + radiusX, width - 1);
    int y0 = max(int(floor(centre.y)) - radiusY, 0), y1 = min(int(ceil(centre.y)) + radiusY, height - 1);
    // The Swift side keeps sigma at or below 5, so the window fits 32 taps.
    x1 = min(x1, x0 + 31);
    y1 = min(y1, y0 + 31);

    float weightsX[32];
    for (int x = x0; x <= x1; x++) {
        float d = float(x) - centre.x;
        weightsX[x - x0] = exp(-d * d / (2.0 * sigma.x * sigma.x));
    }
    float luminance = 0.0, clipped = 0.0, total = 0.0;
    for (int y = y0; y <= y1; y++) {
        float dy = float(y) - centre.y;
        float wy = exp(-dy * dy / (2.0 * sigma.y * sigma.y));
        for (int x = x0; x <= x1; x++) {
            float w = wy * weightsX[x - x0];
            uint2 p = uint2(x, y);
            float3 rgb = source.read(p).rgb * channelScale.rgb;
            bool isClipped = any(rgb >= channelClip.rgb) || (hasClipMask == 1 && clipMask.read(p).r > 0.0);
            luminance += w * dot(rgb, float3(0.25, 0.5, 0.25));
            clipped += isClipped ? w : 0.0;
            total += w;
        }
    }
    reduced.write(float4(total > 0.0 ? luminance / total : 0.0, total > 0.0 ? clipped / total : 1.0, 0.0, 1.0),
                  uint2(gid.x, outY));
}

// MARK: - Warping

// Catmull-Rom weights for the four samples around a point a fraction `t`
// past the second of them. Catmull-Rom is a cubic that passes exactly
// through the samples (at t = 0 the weights are 0, 1, 0, 0), so warping by
// a whole number of pixels moves values without blurring them, and it is
// sharper than bilinear sampling, which softens every frame a little
// differently and would leave the merge softer than any one frame.
inline float4 mergeWarpCatmullRom(float t) {
    float t2 = t * t, t3 = t2 * t;
    return float4(-0.5 * t3 + t2 - 0.5 * t,
                  1.5 * t3 - 2.5 * t2 + 1.0,
                  -1.5 * t3 + 2.0 * t2 + 0.5 * t,
                  0.5 * t3 - 0.5 * t2);
}

// Where the output pixel at (x, y) comes from in the source, in the
// source's top-left pixel coordinates. `referenceToMoving` is the 3 x 3
// homography, stored in the top-left of a 4 x 4 (the one matrix layout
// Swift's simd and Metal plainly agree on), and works on coordinates
// relative to each image's centre (`centres`: output centre x, y, then
// source centre x, y), which keeps 32-bit floats precise across a 45 MP
// frame. Returns false when the point is behind the camera or outside the
// source: a warp never invents pixels.
inline bool mergeWarpSourcePoint(float4x4 referenceToMoving, float4 centres, uint x, uint y,
                                 float sourceWidth, float sourceHeight, thread float2 &point) {
    float3 p = (referenceToMoving * float4(float(x) + 0.5 - centres.x, float(y) + 0.5 - centres.y, 1.0, 0.0)).xyz;
    if (!(p.z > 1e-6)) return false;
    point = p.xy / p.z + centres.zw;
    return point.x >= 0.0 && point.y >= 0.0 && point.x <= sourceWidth && point.y <= sourceHeight;
}

// An rgba16Float frame (camera RGB) moved onto the reference's pixel grid:
// each output pixel looks up where it lands in the moving frame (the
// inverse map, so every output pixel gets exactly one value and no holes
// appear) and samples it with Catmull-Rom over the 4 x 4 pixels around it.
//
// - The data is linear light, so the cubic's small overshoot next to a hard
//   edge can dip below zero; negative light doesn't exist, so it is
//   clamped to 0.
// - Alpha is coverage: 1 where the point lies inside the source, 0 outside,
//   where the colour is 0 too. The merge multiplies its weight by it.
// - Samples near the source's edge reuse the edge pixels for the part of
//   the 4 x 4 window that falls outside.
// - `rowOffset` lets the caller dispatch the image in bands of rows.
kernel void mergeWarpRGBA(
    texture2d<float, access::read> source  [[texture(0)]],
    texture2d<float, access::write> warped [[texture(1)]],
    constant float4x4 &referenceToMoving   [[buffer(0)]],
    constant float4 &centres               [[buffer(1)]],
    constant uint32_t &rowOffset           [[buffer(2)]],
    uint2 gid                              [[thread_position_in_grid]])
{
    uint y = gid.y + rowOffset;
    if (gid.x >= warped.get_width() || y >= warped.get_height()) return;

    int width = int(source.get_width()), height = int(source.get_height());
    float2 point;
    if (!mergeWarpSourcePoint(referenceToMoving, centres, gid.x, y, float(width), float(height), point)) {
        warped.write(float4(0.0), uint2(gid.x, y));
        return;
    }
    float2 index = point - 0.5;
    float2 base = floor(index);
    float4 wx = mergeWarpCatmullRom(index.x - base.x), wy = mergeWarpCatmullRom(index.y - base.y);
    int bx = int(base.x), by = int(base.y);
    float3 sum = float3(0.0);
    for (int j = 0; j < 4; j++) {
        int row = clamp(by - 1 + j, 0, height - 1);
        float3 rowSum = float3(0.0);
        for (int i = 0; i < 4; i++) {
            rowSum += wx[i] * source.read(uint2(clamp(bx - 1 + i, 0, width - 1), row)).rgb;
        }
        sum += wy[j] * rowSum;
    }
    sum = select(sum, float3(0.0), isnan(sum));
    warped.write(float4(max(sum, float3(0.0)), 1.0), uint2(gid.x, y));
}

// A one-channel mask moved the same way, in one of two modes (`mode`):
//
// 0. Bilinear: for soft masks and weights, where a blend of the four
//    nearest values is the right answer.
// 1. Footprint maximum: the largest value among the pixels the RGBA warp's
//    Catmull-Rom sample actually uses (those with a non-zero weight). For
//    the clip mask: if any clipped pixel fed an output colour, that output
//    counts as clipped, because a clipped value's error travels with it.
//    At a whole-pixel shift only one pixel has weight, so the mask moves
//    exactly as the colours do.
// 2. Nearest four maximum: the largest of the four pixels a bilinear sample
//    would blend (those with a non-zero weight), the four the Catmull-Rom
//    sample leans on (its outer taps weigh at most 7.4% each way). For the
//    HDR merge's clip mask: the merge widens the mask by a pixel all round
//    anyway (`mergeHDRAccumulate`), and a neighbouring output pixel's
//    nearest four are the outer taps of this one's, so after that widening
//    every output a clipped pixel fed is marked, as with mode 1. Mode 1
//    widened twice marked a ring more, and on glittering water the merge
//    then handed whole blocks over to darker frames, which showed as grey
//    squares.
//
// Outside the source the mask reads `outside`.
kernel void mergeWarpMask(
    texture2d<float, access::read> source  [[texture(0)]],
    texture2d<float, access::write> warped [[texture(1)]],
    constant float4x4 &referenceToMoving   [[buffer(0)]],
    constant float4 &centres               [[buffer(1)]],
    constant uint32_t &rowOffset           [[buffer(2)]],
    constant uint32_t &mode                [[buffer(3)]],
    constant float &outside                [[buffer(4)]],
    uint2 gid                              [[thread_position_in_grid]])
{
    uint y = gid.y + rowOffset;
    if (gid.x >= warped.get_width() || y >= warped.get_height()) return;

    int width = int(source.get_width()), height = int(source.get_height());
    float2 point;
    if (!mergeWarpSourcePoint(referenceToMoving, centres, gid.x, y, float(width), float(height), point)) {
        warped.write(float4(outside, 0.0, 0.0, 1.0), uint2(gid.x, y));
        return;
    }
    float2 index = point - 0.5;
    float2 base = floor(index);
    float2 t = index - base;
    int bx = int(base.x), by = int(base.y);
    float value = 0.0;
    if (mode == 0) {
        int xa = clamp(bx, 0, width - 1), xb = clamp(bx + 1, 0, width - 1);
        int ya = clamp(by, 0, height - 1), yb = clamp(by + 1, 0, height - 1);
        float top = mix(source.read(uint2(xa, ya)).r, source.read(uint2(xb, ya)).r, t.x);
        float bottom = mix(source.read(uint2(xa, yb)).r, source.read(uint2(xb, yb)).r, t.x);
        value = mix(top, bottom, t.y);
    } else if (mode == 2) {
        for (int j = 0; j < 2; j++) {
            if ((j == 0 ? 1.0 - t.y : t.y) < 1e-6) continue;
            int row = clamp(by + j, 0, height - 1);
            for (int i = 0; i < 2; i++) {
                if ((i == 0 ? 1.0 - t.x : t.x) < 1e-6) continue;
                value = max(value, source.read(uint2(clamp(bx + i, 0, width - 1), row)).r);
            }
        }
    } else {
        float4 wx = mergeWarpCatmullRom(t.x), wy = mergeWarpCatmullRom(t.y);
        for (int j = 0; j < 4; j++) {
            if (abs(wy[j]) < 1e-6) continue;
            int row = clamp(by - 1 + j, 0, height - 1);
            for (int i = 0; i < 4; i++) {
                if (abs(wx[i]) < 1e-6) continue;
                value = max(value, source.read(uint2(clamp(bx - 1 + i, 0, width - 1), row)).r);
            }
        }
    }
    warped.write(float4(value, 0.0, 0.0, 1.0), uint2(gid.x, y));
}
