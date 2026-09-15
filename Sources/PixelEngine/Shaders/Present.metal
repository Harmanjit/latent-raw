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
// Bilinear filtering keeps window resizes and mid-gesture upscales smooth;
// past 200% the tile switches to nearest-neighbour (see `composite`).
//
// A third, optional layer is the press-and-hold magnifier: inside a circle
// at the pointer the same two-layer composite runs again at the loupe's
// zoom, from a small full-resolution tile of the area under it.
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

// Where the press-and-hold magnifier draws, and from what. Laid out like
// PresentLoupe in Presenter.swift.
struct Loupe {
    float3x2 baseMap;       // screen px -> base uv, at the loupe's zoom
    float3x2 tileMap;       // screen px -> loupe tile uv (inset region)
    float4   tileSource;    // uv origin.xy, uv size.zw
    float4   circle;        // centre.xy, radius, ring width (drawable px)
};

// Bits of `flags`.
constant uint kTileNearest      = 1u << 0;
constant uint kMagnifier        = 1u << 1;
constant uint kMagnifierHasTile = 1u << 2;
constant uint kMagnifierNearest = 1u << 3;

// One screen pixel of the picture: the full-resolution tile where it
// covers, the base layer elsewhere, the surround outside the image.
//
// Past 200% the tile is sampled nearest-neighbour, so every sensor pixel is
// a crisp square and demosaic, sharpening and noise artefacts show as they
// are; bilinear there would smear exactly what the user is checking. The
// base layer is only ever a soft stand-in and always stays bilinear.
inline float3 composite(float3 p,
                        texture2d<float, access::sample> base, float3x2 baseMap,
                        texture2d<float, access::sample> tile, float3x2 tileMap, float4 tileSource,
                        bool hasTile, bool tileNearest,
                        float backgroundLevel, float displayHeadroom,
                        float baseHeadroom, float tileHeadroom)
{
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    constexpr sampler nearestSampler(coord::normalized, address::clamp_to_edge, filter::nearest);

    if (hasTile) {
        float2 uv = tileMap * p;
        if (uv.x >= 0.0 && uv.y >= 0.0 && uv.x <= 1.0 && uv.y <= 1.0) {
            float2 st = tileSource.xy + uv * tileSource.zw;
            float4 c = tileNearest ? tile.sample(nearestSampler, st) : tile.sample(linearSampler, st);
            return toneMapToHeadroom(c.rgb, displayHeadroom, tileHeadroom);
        }
    }

    float2 uv = baseMap * p;
    if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
        // Outside the image: neutral surround. A mid-dark grey rather than
        // black — pure black next to an image biases how you judge its
        // shadows, which is why Lightroom and Capture One both use grey.
        return float3(backgroundLevel);
    }
    float4 c = base.sample(linearSampler, uv);
    return toneMapToHeadroom(c.rgb, displayHeadroom, baseHeadroom);
}

kernel void presentToScreen(
    texture2d<float, access::sample> base     [[texture(0)]],
    texture2d<float, access::sample> tile     [[texture(1)]],
    texture2d<float, access::write>  drawable [[texture(2)]],
    texture2d<float, access::sample> loupeTile [[texture(3)]],
    constant float3x2 &baseMap                [[buffer(0)]],  // screen px -> base uv
    constant float3x2 &tileMap                [[buffer(1)]],  // screen px -> tile uv (inset region)
    constant float4 &tileSource               [[buffer(2)]],  // uv origin.xy, uv size.zw
    constant uint   &hasTile                  [[buffer(3)]],
    constant float  &backgroundLevel          [[buffer(4)]],
    constant float4 &headrooms                [[buffer(5)]],  // display, base, tile, loupe tile content
    constant Loupe  &loupe                    [[buffer(6)]],
    constant uint   &flags                    [[buffer(7)]],
    uint2 gid                                 [[thread_position_in_grid]])
{
    if (gid.x >= drawable.get_width() || gid.y >= drawable.get_height()) return;

    float3 p = float3(float2(gid) + 0.5, 1.0);
    bool magnifier = (flags & kMagnifier) != 0;
    float radius = loupe.circle.z;
    float d = magnifier ? distance(p.xy, loupe.circle.xy) : 0.0;
    // Anti-aliased edges, one drawable pixel wide: the magnified picture,
    // then a light ring, then a dark hairline, then the view as usual.
    float ringWidth = loupe.circle.w;
    float inRing = smoothstep(radius - ringWidth - 1.0, radius - ringWidth, d);
    float inHairline = smoothstep(radius - 1.5, radius - 0.5, d);
    float outside = magnifier ? smoothstep(radius - 0.5, radius + 0.5, d) : 1.0;

    float3 color = float3(0.0);
    if (outside > 0.0) {
        color = composite(p, base, baseMap, tile, tileMap, tileSource,
                          hasTile != 0, (flags & kTileNearest) != 0,
                          backgroundLevel, headrooms.x, headrooms.y, headrooms.z);
    }
    if (outside < 1.0) {
        float3 inside = float3(0.8);
        if (inRing < 1.0) {
            float3 magnified = composite(p, base, loupe.baseMap, loupeTile, loupe.tileMap, loupe.tileSource,
                                         (flags & kMagnifierHasTile) != 0, (flags & kMagnifierNearest) != 0,
                                         backgroundLevel, headrooms.x, headrooms.y, headrooms.w);
            inside = mix(magnified, inside, inRing);
        }
        inside = mix(inside, float3(0.0), inHairline);
        color = mix(inside, color, outside);
    }
    drawable.write(float4(color, 1.0), gid);
}
