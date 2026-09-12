#include <metal_stdlib>
using namespace metal;

// Gets rendered images onto the screen.
//
// Two layers, composited in one pass:
//
//   base  — the whole image at reduced resolution. Always present once an
//           image is open, so no matter how far the user pans or pinches
//           there's never an empty region: at worst a soft, upscaled one.
//   tile  — optional, a full-resolution render of the visible area drawn
//           on top. This is what makes 100% zoom sharp. `tileSource`
//           selects a sub-rectangle of the tile texture in normalized
//           coordinates so the tile's border — where the demosaic had no
//           neighbours and clamped to itself — is never shown.
//
// Both layers are placed by screen-space rectangles that the CPU computes
// from the viewport transform; the kernel just samples. Bilinear filtering
// keeps window resizes and mid-gesture upscales smooth rather than blocky.
//
// Pixel centres (+0.5) matter: at exactly 100% they make each screen pixel
// sample exactly one texel instead of a blend of two.
kernel void presentToScreen(
    texture2d<float, access::sample> base     [[texture(0)]],
    texture2d<float, access::sample> tile     [[texture(1)]],
    texture2d<float, access::write>  drawable [[texture(2)]],
    constant float4 &baseRect                 [[buffer(0)]],  // x, y, w, h on screen
    constant float4 &tileRect                 [[buffer(1)]],
    constant float4 &tileSource               [[buffer(2)]],  // uv origin.xy, uv size.zw
    constant uint   &hasTile                  [[buffer(3)]],
    constant float  &backgroundLevel          [[buffer(4)]],
    uint2 gid                                 [[thread_position_in_grid]])
{
    if (gid.x >= drawable.get_width() || gid.y >= drawable.get_height()) return;

    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 p = float2(gid) + 0.5;

    if (hasTile != 0) {
        float2 uv = (p - tileRect.xy) / tileRect.zw;
        if (uv.x >= 0.0 && uv.y >= 0.0 && uv.x <= 1.0 && uv.y <= 1.0) {
            float4 c = tile.sample(s, tileSource.xy + uv * tileSource.zw);
            drawable.write(float4(c.rgb, 1.0), gid);
            return;
        }
    }

    float2 uv = (p - baseRect.xy) / baseRect.zw;
    if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
        // Outside the image: neutral surround. A mid-dark grey rather than
        // black — pure black next to an image biases how you judge its
        // shadows, which is why Lightroom and Capture One both use grey.
        drawable.write(float4(backgroundLevel, backgroundLevel, backgroundLevel, 1.0), gid);
        return;
    }
    float4 c = base.sample(s, uv);
    drawable.write(float4(c.rgb, 1.0), gid);
}
