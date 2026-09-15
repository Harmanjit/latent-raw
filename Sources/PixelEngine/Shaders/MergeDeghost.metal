#include <metal_stdlib>
#include "Common.h"
using namespace metal;

// Photo Merge's deghosting kernels (docs/PhotoMerge.md section 3, stage 5).
// A ghost is something that moved between the frames of a bracket: merged
// as it is, a walking person shows up several times, half transparent.
// Deghosting finds where the frames disagree with a *local reference* and
// takes every other frame out of the merge there, so the moving thing comes
// from one exposure only, once and sharp.
//
// Everything here runs on quarter-size images ("mask pixels", 4 x 4
// photosites each): movement worth masking is far bigger than a pixel, and
// a quarter-size mask of a 45 MP frame is under 3 MB. MergeDeghostKernels.swift
// encodes the kernels, in this order:
//
//   1. `mergeDeghostMeasure`, per frame: how bright each block is, as an
//      interval of log2 scene brightness the block's true value lies in.
//   2. `mergeDeghostChooseReference`, per frame: keeps, for every block,
//      the frame that sees it best so far (the local reference).
//   3. `mergeDeghostCompare`, per frame: blocks that disagree with the
//      local reference by more than their noise and more than a block of
//      misalignment could explain.
//   4. `mergeDeghostPatch`, per frame: only disagreement that covers a
//      patch (noise disagrees in scattered single blocks, a moving object
//      in whole areas), collected over all frames into one map of movement.
//   5. `mergeDeghostOwnership` and 6. `mergeDeghostCombine`, per frame: the
//      finished mask. It is the same movement map for every frame (widened
//      and feathered), except that a frame is never masked where it is
//      itself the local reference.
//
// **Why one map of movement for all frames.** Something that moved counts
// as moving in every frame, even in a frame that happens to agree with the
// reference there: a walking person's body overlaps itself from frame to
// frame, and where it does the frames agree, so masking each frame only
// where *it* disagrees would still blend several poses. Taking every frame
// but the local reference out of the whole moving area leaves exactly one.
//
// Every helper starts with `mergeDeghost`: each shader file is compiled on
// its own for the app's metallib but joined into one source when compiled
// at runtime, so a name must be unique across all of them.

// Black level of the photosite at (x, y), as MergeHDR.metal's
// mergeHDRBlackAt (kept separate: shader files can't share helpers).
inline float mergeDeghostBlackAt(float4 channelBlack, uint8_t pattern, uint x, uint y) {
    uint8_t colour = cfaColorAt(pattern, x, y);
    if (colour == 1 && (y & 1) == 1) colour = 3;
    return channelBlack[colour];
}

// A stand-in for "no limit" in an interval. Half floats hold it, and no real
// log2 brightness comes near it.
constant float mergeDeghostUnbounded = 10000.0;

// 1. One frame's blocks, measured straight from the sensor: each output pixel
// covers a `span` x `span` block of photosites (4 x 4 in practice).
//
// `interval` gets, in red and green, the lowest and highest log2 scene
// brightness the block can have, on the brightest frame's scale
// (`radianceScale` = 2^-relativeEV puts every frame there). Brightness is
// the mean of the block's red, green and blue at unit white balance.
// - An ordinary block: its brightness, give or take the noise it can hold
//   (three standard deviations of shot plus read noise over the block's
//   photosites, in stops). Dim blocks get a wide interval, bright ones a
//   narrow one, so noise alone rarely makes two frames disagree.
// - A clipped block (any photosite clipped, or a colour's mean above 90% of
//   its clip level): only a lower limit. The scene there is at least this
//   bright, maybe much brighter.
// - A crushed block (fewer than `crushedCounts` counts above black, where
//   read noise swamps the signal): only an upper limit.
// Blue holds how well exposed the block is apart from clipping: 0 when
// crushed, rising to 1 by four times that level.
//
// `usable` gets how far the block is from clipping, as the merge's own
// weights judge it (1 - smoothstep(0.80, 0.95, clipness)); the caller erodes
// and feathers it as the merge does before choosing references with it.
kernel void mergeDeghostMeasure(
    device const uint16_t *sensor            [[buffer(0)]],
    constant uint32_t &rawWidth              [[buffer(1)]],
    constant uint32_t &rawHeight             [[buffer(2)]],
    constant float4 &channelBlack            [[buffer(3)]],
    constant float &invRange                 [[buffer(4)]],
    constant float &clipRaw                  [[buffer(5)]],
    constant uint8_t &cfaPattern             [[buffer(6)]],
    constant uint32_t &span                  [[buffer(7)]],
    constant float4 &channelClip             [[buffer(8)]],
    constant float &radianceScale            [[buffer(9)]],
    constant float &crushedCounts            [[buffer(10)]],
    constant float &readNoiseCounts          [[buffer(11)]],
    texture2d<float, access::write> interval [[texture(0)]],
    texture2d<float, access::write> usable   [[texture(1)]],
    uint2 gid                                [[thread_position_in_grid]])
{
    if (gid.x >= interval.get_width() || gid.y >= interval.get_height()) return;

    uint x0 = gid.x * span, y0 = gid.y * span;
    uint x1 = min(x0 + span, rawWidth), y1 = min(y0 + span, rawHeight);
    float sum[3] = {0.0, 0.0, 0.0};
    float count[3] = {0.0, 0.0, 0.0};
    float clipped = 0.0, total = 0.0;
    for (uint sy = y0; sy < y1; sy++) {
        for (uint sx = x0; sx < x1; sx++) {
            uint8_t colour = cfaColorRGB(cfaPattern, sx, sy);
            float raw = float(sensor[sy * rawWidth + sx]);
            sum[colour] += (raw - mergeDeghostBlackAt(channelBlack, cfaPattern, sx, sy)) * invRange;
            count[colour] += 1.0;
            clipped += raw >= clipRaw ? 1.0 : 0.0;
            total += 1.0;
        }
    }
    float3 mean = float3(count[0] > 0.0 ? sum[0] / count[0] : 0.0,
                         count[1] > 0.0 ? sum[1] / count[1] : 0.0,
                         count[2] > 0.0 ? sum[2] / count[2] : 0.0);
    float3 ofClip = mean / max(channelClip.rgb, float3(1e-6));
    float clipness = max(clipped > 0.0 ? 1.0 : 0.0, max(ofClip.r, max(ofClip.g, ofClip.b)));

    float brightness = (mean.r + mean.g + mean.b) / 3.0;
    float counts = max(brightness / max(invRange, 1e-12), 0.0);
    // The standard deviation of the block's mean, in counts: shot noise
    // (about one electron per count) plus read noise, over the block's
    // photosites. Three of them, as a share of the signal, in stops.
    float sigma = sqrt(counts + readNoiseCounts * readNoiseCounts) / sqrt(max(total, 1.0));
    float noiseStops = min(3.0 * sigma / max(counts, 1.0) / M_LN2_F, 2.0);
    float level = log2(max(brightness, 1e-9) * radianceScale);

    float low = level - noiseStops, high = level + noiseStops;
    if (clipness >= 0.9) {
        high = mergeDeghostUnbounded;
    } else if (counts < crushedCounts) {
        low = -mergeDeghostUnbounded;
        high = log2(crushedCounts * invRange * radianceScale) + noiseStops;
    }
    float exposed = smoothstep(crushedCounts, 4.0 * crushedCounts, counts);
    interval.write(float4(low, high, exposed, 0.0), gid);
    usable.write(float4(1.0 - smoothstep(0.80, 0.95, clipness), 0.0, 0.0, 1.0), gid);
}

// 2. The local reference so far, updated with one more frame. `best` holds,
// per block, the chosen frame's interval (red, green), its priority (blue)
// and its index in the bracket (alpha).
//
// A frame's priority is how usable the block is in it (feathered away from
// clipping, as the merge will weight it, times not crushed), plus `bonus`
// for the reference frame, minus `penalty` for every other frame (a small
// amount per stop from the reference). So the reference frame is the local
// reference wherever it sees the block reasonably well; elsewhere the frame
// that sees it best wins, and between equally good frames the one closest
// in exposure to the reference. Where no frame sees it well (clipped in
// all of them), the reference keeps it: the bonus still counts.
kernel void mergeDeghostChooseReference(
    texture2d<float, access::read> interval    [[texture(0)]],
    texture2d<float, access::read> usable      [[texture(1)]],
    texture2d<float, access::read_write> best  [[texture(2)]],
    constant float &frameIndex                 [[buffer(0)]],
    constant float &bonus                      [[buffer(1)]],
    constant float &penalty                    [[buffer(2)]],
    constant uint32_t &isFirst                 [[buffer(3)]],
    uint2 gid                                  [[thread_position_in_grid]])
{
    if (gid.x >= best.get_width() || gid.y >= best.get_height()) return;

    float4 measured = interval.read(gid);
    float priority = usable.read(gid).r * measured.b + bonus - penalty;
    float4 current = best.read(gid);
    if (isFirst != 0 || priority > current.b) {
        best.write(float4(measured.r, measured.g, priority, frameIndex), gid);
    }
}

// 3. Blocks where this frame disagrees with the local reference.
//
// Each side is compared with the other's 3 x 3 neighbourhood (the lowest low
// and the highest high around it), not with the single block opposite: an
// edge that sits a block away in one frame (a pixel or two of shake, or the
// blur of a longer exposure) still fits inside the neighbourhood, so only
// real movement disagrees. Both directions count, because either can be the
// one that shows the change: a thin dark branch in the reference fits inside
// this frame's neighbourhood only if this frame has dark nearby too, and
// this frame's plain sky fits inside the reference's neighbourhood, which
// holds sky beside the branch.
//
// A block disagrees when either gap is more than `gapStops`. Never where
// this frame is itself the local reference.
inline float4 mergeDeghostNeighbourhood(texture2d<float, access::read> image, int2 centre, int width, int height) {
    float low = mergeDeghostUnbounded, high = -mergeDeghostUnbounded;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            uint2 p = uint2(clamp(centre.x + dx, 0, width - 1), clamp(centre.y + dy, 0, height - 1));
            float4 value = image.read(p);
            low = min(low, value.r);
            high = max(high, value.g);
        }
    }
    return float4(low, high, 0.0, 0.0);
}

kernel void mergeDeghostCompare(
    texture2d<float, access::read> interval  [[texture(0)]],
    texture2d<float, access::read> best      [[texture(1)]],
    texture2d<float, access::write> flags    [[texture(2)]],
    constant float &frameIndex               [[buffer(0)]],
    constant float &gapStops                 [[buffer(1)]],
    uint2 gid                                [[thread_position_in_grid]])
{
    int width = int(flags.get_width()), height = int(flags.get_height());
    if (int(gid.x) >= width || int(gid.y) >= height) return;

    float4 reference = best.read(gid);
    if (abs(reference.a - frameIndex) < 0.5) {
        flags.write(float4(0.0, 0.0, 0.0, 1.0), gid);
        return;
    }
    float4 mine = interval.read(gid);
    float4 mineAround = mergeDeghostNeighbourhood(interval, int2(gid), width, height);
    float4 referenceAround = mergeDeghostNeighbourhood(best, int2(gid), width, height);
    // How far each block's interval lies outside the other's neighbourhood.
    float mineOutside = max(mine.r - referenceAround.g, referenceAround.r - mine.g);
    float referenceOutside = max(reference.r - mineAround.g, mineAround.r - reference.g);
    float gap = max(mineOutside, referenceOutside);
    flags.write(float4(gap > gapStops ? 1.0 : 0.0, 0.0, 0.0, 1.0), gid);
}

// 4. Keeps a disagreement only where it covers a patch: at least
// `minimumCount` of the (2 x `radius` + 1)² blocks around this one disagree.
// Noise makes a block disagree now and then, but rarely many close together;
// something that moved makes a whole area disagree. The test also reaches a
// little past a moving object's edge, where fewer neighbours disagree but
// still enough.
//
// `seeds` gets this frame's result (for the report); `movement` collects
// every frame's, the largest so far (`isFirst` starts it afresh).
kernel void mergeDeghostPatch(
    texture2d<float, access::read> flags           [[texture(0)]],
    texture2d<float, access::write> seeds          [[texture(1)]],
    texture2d<float, access::read_write> movement  [[texture(2)]],
    constant int32_t &radius                       [[buffer(0)]],
    constant float &minimumCount                   [[buffer(1)]],
    constant uint32_t &isFirst                     [[buffer(2)]],
    uint2 gid                                      [[thread_position_in_grid]])
{
    int width = int(flags.get_width()), height = int(flags.get_height());
    if (int(gid.x) >= width || int(gid.y) >= height) return;

    float count = 0.0;
    for (int dy = -radius; dy <= radius; dy++) {
        int y = int(gid.y) + dy;
        if (y < 0 || y >= height) continue;
        for (int dx = -radius; dx <= radius; dx++) {
            int x = int(gid.x) + dx;
            if (x < 0 || x >= width) continue;
            count += flags.read(uint2(x, y)).r;
        }
    }
    float seed = count >= minimumCount ? 1.0 : 0.0;
    seeds.write(float4(seed, 0.0, 0.0, 1.0), gid);
    float before = isFirst != 0 ? 0.0 : movement.read(gid).r;
    movement.write(float4(max(before, seed), 0.0, 0.0, 1.0), gid);
}

// 5. 1 where this frame is the local reference, 0 elsewhere; the caller
// feathers it like the mask.
kernel void mergeDeghostOwnership(
    texture2d<float, access::read> best    [[texture(0)]],
    texture2d<float, access::write> owned  [[texture(1)]],
    constant float &frameIndex             [[buffer(0)]],
    uint2 gid                              [[thread_position_in_grid]])
{
    if (gid.x >= owned.get_width() || gid.y >= owned.get_height()) return;
    owned.write(float4(abs(best.read(gid).a - frameIndex) < 0.5 ? 1.0 : 0.0, 0.0, 0.0, 1.0), gid);
}

// 6. The finished ghost mask: the widened, feathered disagreement, except
// where this frame is the local reference (feathered too). Without that
// exception the widening could take a frame out of the very place it was
// chosen to fill, leaving no frame there at all.
kernel void mergeDeghostCombine(
    texture2d<float, access::read> ghost   [[texture(0)]],
    texture2d<float, access::read> owned   [[texture(1)]],
    texture2d<float, access::write> mask   [[texture(2)]],
    uint2 gid                              [[thread_position_in_grid]])
{
    if (gid.x >= mask.get_width() || gid.y >= mask.get_height()) return;
    float value = saturate(ghost.read(gid).r) * (1.0 - saturate(owned.read(gid).r));
    mask.write(float4(value, 0.0, 0.0, 1.0), gid);
}
