#include "Common.h"

// Slideshow transitions (SlideshowRenderer in Slideshow.swift), ported from
// minivu's slideshow shader.
//
// One full-screen triangle and one fragment shader for every transition,
// chosen by a small index: a pipeline per transition would cost a
// compilation each for what is a few lines. Each slide is drawn aspect-fit
// on black inside a rectangle the CPU works out per frame
// (`SlideshowGeometry`); push and zoom move or scale those rectangles, so
// the shader only decides, per pixel, how much of the new slide shows.
// Work is proportional to screen pixels: two samples at most, and one
// wherever a pixel is wholly old or wholly new.
//
// Slides are 8-bit textures holding display-encoded Display P3 (the sRGB
// curve, as an exported file has it). They are decoded to linear light
// before mixing, so a cross-fade's midpoint is an even mix of light rather
// than a dip in brightness, and written linear to the drawable, which is
// extended linear Display P3 like the viewport's.
//
// Every name starts with `slideshow`: the runtime shader compile joins all
// the .metal files into one source.

struct SlideshowUniforms {
    float4 fromRect;   // origin.xy, size.zw, in drawable pixels, top-left origin
    float4 toRect;
    float4 info;       // has from, has to, unused, unused
    float4 params;     // eased progress, mix kind (0 fade, 1 through black, 2 push edge), 1 going backward, unused
    float4 view;       // width, height (pixels), unused, unused
};

struct SlideshowVertex {
    float4 position [[position]];
};

vertex SlideshowVertex slideshowVertex(uint vid [[vertex_id]]) {
    // A triangle that covers the viewport: (-1,-1) (3,-1) (-1,3).
    float2 p = float2((vid << 1) & 2, vid & 2);
    SlideshowVertex out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

static float3 slideshowDecode(float3 c) {
    c = clamp(c, 0.0, 1.0);
    return select(c / 12.92, pow((c + 0.055) / 1.055, 2.4), c > 0.04045);
}

// One slide, aspect-fit inside `rect`, black around it, in linear light.
static float3 slideshowSample(texture2d<float> image, float4 rect, float has, float2 p) {
    if (has < 0.5) { return float3(0.0); }
    float2 uv = (p - rect.xy) / rect.zw;
    if (any(uv < 0.0) || any(uv > 1.0)) { return float3(0.0); }
    constexpr sampler smooth(coord::normalized, address::clamp_to_edge, filter::linear);
    return slideshowDecode(image.sample(smooth, uv).rgb);
}

fragment float4 slideshowFragment(SlideshowVertex in [[stage_in]],
                                  texture2d<float> fromImage [[texture(0)]],
                                  texture2d<float> toImage [[texture(1)]],
                                  constant SlideshowUniforms &u [[buffer(0)]])
{
    float2 p = in.position.xy;
    float t = u.params.x;
    int kind = int(u.params.y + 0.5);
    float width = u.view.x;

    float w;
    switch (kind) {
        case 1: {
            // Fade through black: the old slide fades out, then the new in.
            float3 color = t < 0.5
                ? slideshowSample(fromImage, u.fromRect, u.info.x, p) * (1.0 - 2.0 * t)
                : slideshowSample(toImage, u.toRect, u.info.y, p) * (2.0 * t - 1.0);
            return float4(color, 1.0);
        }
        case 2: {
            // Push: both slides move (the rectangles say so); the new one's
            // screen starts at its leading edge. Half a pixel either side of
            // the edge, for a clean line. Going forward the new slide comes
            // from the right, going backward from the left.
            float along = u.params.z > 0.5 ? width - p.x : p.x;
            float edge = (1.0 - t) * width;
            w = smoothstep(edge - 0.5, edge + 0.5, along);
            break;
        }
        default:
            // Cross-fade, and zoom, whose rectangles grow and settle.
            w = t;
            break;
    }

    if (w <= 0.0) { return float4(slideshowSample(fromImage, u.fromRect, u.info.x, p), 1.0); }
    if (w >= 1.0) { return float4(slideshowSample(toImage, u.toRect, u.info.y, p), 1.0); }
    float3 a = slideshowSample(fromImage, u.fromRect, u.info.x, p);
    float3 b = slideshowSample(toImage, u.toRect, u.info.y, p);
    return float4(mix(a, b, w), 1.0);
}
