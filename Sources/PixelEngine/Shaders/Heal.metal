#include <metal_stdlib>
using namespace metal;

// Spot removal, in camera-linear space (before the lens stage so every
// coordinate is a sensor coordinate).
//
// Two kernels. `healStats` measures, per patch, the mean colour of a ring
// just inside the target circle's edge and of the matching ring at the
// source: the rim is where a seam would show, so matching it is what
// makes a heal invisible. `healApply` then copies source pixels over the
// target, scaled by targetRim/sourceRim in heal mode, feathered at the
// edge. Both run on whatever texture the pipeline has — full frame,
// binned preview or a tile — using `tileOrigin` and `binSpan` to map
// sensor pixels onto it, exactly as the local-adjustment masks do.

struct HealPatchGPU {
    float4 geometry;   // target.xy, source.xy, normalized sensor
    float4 params;     // radius (fraction of short side), feather, mode (0 heal, 1 clone), unused
};

constant int kMaxHeals = 32;
constant int kStatsThreads = 256;

inline float2 sensorToTexture(float2 sensorPx, float2 tileOrigin, float binSpan) {
    return (sensorPx - tileOrigin) / binSpan;
}

inline bool insideTexture(float2 t, texture2d<float, access::sample> tex) {
    return t.x >= 0.0 && t.y >= 0.0 && t.x < float(tex.get_width()) && t.y < float(tex.get_height());
}

// One threadgroup per patch. Each thread samples a strided subset of a
// 16x16 grid over the circle's bounding square, keeping the samples that
// fall in the outer ring (0.7r…r) and whose source counterpart is on the
// texture. Sums are reduced across the group and the means written out.
kernel void healStats(
    texture2d<float, access::sample> input   [[texture(0)]],
    constant HealPatchGPU *patches           [[buffer(0)]],
    device float4 *stats                     [[buffer(1)]],   // [2 * kMaxHeals]: target means, then source means
    constant float2 &sensorSize              [[buffer(2)]],
    constant float2 &tileOrigin              [[buffer(3)]],
    constant float &binSpan                  [[buffer(4)]],
    uint patch                               [[threadgroup_position_in_grid]],
    uint tid                                 [[thread_index_in_threadgroup]],
    uint simdLane                            [[thread_index_in_simdgroup]],
    uint simdIndex                           [[simdgroup_index_in_threadgroup]])
{
    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);
    threadgroup float4 partialT[8];
    threadgroup float4 partialS[8];
    threadgroup float partialN[8];

    HealPatchGPU p = patches[patch];
    float shortSide = min(sensorSize.x, sensorSize.y);
    float r = p.params.x * shortSide;
    float2 target = p.geometry.xy * sensorSize;
    float2 source = p.geometry.zw * sensorSize;

    float4 sumT = 0.0, sumS = 0.0;
    float n = 0.0;
    for (int i = int(tid); i < 32 * 32; i += kStatsThreads) {
        float2 g = float2(float(i % 32) + 0.5, float(i / 32) + 0.5) / 32.0;   // 0…1 across the square
        float2 d = (g * 2.0 - 1.0) * r;
        float dist = length(d);
        if (dist < 0.7 * r || dist > r) continue;
        float2 tT = sensorToTexture(target + d, tileOrigin, binSpan);
        float2 tS = sensorToTexture(source + d, tileOrigin, binSpan);
        if (!insideTexture(tT, input) || !insideTexture(tS, input)) continue;
        sumT += input.sample(s, tT);
        sumS += input.sample(s, tS);
        n += 1.0;
    }
    sumT = simd_sum(sumT); sumS = simd_sum(sumS); n = simd_sum(n);
    if (simdLane == 0) { partialT[simdIndex] = sumT; partialS[simdIndex] = sumS; partialN[simdIndex] = n; }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid == 0) {
        float4 T = 0.0, S = 0.0; float N = 0.0;
        for (int i = 0; i < 8; i++) { T += partialT[i]; S += partialS[i]; N += partialN[i]; }
        float inv = N > 0.0 ? 1.0 / N : 0.0;
        stats[patch] = T * inv;
        stats[kMaxHeals + int(patch)] = S * inv;
    }
}

kernel void healApply(
    texture2d<float, access::sample> input   [[texture(0)]],
    texture2d<float, access::write>  output  [[texture(1)]],
    constant HealPatchGPU *patches           [[buffer(0)]],
    constant float4 *stats                   [[buffer(1)]],
    constant int &patchCount                 [[buffer(2)]],
    constant float2 &sensorSize              [[buffer(3)]],
    constant float2 &tileOrigin              [[buffer(4)]],
    constant float &binSpan                  [[buffer(5)]],
    uint2 gid                                [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);

    float2 here = float2(gid) + 0.5;
    float4 c = input.sample(s, here);
    float2 sensorPx = tileOrigin + here * binSpan;
    float shortSide = min(sensorSize.x, sensorSize.y);

    for (int i = 0; i < min(patchCount, kMaxHeals); i++) {
        HealPatchGPU p = patches[i];
        float r = p.params.x * shortSide;
        float2 d = sensorPx - p.geometry.xy * sensorSize;
        float dist = length(d);
        if (dist >= r) continue;
        float2 src = sensorToTexture(p.geometry.zw * sensorSize + d, tileOrigin, binSpan);
        if (!insideTexture(src, input)) continue;
        float4 v = input.sample(s, src);
        if (p.params.z < 0.5) {
            // Heal: match the rim. Ratios in linear light keep texture and
            // fix both brightness and colour cast; clamped so a black rim
            // can't blow the patch up.
            float4 t = stats[i], sm = stats[kMaxHeals + i];
            float3 ratio = clamp(t.rgb / max(sm.rgb, 1e-4), 0.25, 4.0);
            v.rgb *= ratio;
        }
        // Feather: full inside (1 - feather) * r, fading to nothing at r.
        float inner = (1.0 - p.params.y) * r;
        float w = 1.0 - smoothstep(inner, r, dist);
        c.rgb = mix(c.rgb, v.rgb, w);
    }
    output.write(c, gid);
}
