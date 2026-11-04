#include <metal_stdlib>
using namespace metal;

// Flat-field correction (FlatField.swift, RenderPipeline stage 6b): each
// camera-RGB pixel multiplied by the reference's gain at its place on the
// sensor, mixed towards 1 by Amount. Positions are worked out in sensor
// pixels whatever the render's scale, so a binned preview and a
// full-resolution tile agree; the gain map is smooth, so the sampler's
// bilinear read is all it needs.

struct FlatFieldParams {
    float2 sensorSize;   // sensor px
    float2 origin;       // sensor px of the input's texel (0, 0)
    float  binSpan;      // sensor px per input texel
    float  amount;       // 0...1
    float2 padding;
};

kernel void flatFieldApply(
    texture2d<float, access::read>   input  [[texture(0)]],
    texture2d<float, access::write>  output [[texture(1)]],
    texture2d<float, access::sample> gain   [[texture(2)]],
    constant FlatFieldParams &p             [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 c = input.read(gid);
    float2 sensor = p.origin + (float2(gid) + 0.5) * p.binSpan;
    float3 g = gain.sample(s, sensor / p.sensorSize).rgb;
    output.write(float4(c.rgb * mix(float3(1.0), g, p.amount), c.a), gid);
}
