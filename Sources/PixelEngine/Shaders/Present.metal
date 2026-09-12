#include <metal_stdlib>
using namespace metal;

// Gets a rendered image onto the screen.
//
// Two mismatches have to be resolved between the pipeline's output and a
// CAMetalLayer drawable: the pixel format (rgba16Float vs bgra8Unorm) and
// the size (the render is sized to the viewport, but the window can be any
// shape). This kernel handles both, plus letterboxing so the image keeps
// its aspect ratio.
//
// Sampling rather than a straight copy means window resizes stay smooth:
// the image scales with bilinear filtering instead of snapping to whole
// pixels. Re-rendering at the new viewport resolution happens separately,
// and lands a frame or two later.
kernel void presentToScreen(
    texture2d<float, access::sample> source   [[texture(0)]],
    texture2d<float, access::write>  drawable [[texture(1)]],
    constant float2 &imageOrigin              [[buffer(0)]],
    constant float2 &imageSize                [[buffer(1)]],
    constant float &backgroundLevel           [[buffer(2)]],
    uint2 gid                                 [[thread_position_in_grid]])
{
    if (gid.x >= drawable.get_width() || gid.y >= drawable.get_height()) return;

    float2 uv = (float2(gid) - imageOrigin) / imageSize;

    // Outside the fitted image: neutral surround. A mid-dark grey rather
    // than black, which is what Lightroom and Capture One both use — pure
    // black next to an image biases how you judge its shadows.
    if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
        drawable.write(float4(backgroundLevel, backgroundLevel, backgroundLevel, 1.0), gid);
        return;
    }

    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 color = source.sample(s, uv);

    drawable.write(float4(color.rgb, 1.0), gid);
}
