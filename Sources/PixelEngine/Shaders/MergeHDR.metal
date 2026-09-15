#include <metal_stdlib>
#include "Common.h"
using namespace metal;

// Photo Merge's HDR kernels (docs/PhotoMerge.md section 3). A bracket is
// merged one frame at a time: each frame's sensor plane goes through
// `mergeHDRRawPrepare`, the existing RCD passes and `mergeHDRAccumulate`,
// then `mergeHDRResolve` turns the running sums into the merged image.
// `mergeHDRBinnedAnalysis` makes the small frames the exposure and
// alignment measurements read, and `mergeHDRDownsample` shrinks the result
// for its preview. HDRMergeKernels.swift encodes them.
//
// Every helper here starts with `mergeHDR`: the runtime compiler joins all
// shader files into one source, so a name must be unique across all of them.

// The black level of the photosite at (x, y). LibRaw numbers the colours
// 0 red, 1 green, 2 blue, 3 second green, the order of
// `RawSummary.channelBlackLevels`. Some files label both greens 1; the
// shim that measures the levels (clibraw_channel_black) then counts the
// green on an odd row as the second one, and so does this.
inline float mergeHDRBlackAt(float4 channelBlack, uint8_t pattern, uint x, uint y) {
    uint8_t colour = cfaColorAt(pattern, x, y);
    if (colour == 1 && (y & 1) == 1) colour = 3;
    return channelBlack[colour];
}

// A reduced frame for analysis: each output pixel is the mean of a
// `span` x `span` block of photosites, per colour, in normalised units
// (raw minus that colour's own black level, times `invRange`), and alpha
// is the share of the block's photosites at or above `clipRaw`.
//
// Why not the pipeline's `demosaicBinned`: it subtracts one black level
// shared by every colour, and a camera whose blue black sits a few counts
// higher than its red would then measure a different exposure ratio in
// each channel. It also can't say whether any photosite in a block was
// clipped, and a block whose mean looks fine but hides one clipped
// photosite gives a wrong ratio. Values aren't clamped at zero here, so
// noise around black averages out instead of adding a bias.
kernel void mergeHDRBinnedAnalysis(
    device const uint16_t *sensor         [[buffer(0)]],
    constant uint32_t &rawWidth           [[buffer(1)]],
    constant uint32_t &rawHeight          [[buffer(2)]],
    constant float4 &channelBlack         [[buffer(3)]],
    constant float &invRange              [[buffer(4)]],
    constant float &clipRaw               [[buffer(5)]],
    constant uint8_t &cfaPattern          [[buffer(6)]],
    constant uint32_t &span               [[buffer(7)]],
    texture2d<float, access::write> out   [[texture(0)]],
    uint2 gid                             [[thread_position_in_grid]])
{
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;

    uint x0 = gid.x * span, y0 = gid.y * span;
    uint x1 = min(x0 + span, rawWidth), y1 = min(y0 + span, rawHeight);
    float sum[3] = {0.0, 0.0, 0.0};
    float count[3] = {0.0, 0.0, 0.0};
    float clipped = 0.0, total = 0.0;
    for (uint sy = y0; sy < y1; sy++) {
        for (uint sx = x0; sx < x1; sx++) {
            uint8_t colour = cfaColorAt(cfaPattern, sx, sy);
            float raw = float(sensor[sy * rawWidth + sx]);
            uint8_t rgb = colour == 3 ? 1 : colour;
            sum[rgb] += (raw - mergeHDRBlackAt(channelBlack, cfaPattern, sx, sy)) * invRange;
            count[rgb] += 1.0;
            clipped += raw >= clipRaw ? 1.0 : 0.0;
            total += 1.0;
        }
    }
    float3 mean = float3(count[0] > 0.0 ? sum[0] / count[0] : 0.0,
                         count[1] > 0.0 ? sum[1] / count[1] : 0.0,
                         count[2] > 0.0 ? sum[2] / count[2] : 0.0);
    out.write(float4(mean, total > 0.0 ? clipped / total : 0.0), gid);
}

// Full resolution, the first step for each frame: the CFA plane RCD
// demosaics, and where the frame is clipped.
//
// `cfa` is what the pipeline's `blackLevelAndWhiteBalance` makes, except
// that each colour loses its own black level: normalised, clamped at zero
// (RCD's ratios need non-negative input, as in the pipeline) and multiplied
// by the white balance `camMul`, which every frame of the bracket shares so
// RCD sees the same colour balance in each.
//
// `clipMask` is 1 where the photosite read `clipRaw` or more. A clipped
// photosite's true value is unknown, and demosaicing spreads it into its
// neighbours' interpolated colours; `mergeHDRAccumulate` widens the mask
// to catch that.
kernel void mergeHDRRawPrepare(
    device const uint16_t *sensor              [[buffer(0)]],
    constant uint32_t &rawWidth                [[buffer(1)]],
    constant float4 &channelBlack              [[buffer(2)]],
    constant float &invRange                   [[buffer(3)]],
    constant float &clipRaw                    [[buffer(4)]],
    constant float4 &camMul                    [[buffer(5)]],
    constant uint8_t &cfaPattern               [[buffer(6)]],
    texture2d<float, access::write> cfa        [[texture(0)]],
    texture2d<float, access::write> clipMask   [[texture(1)]],
    uint2 gid                                  [[thread_position_in_grid]])
{
    if (gid.x >= cfa.get_width() || gid.y >= cfa.get_height()) return;

    uint8_t colour = cfaColorAt(cfaPattern, gid.x, gid.y);
    float raw = float(sensor[gid.y * rawWidth + gid.x]);
    float value = max((raw - mergeHDRBlackAt(channelBlack, cfaPattern, gid.x, gid.y)) * invRange, 0.0);
    // The second green shares green's multiplier.
    float multiplier = colour == 0 ? camMul.x : colour == 2 ? camMul.z : camMul.y;
    cfa.write(float4(value * multiplier, 0.0, 0.0, 1.0), gid);
    clipMask.write(float4(raw >= clipRaw ? 1.0 : 0.0, 0.0, 0.0, 1.0), gid);
}

// Adds one demosaiced frame to the running sums: rgb += w * radiance and
// alpha += w, in a 32-bit float texture that every frame writes in turn.
//
// - `rgb` is RCD's output. Multiplying by `inverseMultipliers` takes the
//   white balance back out, leaving camera RGB at unit white balance in
//   normalised units: the merge's own units.
// - `radianceScale` is 2^-relativeEV, which puts a darker frame's values on
//   the brightest frame's scale (a frame 2 stops darker is multiplied by 4).
// - The weight is `weightScale` (2^relativeEV: more light means less shot
//   noise, so brighter frames count for more wherever they're good) times
//   how far the pixel is from clipping. "Clipness" is the larger of the
//   clip mask, widened to the 3 x 3 neighbourhood, and each channel's value
//   over that channel's clip level; the weight fades out between 80% and
//   95% of it. One weight for all three channels, so a handover between
//   frames can't shift the colour.
// - `weightFloor` is 0 except for the darkest frame, which keeps at least
//   1e-4: where every frame is clipped, the darkest one's value is the
//   best there is, and the floor makes it the result with no special case.
kernel void mergeHDRAccumulate(
    texture2d<float, access::read> rgb               [[texture(0)]],
    texture2d<float, access::read> clipMask          [[texture(1)]],
    texture2d<float, access::read_write> accumulator [[texture(2)]],
    constant float4 &inverseMultipliers              [[buffer(0)]],
    constant float4 &channelClip                     [[buffer(1)]],
    constant float &radianceScale                    [[buffer(2)]],
    constant float &weightScale                      [[buffer(3)]],
    constant float &weightFloor                      [[buffer(4)]],
    uint2 gid                                        [[thread_position_in_grid]])
{
    int width = int(accumulator.get_width()), height = int(accumulator.get_height());
    if (int(gid.x) >= width || int(gid.y) >= height) return;

    float spreadMask = 0.0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            uint2 p = uint2(clamp(int(gid.x) + dx, 0, width - 1), clamp(int(gid.y) + dy, 0, height - 1));
            spreadMask = max(spreadMask, clipMask.read(p).r);
        }
    }

    float3 unitWB = max(rgb.read(gid).rgb * inverseMultipliers.rgb, float3(0.0));
    float3 ofClip = unitWB / max(channelClip.rgb, float3(1e-6));
    float clipness = max(spreadMask, max(ofClip.r, max(ofClip.g, ofClip.b)));
    float weight = max(weightScale * (1.0 - smoothstep(0.80, 0.95, clipness)), weightFloor);

    float4 sums = accumulator.read(gid);
    accumulator.write(sums + float4(unitWB * (radianceScale * weight), weight), gid);
}

// The merged image: the weighted sums divided by the total weight, in half
// floats. Never NaN or negative, and no larger than a half float holds,
// which the DNG writer and `LinearPlane` both rely on.
kernel void mergeHDRResolve(
    texture2d<float, access::read> accumulator [[texture(0)]],
    texture2d<float, access::write> merged     [[texture(1)]],
    uint2 gid                                  [[thread_position_in_grid]])
{
    if (gid.x >= merged.get_width() || gid.y >= merged.get_height()) return;

    float4 sums = accumulator.read(gid);
    float3 value = sums.a > 0.0 ? sums.rgb / sums.a : float3(0.0);
    value = select(value, float3(0.0), isnan(value));
    merged.write(float4(clamp(value, 0.0, 65504.0), 1.0), gid);
}

// A box-filtered reduction of the merged image by a whole `span`, for its
// preview, multiplied by `scale` (the DNG's normalisation, so the preview
// holds the values the file will). Summed in 32-bit floats: the merge's
// values run far above 1.0.
kernel void mergeHDRDownsample(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> small [[texture(1)]],
    constant uint32_t &span               [[buffer(0)]],
    constant float &scale                 [[buffer(1)]],
    uint2 gid                             [[thread_position_in_grid]])
{
    if (gid.x >= small.get_width() || gid.y >= small.get_height()) return;

    uint x0 = gid.x * span, y0 = gid.y * span;
    uint x1 = min(x0 + span, source.get_width()), y1 = min(y0 + span, source.get_height());
    float3 sum = float3(0.0);
    for (uint y = y0; y < y1; y++) {
        for (uint x = x0; x < x1; x++) {
            sum += source.read(uint2(x, y)).rgb;
        }
    }
    float count = float((x1 - x0) * (y1 - y0));
    small.write(float4(count > 0.0 ? sum * (scale / count) : float3(0.0), 1.0), gid);
}
