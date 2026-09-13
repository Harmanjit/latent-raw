#include <metal_stdlib>
using namespace metal;

// Packs a rendered (display-encoded) texture into the final export
// pixels in one pass: rotation and the last resize are folded into the
// sampling, and the write converts to 8- or 16-bit unorm because that's
// the destination texture's format. This replaces per-pixel CPU loops
// that took seconds for a 24 MP frame in a debug build.
//
// `rotation` is quarter turns clockwise. For each destination pixel we
// ask "where in the unrotated source does this come from?" — the same
// inverse-mapping idea as the lens and present kernels.
kernel void packForExport(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::write>  dest   [[texture(1)]],
    constant uint &rotation                 [[buffer(0)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    if (gid.x >= dest.get_width() || gid.y >= dest.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

    float2 p = (float2(gid) + 0.5) / float2(dest.get_width(), dest.get_height());
    float2 uv;
    switch (rotation) {
        case 1:  uv = float2(p.y, 1.0 - p.x); break;        // 90° CW
        case 2:  uv = 1.0 - p; break;                        // 180°
        case 3:  uv = float2(1.0 - p.y, p.x); break;        // 270° CW
        default: uv = p; break;
    }
    float4 c = source.sample(s, uv);
    dest.write(float4(clamp(c.rgb, 0.0, 1.0), 1.0), gid);
}
