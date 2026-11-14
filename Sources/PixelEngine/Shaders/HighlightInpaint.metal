#include <metal_stdlib>
using namespace metal;

// Highlight Reconstruction › Inpaint Opposed (HighlightInpaint.swift,
// RenderPipeline stage 6a), after darktable's method of the same name.
//
// A channel at or past its clip level lost its real value; the two
// channels opposite it may not have. Each clipped channel is rebuilt as
// the mean of the other two times `ratio`, the colour of the unclipped
// ring around the image's clipped areas, worked out once for the whole
// frame on the CPU, so every tile agrees. The rebuilt value only ever
// raises a channel (it was clipped, so its true value was at least what
// it reads), and fades in from the threshold to the clip level so
// nothing steps at the threshold.
//
// Values are white-balanced camera RGB, as the seam hands them on;
// `clipLevel` is where each channel saturates in those units
// (`ImageSession.highlightClipLevel`).

struct HighlightInpaintParams {
    float4 clipLevel;   // xyz
    float4 ratio;       // xyz: channel over the mean of the other two
    float  threshold;   // fraction of clip where rebuilding starts
    float  amount;      // Recovery, 0...1
    float2 padding;
};

kernel void highlightInpaintOpposed(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant HighlightInpaintParams &p     [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float4 c = input.read(gid);
    float3 v = max(c.rgb, float3(0.0));
    float3 clip = max(p.clipLevel.xyz, float3(1e-6));
    float3 level = v / clip;   // 1 = clipped
    float t = clamp(p.threshold, 0.0, 0.999);
    // 0 at the threshold, 1 at the clip level and past it.
    float3 w = saturate((level - t) / max(1.0 - t, 0.01));
    if (max(w.r, max(w.g, w.b)) <= 0.0) {
        output.write(c, gid);
        return;
    }
    float3 opposite = float3(v.g + v.b, v.r + v.b, v.r + v.g) * 0.5;
    float3 rebuilt = max(v, opposite * p.ratio.xyz);
    float3 result = mix(v, rebuilt, w * saturate(p.amount));
    output.write(float4(result, c.a), gid);
}
