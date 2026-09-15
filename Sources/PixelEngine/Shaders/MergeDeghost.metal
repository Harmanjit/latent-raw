#include <metal_stdlib>
#include "Common.h"
using namespace metal;

// Photo Merge's deghosting kernels (docs/PhotoMerge.md section 3, stage 5).
// A ghost is something that moved between the frames of a bracket: merged
// as it is, a walking person shows up several times, half transparent.
// Deghosting finds where the frames disagree, and takes each moving area
// from one frame only, so the moving thing appears once and sharp.
//
// Everything here runs on quarter-size images ("mask pixels", 4 x 4
// photosites each): movement worth masking is far bigger than a pixel, and
// a quarter-size mask of a 45 MP frame is under 3 MB. MergeDeghostKernels.swift
// encodes the kernels, in this order:
//
//   1. `mergeDeghostMeasure`, per frame: how bright each block is, as an
//      interval of log2 scene brightness the block's true value lies in,
//      and its colour, as ratios that don't depend on exposure.
//   2. `mergeDeghostChooseReference`, per frame: keeps, for every block,
//      the frame that sees it best so far (the local reference).
//   3. `mergeDeghostCompare`, per frame: blocks that disagree with the
//      local reference, in brightness or in colour, by more than their
//      noise and more than a block of misalignment could explain.
//   4. `mergeDeghostPatch`, per frame: only disagreement that covers a
//      patch (noise disagrees in scattered single blocks, a moving object
//      in whole areas), collected over all frames into one map of movement.
//   5. On the CPU (`HDRGhostDetector`): the movement map is closed and
//      widened into moving *areas*, and each connected area gets one source
//      frame for all of it.
//   6. `mergeDeghostOwnership` and 7. `mergeDeghostCombine`, per frame: the
//      finished mask. Every frame is left out of every moving area, except
//      the area's source frame.
//
// **Why one map of movement for all frames.** Something that moved counts
// as moving in every frame, even in a frame that happens to agree with the
// reference there: a walking person's body overlaps itself from frame to
// frame, and where it does the frames agree, so masking each frame only
// where *it* disagrees would still blend several poses.
//
// **Why one source frame per area, not per block.** The best frame for a
// block changes from block to block: a dark shirt is nearly black in a
// short exposure, so a longer one sees it better. Taken block by block, a
// person became a patchwork of frames shot at different moments, with two
// heads, and translucent wherever the patchwork's seams blended them.
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

// A colour allowance at or above this many stops means "this block's
// colour can't be trusted" (clipped, too dark, or outside the frame):
// colour isn't compared there. The measurement writes `mergeDeghostNoColour`,
// comfortably above, so a blend with it after warping still counts.
constant float mergeDeghostColourUntrusted = 4.0;
constant float mergeDeghostNoColour = 64.0;

// How far past its own 4 x 4 block a block's colour is measured, in
// photosites each way (an 8 x 8 footprint). A 4 x 4 block holds only four
// red and four blue photosites, on fixed sides of the block: across an edge
// its red and blue see different sides, so a pixel of shake would change
// its colour. Eight wide, every colour sees the whole footprint.
constant int mergeDeghostColourMargin = 2;

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
// `colour` gets the block's colour as two ratios in stops, log2(red /
// green) and log2(blue / green), and in blue how far noise could move
// either (three standard deviations of the ratio). Exposure divides out of
// a ratio, so a frame 4 stops darker has the same colour: a beige dress
// walking past a grey wall of the same brightness still differs. Where any
// photosite of the footprint is clipped, or a colour is too dark to have a
// ratio worth reading, the allowance is `mergeDeghostNoColour`.
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
    texture2d<float, access::write> colour   [[texture(2)]],
    uint2 gid                                [[thread_position_in_grid]])
{
    if (gid.x >= interval.get_width() || gid.y >= interval.get_height()) return;

    uint x0 = gid.x * span, y0 = gid.y * span;
    uint x1 = min(x0 + span, rawWidth), y1 = min(y0 + span, rawHeight);
    // The colour's wider footprint, clamped to the frame.
    int margin = mergeDeghostColourMargin;
    uint cx0 = uint(max(int(x0) - margin, 0)), cy0 = uint(max(int(y0) - margin, 0));
    uint cx1 = min(x1 + uint(margin), rawWidth), cy1 = min(y1 + uint(margin), rawHeight);

    float sum[3] = {0.0, 0.0, 0.0};
    float count[3] = {0.0, 0.0, 0.0};
    float wideSum[3] = {0.0, 0.0, 0.0};
    float wideCount[3] = {0.0, 0.0, 0.0};
    float clipped = 0.0, wideClipped = 0.0, total = 0.0;
    for (uint sy = cy0; sy < cy1; sy++) {
        bool rowInside = sy >= y0 && sy < y1;
        for (uint sx = cx0; sx < cx1; sx++) {
            uint8_t c = cfaColorRGB(cfaPattern, sx, sy);
            float raw = float(sensor[sy * rawWidth + sx]);
            float value = (raw - mergeDeghostBlackAt(channelBlack, cfaPattern, sx, sy)) * invRange;
            float isClipped = raw >= clipRaw ? 1.0 : 0.0;
            wideSum[c] += value;
            wideCount[c] += 1.0;
            wideClipped += isClipped;
            if (rowInside && sx >= x0 && sx < x1) {
                sum[c] += value;
                count[c] += 1.0;
                clipped += isClipped;
                total += 1.0;
            }
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

    // The colour, from the wider footprint. Each ratio's noise in stops is
    // the two colours' relative noise added in quadrature; the allowance is
    // three of the larger ratio's. A colour under `crushedCounts` counts on
    // average has no ratio worth reading, and a clipped photosite has lost
    // its colour's share, so neither is compared.
    float3 wideCounts = float3(wideSum[0] / max(wideCount[0], 1.0), wideSum[1] / max(wideCount[1], 1.0),
                               wideSum[2] / max(wideCount[2], 1.0)) / max(invRange, 1e-12);
    float3 relative = sqrt(max(wideCounts, float3(0.0)) + readNoiseCounts * readNoiseCounts)
                    / sqrt(max(float3(wideCount[0], wideCount[1], wideCount[2]), float3(1.0)))
                    / max(wideCounts, float3(1.0)) / M_LN2_F;
    float redNoise = sqrt(relative.r * relative.r + relative.g * relative.g);
    float blueNoise = sqrt(relative.b * relative.b + relative.g * relative.g);
    float allowance = 3.0 * max(redNoise, blueNoise);
    bool trusted = wideClipped == 0.0 && all(wideCounts >= float3(crushedCounts))
                && allowance < mergeDeghostColourUntrusted;
    float redRatio = log2(max(wideCounts.r, 1e-3) / max(wideCounts.g, 1e-3));
    float blueRatio = log2(max(wideCounts.b, 1e-3) / max(wideCounts.g, 1e-3));
    colour.write(float4(clamp(redRatio, -16.0, 16.0), clamp(blueRatio, -16.0, 16.0),
                        trusted ? allowance : mergeDeghostNoColour, 0.0), gid);
}

// 2. The local reference so far, updated with one more frame. `best` holds,
// per block, the chosen frame's interval (red, green), its priority (blue)
// and its index in the bracket (alpha); `bestColour` the chosen frame's
// colour, as `mergeDeghostMeasure` wrote it.
//
// A frame's priority is how usable the block is in it (feathered away from
// clipping, as the merge will weight it, times not crushed), plus `bonus`
// for the reference frame, minus `penalty` for every other frame (a small
// amount per stop from the reference). So the reference frame is the local
// reference wherever it sees the block reasonably well; elsewhere the frame
// that sees it best wins, and between equally good frames the one closest
// in exposure to the reference.
//
// The bonus fades out as the block nears clipping in the reference
// (smoothstep over the first half of usable): where the merge will give the
// reference no weight at all, as in water glittering in the sun, choosing
// it would leave nothing but the darkest frame's floor to fill the block.
kernel void mergeDeghostChooseReference(
    texture2d<float, access::read> interval         [[texture(0)]],
    texture2d<float, access::read> usable           [[texture(1)]],
    texture2d<float, access::read_write> best       [[texture(2)]],
    texture2d<float, access::read> colour           [[texture(3)]],
    texture2d<float, access::read_write> bestColour [[texture(4)]],
    constant float &frameIndex                      [[buffer(0)]],
    constant float &bonus                           [[buffer(1)]],
    constant float &penalty                         [[buffer(2)]],
    constant uint32_t &isFirst                      [[buffer(3)]],
    uint2 gid                                       [[thread_position_in_grid]])
{
    if (gid.x >= best.get_width() || gid.y >= best.get_height()) return;

    float4 measured = interval.read(gid);
    float usableHere = usable.read(gid).r;
    float priority = usableHere * measured.b + bonus * smoothstep(0.0, 0.5, usableHere) - penalty;
    float4 current = best.read(gid);
    if (isFirst != 0 || priority > current.b) {
        best.write(float4(measured.r, measured.g, priority, frameIndex), gid);
        bestColour.write(colour.read(gid), gid);
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
// Colour is compared the same way, each ratio give or take its allowance,
// where both the block and the other side's whole neighbourhood can be
// trusted. A block disagrees when
// the brightness gap is more than `gapStops` or a colour gap more than
// `colourStops`. Never where this frame is itself the local reference.
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

// The 3 x 3 neighbourhood's colour: the lowest and highest red ratio and
// blue ratio (each widened by its allowance). `found` is false unless every
// block of it is trusted: a neighbour that isn't (clipped, say) might have
// held the very colour the other frame shows, so the rest can't stand for
// the neighbourhood. A bright blue patch clipped in the brightest frame made
// the dim grey above it disagree with the reference's blue-tinged edge.
inline float4 mergeDeghostColourNeighbourhood(texture2d<float, access::read> image, int2 centre, int width,
                                              int height, thread bool &found) {
    float4 range = float4(mergeDeghostUnbounded, -mergeDeghostUnbounded, mergeDeghostUnbounded,
                          -mergeDeghostUnbounded);
    found = false;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            uint2 p = uint2(clamp(centre.x + dx, 0, width - 1), clamp(centre.y + dy, 0, height - 1));
            float4 value = image.read(p);
            if (value.b >= mergeDeghostColourUntrusted) return range;
            range = float4(min(range.x, value.r - value.b), max(range.y, value.r + value.b),
                           min(range.z, value.g - value.b), max(range.w, value.g + value.b));
        }
    }
    found = true;
    return range;
}

// How far `value` (give or take `allowance`) lies outside [low, high].
inline float mergeDeghostOutside(float value, float allowance, float low, float high) {
    return max(value - allowance - high, low - value - allowance);
}

kernel void mergeDeghostCompare(
    texture2d<float, access::read> interval    [[texture(0)]],
    texture2d<float, access::read> best        [[texture(1)]],
    texture2d<float, access::write> flags      [[texture(2)]],
    texture2d<float, access::read> colour      [[texture(3)]],
    texture2d<float, access::read> bestColour  [[texture(4)]],
    constant float &frameIndex                 [[buffer(0)]],
    constant float &gapStops                   [[buffer(1)]],
    constant float &colourStops                [[buffer(2)]],
    uint2 gid                                  [[thread_position_in_grid]])
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

    float colourGap = 0.0;
    float4 myColour = colour.read(gid), referenceColour = bestColour.read(gid);
    bool mineFound = false, referenceFound = false;
    float4 myColourAround = mergeDeghostColourNeighbourhood(colour, int2(gid), width, height, mineFound);
    float4 referenceColourAround = mergeDeghostColourNeighbourhood(bestColour, int2(gid), width, height,
                                                                   referenceFound);
    if (myColour.b < mergeDeghostColourUntrusted && referenceFound) {
        colourGap = max(colourGap, max(
            mergeDeghostOutside(myColour.r, myColour.b, referenceColourAround.x, referenceColourAround.y),
            mergeDeghostOutside(myColour.g, myColour.b, referenceColourAround.z, referenceColourAround.w)));
    }
    if (referenceColour.b < mergeDeghostColourUntrusted && mineFound) {
        colourGap = max(colourGap, max(
            mergeDeghostOutside(referenceColour.r, referenceColour.b, myColourAround.x, myColourAround.y),
            mergeDeghostOutside(referenceColour.g, referenceColour.b, myColourAround.z, myColourAround.w)));
    }
    bool disagrees = gap > gapStops || colourGap > colourStops;
    flags.write(float4(disagrees ? 1.0 : 0.0, 0.0, 0.0, 1.0), gid);
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

// 6. 1 where this frame is the source of the moving area, 0 elsewhere; the
// caller feathers it like the mask. `source` holds each block's source
// frame index in red (negative outside every moving area).
kernel void mergeDeghostOwnership(
    texture2d<float, access::read> source  [[texture(0)]],
    texture2d<float, access::write> owned  [[texture(1)]],
    constant float &frameIndex             [[buffer(0)]],
    uint2 gid                              [[thread_position_in_grid]])
{
    if (gid.x >= owned.get_width() || gid.y >= owned.get_height()) return;
    owned.write(float4(abs(source.read(gid).r - frameIndex) < 0.5 ? 1.0 : 0.0, 0.0, 0.0, 1.0), gid);
}

// 7. The finished ghost mask: the feathered moving areas, except where this
// frame is their source (feathered too). Without that exception the
// feathering could take a frame out of the very place it was chosen to
// fill, leaving no frame there at all.
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
