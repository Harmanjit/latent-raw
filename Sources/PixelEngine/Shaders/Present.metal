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
// ClippingIndicators in PixelReadout.swift, shifted up by four.
constant uint kClipShadows      = 1u << 4;
constant uint kClipHighlights   = 1u << 5;
constant uint kHDRRanges        = 1u << 6;

// The clipping overlay (J). Same lines as the histogram's end bins
// (Histogram.metal), so what turns red is what the clipped readout counts:
// a channel encoding to 255 is clipped, a pixel whose every channel
// encodes to 0 is crushed. 0.9955 is the linear value that encodes to
// 254.5/255; the top is the layer's own ceiling, which is SDR white
// unless the view is rendered with HDR headroom.
// Visualise HDR Ranges. The SDR part of the picture turns a dim grey so
// the colours read; above SDR white each stop has its own colour (blue,
// green, yellow, then orange from three stops up), and a pixel at the
// ceiling the layer was rendered to (the HDR Limit or the screen's) turns
// magenta: HDR clipping. Values are linear Display P3, 1.0 = SDR white.
inline float3 hdrRangeIndicator(float3 c, float contentHeadroom) {
    float peak = max(c.r, max(c.g, c.b));
    if (peak <= 1.0) {
        float y = dot(max(c, 0.0), float3(0.2290, 0.6917, 0.0793));
        return float3(y * 0.5);
    }
    if (contentHeadroom > 1.0 && peak >= 0.9955 * contentHeadroom) return float3(1.0, 0.0, 1.0);
    float stops = log2(peak);
    if (stops <= 1.0) return float3(0.1, 0.4, 1.0);
    if (stops <= 2.0) return float3(0.2, 0.85, 0.3);
    if (stops <= 3.0) return float3(1.0, 0.9, 0.1);
    return float3(1.0, 0.5, 0.0);
}

inline float3 clippingIndicator(float3 c, float contentHeadroom, uint flags) {
    if ((flags & kHDRRanges) != 0) return hdrRangeIndicator(c, contentHeadroom);
    float peak = max(c.r, max(c.g, c.b));
    if ((flags & kClipHighlights) != 0 && peak >= 0.9955 * contentHeadroom) return float3(1.0, 0.0, 0.0);
    if ((flags & kClipShadows) != 0 && peak < 0.000152) return float3(0.0, 0.3, 1.0);
    return c;
}

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
                        float baseHeadroom, float tileHeadroom, uint flags)
{
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    constexpr sampler nearestSampler(coord::normalized, address::clamp_to_edge, filter::nearest);

    if (hasTile) {
        float2 uv = tileMap * p;
        if (uv.x >= 0.0 && uv.y >= 0.0 && uv.x <= 1.0 && uv.y <= 1.0) {
            float2 st = tileSource.xy + uv * tileSource.zw;
            float4 c = tileNearest ? tile.sample(nearestSampler, st) : tile.sample(linearSampler, st);
            float3 shown = (flags & (kClipShadows | kClipHighlights | kHDRRanges)) != 0
                ? clippingIndicator(c.rgb, tileHeadroom, flags) : c.rgb;
            return toneMapToHeadroom(shown, displayHeadroom, tileHeadroom);
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
    float3 shown = (flags & (kClipShadows | kClipHighlights | kHDRRanges)) != 0
        ? clippingIndicator(c.rgb, baseHeadroom, flags) : c.rgb;
    return toneMapToHeadroom(shown, displayHeadroom, baseHeadroom);
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
                          backgroundLevel, headrooms.x, headrooms.y, headrooms.z, flags);
    }
    if (outside < 1.0) {
        float3 inside = float3(0.8);
        if (inRing < 1.0) {
            float3 magnified = composite(p, base, loupe.baseMap, loupeTile, loupe.tileMap, loupe.tileSource,
                                         (flags & kMagnifierHasTile) != 0, (flags & kMagnifierNearest) != 0,
                                         backgroundLevel, headrooms.x, headrooms.y, headrooms.w, flags);
            inside = mix(magnified, inside, inRing);
        }
        inside = mix(inside, float3(0.0), inHairline);
        color = mix(inside, color, outside);
    }
    drawable.write(float4(color, 1.0), gid);
}

// The Option-drag preview on a Colour Mixer (HSL) slider: everything grey
// but the colours that band moves, as Lightroom shows while Option is held.
// A display pass on the viewport's picture (linear Display P3), run after
// every stage (RenderPipeline+HueIsolation.swift). The hue is judged as
// the colour kernel's HSL bands judge it, on Rec.2020 primaries at gamma
// 2.2, so what stays coloured is what the slider acts on; each band
// shares the hues between its centre and its neighbours' as the kernel's
// `hslBandWeights` does, and greys (which the bands leave alone) go grey.
struct HueIsolationParams {
    float3x3 toWorking;   // linear Display P3 -> linear Rec.2020
    uint band;            // 0 red ... 7 magenta
};

constant float kIsolationCentres[8] = {0.0, 30.0, 60.0, 120.0, 180.0, 240.0, 270.0, 300.0};

inline float isolationBandWeight(float hue, uint band) {
    int lo = 7, hi = 0;
    float span = 360.0 - kIsolationCentres[7];
    float t = (hue >= kIsolationCentres[7]) ? (hue - kIsolationCentres[7]) / span : 0.0;
    for (int i = 0; i < 7; i++) {
        if (hue >= kIsolationCentres[i] && hue < kIsolationCentres[i + 1]) {
            lo = i; hi = i + 1;
            t = (hue - kIsolationCentres[i]) / (kIsolationCentres[i + 1] - kIsolationCentres[i]);
            break;
        }
    }
    float w = 0.0;
    if (uint(lo) == band) w += 1.0 - t;
    if (uint(hi) == band) w += t;
    return w;
}

kernel void hueIsolate(
    texture2d<float, access::read>  input   [[texture(0)]],
    texture2d<float, access::write> output  [[texture(1)]],
    constant HueIsolationParams &params     [[buffer(0)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float4 c = input.read(gid);
    float3 g = pow(max(params.toWorking * c.rgb, 0.0), 1.0 / 2.2);
    float mx = max(g.r, max(g.g, g.b)), mn = min(g.r, min(g.g, g.b));
    float d = mx - mn;
    float hue = 0.0;
    if (d > 1e-6) {
        if (mx == g.r) hue = fmod((g.g - g.b) / d, 6.0);
        else if (mx == g.g) hue = (g.b - g.r) / d + 2.0;
        else hue = (g.r - g.g) / d + 4.0;
        hue *= 60.0;
        if (hue < 0.0) hue += 360.0;
    }
    float saturation = mx > 1e-6 ? d / mx : 0.0;
    float keep = isolationBandWeight(hue, params.band) * smoothstep(0.0, 0.15, saturation);
    float y = dot(max(c.rgb, 0.0), float3(0.2290, 0.6917, 0.0793));
    output.write(float4(mix(float3(y), c.rgb, keep), c.a), gid);
}
