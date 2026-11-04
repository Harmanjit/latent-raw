#include <metal_stdlib>
using namespace metal;

// Distraction Removal › Reflections (ReflectionRemoval.swift): the graded,
// display-referred image right after the colour stage, times the gain
// map a reflection-removal model made, mixed in by the amount.
//
// The gains are linear-light ratios, so they apply directly to the EDR
// viewport's linear values and through a 2.2 power to an encoded file's.
// A ratio carries over the grading between the analysis render the model
// saw and this one, which a difference would not.

struct ReflectionParamsGPU {
    float2 tileOrigin;     // sensor px at the render's top-left
    float2 sensorSize;     // sensor px
    float binSpan;         // sensor px per render px
    float amount;          // 0…1
    uint isLinear;         // 1 for the EDR viewport, 0 for an encoded file
    float padding;
};

constant float reflectionGainRange = 2.0;  // ReflectionMap.gainRange

kernel void reflectionApply(
    texture2d<float, access::read>   input  [[texture(0)]],
    texture2d<float, access::write>  output [[texture(1)]],
    texture2d<float, access::sample> gains  [[texture(2)]],
    constant ReflectionParamsGPU &p         [[buffer(0)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 src = input.read(gid);
    float2 uv = (p.tileOrigin + (float2(gid) + 0.5) * p.binSpan) / p.sensorSize;
    float3 g = gains.sample(s, uv).rgb * reflectionGainRange;
    g = mix(float3(1.0), g, p.amount);
    float3 factor = p.isLinear != 0 ? g : pow(max(g, 0.0), 1.0 / 2.2);
    output.write(float4(max(src.rgb, 0.0) * factor, src.a), gid);
}
