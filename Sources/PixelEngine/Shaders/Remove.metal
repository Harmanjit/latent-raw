#include <metal_stdlib>
using namespace metal;

// Content-aware Remove: the third spot-removal mode, which fills the area
// it covers with texture synthesised from around it instead of copying one
// source patch (RemoveStage.swift drives these kernels).
//
// The method is PatchMatch (Barnes et al. 2009) inside the expectation-
// maximisation loop of Wexler et al. (2007), coarse to fine:
//
//   removePrepare      the region around the hole, square-root encoded so
//                      distances weigh shadows fairly, and the hole mask
//   removeDownsample   the next pyramid level: known pixels averaged, a
//                      cell a hole if any pixel under it is
//   removeZone         which pixels need a match (the hole and a patch's
//                      reach around it) and which can be a source (no hole
//                      within a patch)
//   removeInitNNF      random matches at the coarsest level
//   removeUpsampleNNF  each finer level starts from the coarser matches
//   removePropagate    a pixel tries its neighbours' matches, shifted
//                      (a jump-flood step, so every pass is parallel)
//   removeRandomSearch a few random tries around the current match, the
//                      search radius halving each time
//   removeVote         each hole pixel becomes the weighted mean of what
//                      the matched patches overlapping it say it should be
//   removeComposite    the finished hole decoded back into the image
//
// Everything is deterministic: random numbers are a hash of the position,
// the level, the pass and a seed taken from the patch's id, and each pass
// reads one texture and writes another. A tile that holds the whole region
// therefore fills exactly as the whole frame does.

constant int removePatchRadius = 3;          // 7 x 7 patches
constant float removeNoMatch = 1e30;

struct RemoveRegionGPU {
    int2 size;            // level-0 region, texels
    int2 origin;          // region's top-left on the working texture
    float2 centre;        // circle centre, region pixels
    float radius;         // brush radius, region pixels
    int pathCount;        // stroke points in the buffer; 0 for a circle
    float2 maskOrigin;    // region position of the object mask's top-left
    float2 maskScale;     // mask cells per region pixel
    int2 maskSize;        // mask cells; 0 when the hole is the brush
    float opacity;        // how much of the fill replaces the image, 0…1
    float unused;
};

struct RemoveLevelGPU {
    int2 size;            // this level's region, texels
    int2 nnfOrigin;       // level position of the match texture's (0, 0)
    int2 nnfSize;
    uint seed;
    uint pass;
    int step;             // propagation distance
    int useHole;          // whether the hole's current estimate counts in distances
};

inline uint removeHash(uint x) {
    x ^= x >> 16; x *= 0x7feb352dU;
    x ^= x >> 15; x *= 0x846ca68bU;
    x ^= x >> 16;
    return x;
}

inline float2 removeRandom2(int2 p, uint seed, uint pass, uint k) {
    uint h = removeHash(uint(p.x) * 0x9E3779B1U ^ removeHash(uint(p.y) ^ removeHash(seed ^ (pass * 0x85EBCA6BU) ^ (k * 0xC2B2AE35U))));
    uint h2 = removeHash(h ^ 0x68E31DA4U);
    return float2(float(h & 0xFFFFFF), float(h2 & 0xFFFFFF)) / 16777216.0;
}

inline bool removeInside(int2 p, int2 size) {
    return p.x >= 0 && p.y >= 0 && p.x < size.x && p.y < size.y;
}

inline float removeSegmentDistance(float2 q, float2 a, float2 b) {
    float2 ab = b - a;
    float t = clamp(dot(q - a, ab) / max(dot(ab, ab), 1e-12), 0.0, 1.0);
    return length(q - (a + t * ab));
}

// Zone values: 0 a possible source, 1 near the hole (needs a match), 2 the hole.
inline bool removeIsSource(int2 s, int2 size, texture2d<uint, access::read> zone) {
    return s.x >= removePatchRadius && s.y >= removePatchRadius
        && s.x < size.x - removePatchRadius && s.y < size.y - removePatchRadius
        && zone.read(uint2(s)).r == 0;
}

// Mean squared difference per pixel between the patch around `q` and the
// one around source `s`. Without `useHole` the hole's pixels are left out:
// before the first fill they hold the object being removed.
inline float removeDistance(int2 q, int2 s, int2 size, bool useHole,
                            texture2d<float, access::read> img,
                            texture2d<uint, access::read> zone) {
    float sum = 0.0, count = 0.0;
    for (int dy = -removePatchRadius; dy <= removePatchRadius; dy++) {
        for (int dx = -removePatchRadius; dx <= removePatchRadius; dx++) {
            int2 t = q + int2(dx, dy);
            if (!removeInside(t, size)) continue;
            if (!useHole && zone.read(uint2(t)).r == 2) continue;
            float3 d = img.read(uint2(t)).rgb - img.read(uint2(s + int2(dx, dy))).rgb;
            sum += dot(d, d);
            count += 1.0;
        }
    }
    return count > 0.0 ? sum / count : 0.0;
}

inline bool removeNeedsMatch(int2 q, constant RemoveLevelGPU &L, texture2d<uint, access::read> zone) {
    return removeInside(q, L.size) && zone.read(uint2(q)).r != 0;
}

// One thread per region texel: the encoded colour, and whether it is hole.
kernel void removePrepare(
    texture2d<float, access::read>  working  [[texture(0)]],
    texture2d<float, access::write> img      [[texture(1)]],
    texture2d<uint, access::write>  hole     [[texture(2)]],
    texture2d<float, access::read>  mask     [[texture(3)]],
    constant RemoveRegionGPU &R              [[buffer(0)]],
    constant float2 *path                    [[buffer(1)]],
    uint2 gid                                [[thread_position_in_grid]])
{
    if (int(gid.x) >= R.size.x || int(gid.y) >= R.size.y) return;
    float4 c = working.read(uint2(int2(gid) + R.origin));
    float2 q = float2(gid) + 0.5;
    bool inHole;
    if (R.maskSize.x > 0) {
        int2 cell = int2(floor((q - R.maskOrigin) * R.maskScale));
        inHole = removeInside(cell, R.maskSize) && mask.read(uint2(cell)).r > 0.5;
    } else {
        float dist;
        if (R.pathCount > 1) {
            dist = removeNoMatch;
            for (int i = 1; i < R.pathCount; i++) dist = min(dist, removeSegmentDistance(q, path[i - 1], path[i]));
        } else {
            dist = length(q - R.centre);
        }
        // Every pixel the brush touches at all, so no fringe of the
        // object survives at the edge.
        inHole = dist <= R.radius + 0.5;
    }
    img.write(float4(sqrt(max(c.rgb, 0.0)), c.a), gid);
    hole.write(uint4(inHole ? 1 : 0), gid);
}

kernel void removeDownsample(
    texture2d<float, access::read>  fineImg   [[texture(0)]],
    texture2d<uint, access::read>   fineHole  [[texture(1)]],
    texture2d<float, access::write> coarseImg [[texture(2)]],
    texture2d<uint, access::write>  coarseHole [[texture(3)]],
    constant int2 &fineSize                   [[buffer(0)]],
    constant int2 &coarseSize                 [[buffer(1)]],
    uint2 gid                                 [[thread_position_in_grid]])
{
    if (int(gid.x) >= coarseSize.x || int(gid.y) >= coarseSize.y) return;
    float4 known = 0.0, all = 0.0;
    float nKnown = 0.0, nAll = 0.0;
    uint anyHole = 0;
    for (int j = 0; j < 2; j++) {
        for (int i = 0; i < 2; i++) {
            int2 f = int2(gid) * 2 + int2(i, j);
            if (!removeInside(f, fineSize)) continue;
            float4 c = fineImg.read(uint2(f));
            uint h = fineHole.read(uint2(f)).r;
            all += c; nAll += 1.0;
            if (h == 0) { known += c; nKnown += 1.0; } else { anyHole = 1; }
        }
    }
    coarseImg.write(nKnown > 0.0 ? known / nKnown : all / max(nAll, 1.0), gid);
    coarseHole.write(uint4(anyHole), gid);
}

kernel void removeZone(
    texture2d<uint, access::read>  hole [[texture(0)]],
    texture2d<uint, access::write> zone [[texture(1)]],
    constant int2 &size                 [[buffer(0)]],
    uint2 gid                           [[thread_position_in_grid]])
{
    int2 p = int2(gid);
    if (!removeInside(p, size)) return;
    uint z = 0;
    if (hole.read(gid).r != 0) {
        z = 2;
    } else {
        for (int dy = -removePatchRadius; dy <= removePatchRadius && z == 0; dy++) {
            for (int dx = -removePatchRadius; dx <= removePatchRadius; dx++) {
                int2 t = p + int2(dx, dy);
                if (removeInside(t, size) && hole.read(uint2(t)).r != 0) { z = 1; break; }
            }
        }
    }
    zone.write(uint4(z), gid);
}

// A uniformly random source, or none after a few misses.
inline bool removeRandomSource(int2 q, constant RemoveLevelGPU &L, uint salt,
                               texture2d<uint, access::read> zone, thread int2 &out) {
    int2 lo = int2(removePatchRadius);
    int2 span = L.size - 2 * removePatchRadius;
    if (span.x <= 0 || span.y <= 0) return false;
    for (uint k = 0; k < 24; k++) {
        float2 r = removeRandom2(q, L.seed, L.pass, salt * 31 + k);
        int2 s = lo + min(int2(r * float2(span)), span - 1);
        if (removeIsSource(s, L.size, zone)) { out = s; return true; }
    }
    return false;
}

kernel void removeInitNNF(
    texture2d<float, access::read>  img  [[texture(0)]],
    texture2d<uint, access::read>   zone [[texture(1)]],
    texture2d<float, access::write> nnf  [[texture(2)]],
    constant RemoveLevelGPU &L           [[buffer(0)]],
    uint2 gid                            [[thread_position_in_grid]])
{
    if (int(gid.x) >= L.nnfSize.x || int(gid.y) >= L.nnfSize.y) return;
    int2 q = int2(gid) + L.nnfOrigin;
    float4 result = float4(-1, -1, removeNoMatch, 0);
    int2 s;
    if (removeNeedsMatch(q, L, zone) && removeRandomSource(q, L, 1, zone, s)) {
        result = float4(float2(s), removeDistance(q, s, L.size, L.useHole != 0, img, zone), 1);
    }
    nnf.write(result, gid);
}

// Each match from the coarser level, doubled and offset by the pixel's
// place in its 2 x 2 block; a random source where that isn't one.
kernel void removeUpsampleNNF(
    texture2d<float, access::read>  img       [[texture(0)]],
    texture2d<uint, access::read>   zone      [[texture(1)]],
    texture2d<float, access::read>  coarse    [[texture(2)]],
    texture2d<float, access::write> nnf       [[texture(3)]],
    constant RemoveLevelGPU &L                [[buffer(0)]],
    constant RemoveLevelGPU &C                [[buffer(1)]],
    uint2 gid                                 [[thread_position_in_grid]])
{
    if (int(gid.x) >= L.nnfSize.x || int(gid.y) >= L.nnfSize.y) return;
    int2 q = int2(gid) + L.nnfOrigin;
    float4 result = float4(-1, -1, removeNoMatch, 0);
    if (removeNeedsMatch(q, L, zone)) {
        int2 cq = clamp(q / 2 - C.nnfOrigin, int2(0), C.nnfSize - 1);
        float4 m = coarse.read(uint2(cq));
        int2 s = int2(-1);
        bool found = false;
        if (m.w > 0.5) {
            s = int2(m.xy) * 2 + (q & 1);
            found = removeIsSource(s, L.size, zone);
            if (!found) {
                s = clamp(s, int2(removePatchRadius), L.size - removePatchRadius - 1);
                found = removeIsSource(s, L.size, zone);
            }
        }
        if (!found) found = removeRandomSource(q, L, 2, zone, s);
        if (found) result = float4(float2(s), removeDistance(q, s, L.size, L.useHole != 0, img, zone), 1);
    }
    nnf.write(result, gid);
}

inline float4 removeReadMatch(int2 q, constant RemoveLevelGPU &L, texture2d<float, access::read> nnf) {
    int2 n = q - L.nnfOrigin;
    if (!removeInside(n, L.nnfSize)) return float4(-1, -1, removeNoMatch, 0);
    return nnf.read(uint2(n));
}

// One jump-flood propagation step: the pixel's own match, rescored against
// the current fill, against its four neighbours' at `step`, shifted back.
kernel void removePropagate(
    texture2d<float, access::read>  img    [[texture(0)]],
    texture2d<uint, access::read>   zone   [[texture(1)]],
    texture2d<float, access::read>  nnfIn  [[texture(2)]],
    texture2d<float, access::write> nnfOut [[texture(3)]],
    constant RemoveLevelGPU &L             [[buffer(0)]],
    uint2 gid                              [[thread_position_in_grid]])
{
    if (int(gid.x) >= L.nnfSize.x || int(gid.y) >= L.nnfSize.y) return;
    int2 q = int2(gid) + L.nnfOrigin;
    float4 best = nnfIn.read(gid);
    if (!removeNeedsMatch(q, L, zone)) { nnfOut.write(best, gid); return; }
    bool useHole = L.useHole != 0;
    if (best.w > 0.5) best.z = removeDistance(q, int2(best.xy), L.size, useHole, img, zone);
    const int2 dirs[4] = { int2(-1, 0), int2(1, 0), int2(0, -1), int2(0, 1) };
    for (int k = 0; k < 4; k++) {
        int2 e = dirs[k] * L.step;
        int2 n = q + e;
        if (!removeNeedsMatch(n, L, zone)) continue;
        float4 m = removeReadMatch(n, L, nnfIn);
        if (m.w < 0.5) continue;
        int2 s = int2(m.xy) - e;
        if (!removeIsSource(s, L.size, zone)) continue;
        float d = removeDistance(q, s, L.size, useHole, img, zone);
        if (d < best.z) best = float4(float2(s), d, 1);
    }
    nnfOut.write(best, gid);
}

kernel void removeRandomSearch(
    texture2d<float, access::read>  img    [[texture(0)]],
    texture2d<uint, access::read>   zone   [[texture(1)]],
    texture2d<float, access::read>  nnfIn  [[texture(2)]],
    texture2d<float, access::write> nnfOut [[texture(3)]],
    constant RemoveLevelGPU &L             [[buffer(0)]],
    uint2 gid                              [[thread_position_in_grid]])
{
    if (int(gid.x) >= L.nnfSize.x || int(gid.y) >= L.nnfSize.y) return;
    int2 q = int2(gid) + L.nnfOrigin;
    float4 best = nnfIn.read(gid);
    if (!removeNeedsMatch(q, L, zone)) { nnfOut.write(best, gid); return; }
    bool useHole = L.useHole != 0;
    if (best.w < 0.5) {
        int2 s;
        if (removeRandomSource(q, L, 3, zone, s)) {
            best = float4(float2(s), removeDistance(q, s, L.size, useHole, img, zone), 1);
        }
    }
    if (best.w > 0.5) {
        float radius = float(max(L.size.x, L.size.y));
        uint k = 0;
        while (radius >= 1.0) {
            float2 r = removeRandom2(q, L.seed, L.pass, 100 + k) * 2.0 - 1.0;
            int2 s = int2(best.xy) + int2(round(r * radius));
            s = clamp(s, int2(0), L.size - 1);
            if (removeIsSource(s, L.size, zone)) {
                float d = removeDistance(q, s, L.size, useHole, img, zone);
                if (d < best.z) best = float4(float2(s), d, 1);
            }
            radius *= 0.5;
            k++;
        }
    }
    nnfOut.write(best, gid);
}

// Each hole pixel: the mean of the pixels the overlapping matched patches
// put there, each weighted by how well its patch matched. Known pixels are
// copied, so the output is the whole level.
kernel void removeVote(
    texture2d<float, access::read>  img    [[texture(0)]],
    texture2d<uint, access::read>   zone   [[texture(1)]],
    texture2d<float, access::read>  nnf    [[texture(2)]],
    texture2d<float, access::write> out    [[texture(3)]],
    constant RemoveLevelGPU &L             [[buffer(0)]],
    uint2 gid                              [[thread_position_in_grid]])
{
    int2 p = int2(gid);
    if (!removeInside(p, L.size)) return;
    float4 own = img.read(gid);
    if (zone.read(gid).r != 2) { out.write(own, gid); return; }
    float4 sum = 0.0;
    float weight = 0.0;
    for (int dy = -removePatchRadius; dy <= removePatchRadius; dy++) {
        for (int dx = -removePatchRadius; dx <= removePatchRadius; dx++) {
            int2 d = int2(dx, dy);
            int2 q = p - d;
            if (!removeNeedsMatch(q, L, zone)) continue;
            float4 m = removeReadMatch(q, L, nnf);
            if (m.w < 0.5) continue;
            int2 s = int2(m.xy) + d;
            // A small floor, so a perfect match (flat sky) doesn't take
            // every vote and two near-perfect ones share.
            float w = 1.0 / (m.z + 2e-4);
            sum += w * img.read(uint2(s));
            weight += w;
        }
    }
    out.write(weight > 0.0 ? sum / weight : own, gid);
}

// The filled hole, decoded, into the working texture; nothing else changes.
// Below full opacity the fill is mixed, in linear light, with `original`
// (the region as removePrepare first encoded it); at full opacity that
// texture isn't read and the fill is written exactly as it always was.
kernel void removeComposite(
    texture2d<float, access::read>  img      [[texture(0)]],
    texture2d<uint, access::read>   hole     [[texture(1)]],
    texture2d<float, access::write> working  [[texture(2)]],
    texture2d<float, access::read>  original [[texture(3)]],
    constant RemoveRegionGPU &R              [[buffer(0)]],
    uint2 gid                                [[thread_position_in_grid]])
{
    if (int(gid.x) >= R.size.x || int(gid.y) >= R.size.y) return;
    if (hole.read(gid).r == 0) return;
    float4 c = img.read(gid);
    float3 fill = c.rgb * c.rgb;
    if (R.opacity < 1.0) {
        float3 o = original.read(gid).rgb;
        fill = mix(o * o, fill, max(R.opacity, 0.0));
    }
    working.write(float4(fill, c.a), uint2(int2(gid) + R.origin));
}
