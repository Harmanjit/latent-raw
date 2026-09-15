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
// Each layer is placed by a 3x2 affine matrix that takes a drawable pixel
// straight to that layer's normalized texture coordinate. Zoom, pan and
// rotation are all folded into it on the CPU; the kernel just samples.
// That's how the image rotates without the pipeline ever moving a pixel.
// Bilinear filtering keeps window resizes and mid-gesture upscales smooth.
//
// Pixel centres (+0.5) matter: at exactly 100% they make each screen pixel
// sample exactly one texel instead of a blend of two.
//
// Each layer was rendered to some headroom (its brightest possible value),
// the screen's *potential* headroom capped at 4, so the look doesn't depend
// on the brightness slider. What the screen can show right now is often
// less: brightness is down, or EDR is still ramping up. The last step rolls
// the highlights off to fit, which is why a brightness change only needs a
// present, never a render.

// Rolls off values above `knee` so they approach the display headroom
// instead of clipping. Hue is kept by scaling all channels by the same
// factor, driven by the largest one. Ported from minivu's canvas.
//
// What the curve guarantees (HeadroomToneMap in Presenter.swift is a
// line-for-line copy that the tests check):
// - Content that fits the display (every SDR render: headroom 1) passes
//   through untouched.
// - Below the knee nothing changes. The knee is 3/4 of the display
//   headroom, so on any screen with 1.33x headroom or more, SDR white and
//   everything under it keep their exact values; only a screen showing no
//   headroom at the moment gives up the top quarter of its range.
// - Above it the curve is continuous, rises monotonically with a slope
//   between 0 and 1 (it never brightens and never adds contrast), and
//   reaches exactly the display headroom at the content headroom. Anything
//   brighter than the content claims to be is held there.
inline float3 toneMapToHeadroom(float3 c, float displayHeadroom, float contentHeadroom) {
    float peak = max(c.r, max(c.g, c.b));
    if (contentHeadroom <= displayHeadroom || peak <= 0.0) { return c; }
    float knee = displayHeadroom * 0.75;
    if (peak <= knee) { return c; }
    // Map [knee, contentHeadroom] onto [knee, displayHeadroom] with a
    // smooth curve whose slope starts at 1 (no visible kink at the knee).
    float range = displayHeadroom - knee;
    float x = (peak - knee) / range;
    float xMax = (contentHeadroom - knee) / range;
    // Extended Reinhard: y = x (1 + x/xMax^2) / (1 + x), y(xMax) = 1.
    float y = x * (1.0 + x / (xMax * xMax)) / (1.0 + x);
    float mapped = knee + range * min(y, 1.0);
    return c * (mapped / peak);
}

kernel void presentToScreen(
    texture2d<float, access::sample> base     [[texture(0)]],
    texture2d<float, access::sample> tile     [[texture(1)]],
    texture2d<float, access::write>  drawable [[texture(2)]],
    constant float3x2 &baseMap                [[buffer(0)]],  // screen px -> base uv
    constant float3x2 &tileMap                [[buffer(1)]],  // screen px -> tile uv (inset region)
    constant float4 &tileSource               [[buffer(2)]],  // uv origin.xy, uv size.zw
    constant uint   &hasTile                  [[buffer(3)]],
    constant float  &backgroundLevel          [[buffer(4)]],
    constant float4 &headrooms                [[buffer(5)]],  // display, base content, tile content
    uint2 gid                                 [[thread_position_in_grid]])
{
    if (gid.x >= drawable.get_width() || gid.y >= drawable.get_height()) return;

    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float3 p = float3(float2(gid) + 0.5, 1.0);

    if (hasTile != 0) {
        float2 uv = tileMap * p;
        if (uv.x >= 0.0 && uv.y >= 0.0 && uv.x <= 1.0 && uv.y <= 1.0) {
            float4 c = tile.sample(s, tileSource.xy + uv * tileSource.zw);
            drawable.write(float4(toneMapToHeadroom(c.rgb, headrooms.x, headrooms.z), 1.0), gid);
            return;
        }
    }

    float2 uv = baseMap * p;
    if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
        // Outside the image: neutral surround. A mid-dark grey rather than
        // black — pure black next to an image biases how you judge its
        // shadows, which is why Lightroom and Capture One both use grey.
        drawable.write(float4(backgroundLevel, backgroundLevel, backgroundLevel, 1.0), gid);
        return;
    }
    float4 c = base.sample(s, uv);
    drawable.write(float4(toneMapToHeadroom(c.rgb, headrooms.x, headrooms.y), 1.0), gid);
}
