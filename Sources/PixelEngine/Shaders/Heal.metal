#include <metal_stdlib>
using namespace metal;

// Spot removal, in camera-linear space (before the lens stage so every
// coordinate is a sensor coordinate).
//
// Patches apply in order, each reading the image as the earlier ones left
// it, so a heal next to (or over) an earlier patch matches that patch
// rather than the blemish underneath. The pipeline copies the input into
// a working texture, then per patch:
//
//   healGather  weighted box averages of the surroundings of target and
//               source onto a coarse grid (heal only)
//   healBlur    separable Gaussian on both grids, once per axis (heal only)
//   healApply   the patch over its bounding box, into a scratch texture
//   healPaste   the scratch back into the working texture
//
// Clone copies the source pixels. Heal multiplies them by a ratio field,
// the target's surroundings over the source's, where "surroundings" is a
// Gaussian blur that leaves the patch itself out and renormalises
// (blur(image x w) / blur(w), w zero under the patch). Where the patch
// meets unpatched pixels the ratio is exactly what turns the source into
// the target, so tone and colour match along the whole edge, and inside
// it follows the surroundings from every side: a sky gradient, a cheek
// turning into shadow, a horizon crossing the patch. One rim-mean ratio
// for the whole patch (the previous method) is wrong on both sides of a
// horizon and leaves a blotch worse than the blemish; HealQualityTests
// has the numbers.
//
// Sigma is half the radius. The surroundings are smooth at that scale, so
// they are gathered onto cells of up to a quarter sigma and blurred there
// (about 40 x 40 cells per patch, whatever its size) instead of blurring
// every full-resolution pixel. Radius, sigma and cell size are in texture
// pixels (sensor pixels / binSpan), so a binned preview, a tile and an
// export agree.
//
// A brush stroke is healed in pieces, each a short segment of its path
// with a grid of its own (HealStroke.swift), since one grid over a wire
// across the frame would be most of the frame. Each piece reads a list of
// the stroke's segments near it: the distance to the nearest one gives
// the surroundings mask and the feathered edge, so both follow the whole
// stroke as one shape, and a piece writes only the pixels nearer its own
// segment than any other, so the pieces tile the stroke without overlap.
// Every piece reads the image as it was before the stroke (`before`, a
// copy HealStage makes), as a circle reads the image before it, so the
// pieces are independent of each other and a tile holds only the pieces
// it shows, however far the stroke runs.
// A circle has no list and takes the original path through every kernel.

struct HealPatchGPU {
    float4 geometry;   // target.xy, source.xy, normalized sensor
    float4 params;     // radius (fraction of short side), feather, mode (0 heal, 1 clone), unused
};

// Where one patch lands on the texture being rendered (HealStage.swift).
struct HealGridGPU {
    float2 target;       // target centre, texture pixels
    float2 offset;       // source centre minus target centre, texture pixels
    float radius;        // texture pixels
    float feather;
    float cell;          // texels per grid cell, a whole number
    float sigma;         // Gaussian sigma, in cells
    float2 gridOrigin;   // texture position of cell (0, 0)'s top-left corner
    int2 gridSize;       // cells
    int2 boxOrigin;      // texel at the scratch's top-left
    int2 boxSize;        // texels
    int maskCount;       // a stroke piece: segments in its list; 0 for a circle
    int ownIndex;        // the piece's own segment in that list
};

// Distance from `q` to the segment a-b (seg.xy, seg.zw), texture pixels.
inline float healSegmentDistance(float2 q, float4 seg) {
    float2 a = seg.xy, ab = seg.zw - seg.xy;
    float t = clamp(dot(q - a, ab) / max(dot(ab, ab), 1e-12), 0.0, 1.0);
    return length(q - (a + t * ab));
}

inline float2 healSensorToTexture(float2 sensorPx, float2 tileOrigin, float binSpan) {
    return (sensorPx - tileOrigin) / binSpan;
}

inline bool healInsideTexture(float2 t, texture2d<float, access::sample> tex) {
    return t.x >= 0.0 && t.y >= 0.0 && t.x < float(tex.get_width()) && t.y < float(tex.get_height());
}

// How much a pixel may inform the surroundings: none where the patch
// covers it by a third or more (the blemish and most of the feathered
// edge), fully where the patch doesn't reach.
inline float healFillWeight(float dist, float radius, float feather) {
    if (dist >= radius) return 1.0;
    float inner = (1.0 - feather) * radius;
    float coverage = dist <= inner ? 1.0 : 1.0 - smoothstep(inner, radius, dist);
    return 1.0 - smoothstep(0.0, 0.33, coverage);
}

// One thread per cell: the weighted means of the k x k texels under it,
// around the target and at the same offsets around the source. Alpha
// holds the mean weight, which the ratio divides back out. `state` is the
// image before the patch: for a stroke's pieces, before the stroke.
kernel void healGather(
    texture2d<float, access::sample> state   [[texture(0)]],
    texture2d<float, access::write>  target  [[texture(1)]],
    texture2d<float, access::write>  source  [[texture(2)]],
    constant HealGridGPU &g                  [[buffer(0)]],
    constant float4 *segments                [[buffer(1)]],
    uint2 gid                                [[thread_position_in_grid]])
{
    if (int(gid.x) >= g.gridSize.x || int(gid.y) >= g.gridSize.y) return;
    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);
    int k = int(g.cell);
    float2 corner = g.gridOrigin + float2(gid) * g.cell;
    float3 sumT = 0.0, sumS = 0.0;
    float sumW = 0.0;
    for (int j = 0; j < k; j++) {
        for (int i = 0; i < k; i++) {
            float2 q = corner + float2(i, j) + 0.5;
            float dist;
            if (g.maskCount > 0) {
                dist = 1e30;
                for (int m = 0; m < g.maskCount; m++) dist = min(dist, healSegmentDistance(q, segments[m]));
            } else {
                dist = length(q - g.target);
            }
            float w = healFillWeight(dist, g.radius, g.feather);
            if (w <= 0.0) continue;
            sumT += w * state.sample(s, q).rgb;
            sumS += w * state.sample(s, q + g.offset).rgb;
            sumW += w;
        }
    }
    float inv = 1.0 / float(k * k);
    target.write(float4(sumT * inv, sumW * inv), gid);
    source.write(float4(sumS * inv, sumW * inv), gid);
}

// Normalised Gaussian along one axis, on both grids at once. The grid
// textures are sized for the largest patch, so the edge clamps to this
// patch's own grid.
kernel void healBlur(
    texture2d<float, access::read>  inT     [[texture(0)]],
    texture2d<float, access::read>  inS     [[texture(1)]],
    texture2d<float, access::write> outT    [[texture(2)]],
    texture2d<float, access::write> outS    [[texture(3)]],
    constant HealGridGPU &g                 [[buffer(0)]],
    constant int &vertical                  [[buffer(1)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    if (int(gid.x) >= g.gridSize.x || int(gid.y) >= g.gridSize.y) return;
    int reach = min(int(ceil(3.0 * g.sigma)), 16);
    int2 axis = vertical != 0 ? int2(0, 1) : int2(1, 0);
    float twoSigmaSq = 2.0 * g.sigma * g.sigma;
    float4 sumT = 0.0, sumS = 0.0;
    float total = 0.0;
    for (int i = -reach; i <= reach; i++) {
        int2 p = clamp(int2(gid) + axis * i, int2(0), g.gridSize - 1);
        float w = exp(-float(i * i) / twoSigmaSq);
        sumT += w * inT.read(uint2(p));
        sumS += w * inS.read(uint2(p));
        total += w;
    }
    outT.write(sumT / total, gid);
    outS.write(sumS / total, gid);
}

// Bilinear read of a grid at a texture position. Float32 textures aren't
// filterable on every GPU, so this interpolates by hand.
inline float4 healField(texture2d<float, access::read> grid, float2 texturePos, constant HealGridGPU &g) {
    float2 u = (texturePos - g.gridOrigin) / g.cell - 0.5;
    float2 base = floor(u);
    float2 f = u - base;
    int2 hi = g.gridSize - 1;
    int2 p0 = clamp(int2(base), int2(0), hi);
    int2 p1 = clamp(int2(base) + 1, int2(0), hi);
    float4 top = mix(grid.read(uint2(p0.x, p0.y)), grid.read(uint2(p1.x, p0.y)), f.x);
    float4 bottom = mix(grid.read(uint2(p0.x, p1.y)), grid.read(uint2(p1.x, p1.y)), f.x);
    return mix(top, bottom, f.y);
}

kernel void healApply(
    texture2d<float, access::sample> state   [[texture(0)]],
    texture2d<float, access::read>   fieldT  [[texture(1)]],
    texture2d<float, access::read>   fieldS  [[texture(2)]],
    texture2d<float, access::write>  scratch [[texture(3)]],
    texture2d<float, access::sample> before  [[texture(4)]],   // the source is read from this
    constant HealPatchGPU &p                 [[buffer(0)]],
    constant HealGridGPU &g                  [[buffer(1)]],
    constant float2 &sensorSize              [[buffer(2)]],
    constant float2 &tileOrigin              [[buffer(3)]],
    constant float &binSpan                  [[buffer(4)]],
    constant float4 *segments                [[buffer(5)]],
    uint2 gid                                [[thread_position_in_grid]])
{
    if (int(gid.x) >= g.boxSize.x || int(gid.y) >= g.boxSize.y) return;
    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);

    float2 here = float2(int2(gid) + g.boxOrigin) + 0.5;
    float4 c = state.sample(s, here);
    float r, dist;
    float2 src;
    bool owned = true;
    if (g.maskCount > 0) {
        // A stroke piece, in texture pixels: the nearest segment decides
        // the edge; the piece writes only what is nearest its own (ties go
        // to the earlier piece, which lists before it).
        r = g.radius;
        float own = healSegmentDistance(here, segments[g.ownIndex]);
        dist = own;
        for (int m = 0; m < g.maskCount; m++) {
            if (m == g.ownIndex) continue;
            float other = healSegmentDistance(here, segments[m]);
            dist = min(dist, other);
            if (m < g.ownIndex ? other <= own : other < own) owned = false;
        }
        src = here + g.offset;
    } else {
        float2 sensorPx = tileOrigin + here * binSpan;
        float shortSide = min(sensorSize.x, sensorSize.y);
        r = p.params.x * shortSide;
        float2 d = sensorPx - p.geometry.xy * sensorSize;
        dist = length(d);
        src = healSensorToTexture(p.geometry.zw * sensorSize + d, tileOrigin, binSpan);
    }
    if (owned && dist < r && healInsideTexture(src, before)) {
        float4 v = before.sample(s, src);
        if (p.params.z < 0.5) {
            // Heal. A ratio in linear light, because texture is mostly
            // reflectance times illumination: pores copied from a lit
            // cheek into a shaded one keep the shaded contrast. Where
            // either side is near zero or negative a ratio means nothing
            // and the difference is added instead; with no surroundings
            // at all the source is copied as it is.
            float4 ft = healField(fieldT, here, g), fs = healField(fieldS, here, g);
            float support = max(ft.a, 1e-4);
            float3 ld = ft.rgb / support, ls = fs.rgb / support;
            float3 added = v.rgb + ld - ls;
            float3 ratio = v.rgb * (ld / max(ls, float3(1e-4)));
            float3 useRatio = smoothstep(0.002, 0.008, min(ls, ld));
            float3 healed = mix(added, ratio, useRatio);
            v.rgb = mix(v.rgb, healed, smoothstep(0.002, 0.02, ft.a));
        }
        // Feather: full inside (1 - feather) * r, fading to nothing at r.
        float inner = (1.0 - p.params.y) * r;
        float w = 1.0 - smoothstep(inner, r, dist);
        c.rgb = mix(c.rgb, v.rgb, w);
    }
    scratch.write(c, gid);
}

kernel void healPaste(
    texture2d<float, access::read>  scratch [[texture(0)]],
    texture2d<float, access::write> state   [[texture(1)]],
    constant HealGridGPU &g                 [[buffer(0)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    if (int(gid.x) >= g.boxSize.x || int(gid.y) >= g.boxSize.y) return;
    state.write(scratch.read(gid), uint2(int2(gid) + g.boxOrigin));
}
