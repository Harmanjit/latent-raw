#include <metal_stdlib>
using namespace metal;

// Packs a rendered (display-encoded) texture into the final export
// pixels in one pass: crop, straighten, rotation and the last resize are
// all folded into one affine map from destination coordinates to source
// texture coordinates, and the write converts to 8- or 16-bit unorm
// because that's the destination texture's format. This replaces
// per-pixel CPU loops that took seconds for a 24 MP frame.
//
// `map` takes a normalized destination point (0...1 across the output)
// to a normalized source coordinate — the same inverse-mapping idea as
// the lens and present kernels. It's built on the CPU by CropFrame.
kernel void packForExport(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::write>  dest   [[texture(1)]],
    constant float3x2 &map                  [[buffer(0)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    if (gid.x >= dest.get_width() || gid.y >= dest.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

    float2 p = (float2(gid) + 0.5) / float2(dest.get_width(), dest.get_height());
    float2 uv = map * float3(p, 1.0);
    float4 c = source.sample(s, uv);
    dest.write(float4(clamp(c.rgb, 0.0, 1.0), 1.0), gid);
}
