#include <metal_stdlib>
using namespace metal;

// Visualise Spots (docs/Retouch.md §6): a high-pass view of the display
// texture, viewport only, that makes faint dust shadows stand out so the
// user can judge Find Spots and click the ones it missed.
//
// A dust spot is a soft dark disc of roughly the band's radius, so the
// view is the difference of two box means of log2 luminance: a small one
// the size of the spot and a wide one three times that. Both are 9 x 9
// taps, spaced apart by up to a quarter and three quarters of sigma, so a
// spot of any radius costs the same 162 reads per pixel, needs no scratch
// texture, and looks the same at every bin factor (sigma is in texture
// pixels: the sensor radius over binSpan). Where the inner mean falls
// below the outer, the pixel darkens: white where nothing is there,
// black at a clear dip, with the Contrast slider setting how faint a dip
// still shows through the threshold t.

// Mirror of `DustVisualiseGPU` in RenderPipeline.swift.
struct DustVisualiseParams {
    float threshold;        // 0…1, the Contrast slider
    float radiusSensorPx;   // the band's radius
    float binSpan;          // sensor px per texture px
    float padding;
};

// log2 of the pixel's luminance, floored so black stays finite. The
// display texture is encoded or linear depending on the destination; a
// difference of logs is a ratio either way, which is all the view needs.
static inline float dustLogLuminance(texture2d<float, access::read> tex, int2 p, int2 limit)
{
    float4 c = tex.read(uint2(clamp(p, int2(0), limit)));
    float l = 0.25 * c.r + 0.5 * c.g + 0.25 * c.b;
    return log2(max(l, 1e-4));
}

// The mean of a 9 x 9 grid of taps `step` pixels apart around `centre`,
// reads clamped to the texture as the other stages clamp theirs.
static inline float dustBoxMean(texture2d<float, access::read> tex, int2 centre, int step, int2 limit)
{
    float sum = 0;
    for (int j = -4; j <= 4; j++) {
        for (int i = -4; i <= 4; i++) {
            sum += dustLogLuminance(tex, centre + int2(i, j) * step, limit);
        }
    }
    return sum / 81.0;
}

kernel void dustVisualise(
    texture2d<float, access::read>  input   [[texture(0)]],
    texture2d<float, access::write> output  [[texture(1)]],
    constant DustVisualiseParams &params    [[buffer(0)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    int2 limit = int2(input.get_width() - 1, input.get_height() - 1);
    int2 p = int2(gid);

    float sigma = max(0.7, params.radiusSensorPx / max(params.binSpan, 1.0));
    int innerStep = max(1, int(round(sigma / 4.0)));
    int outerStep = max(1, int(round(3.0 * sigma / 4.0)));
    float inner = dustBoxMean(input, p, innerStep, limit);
    float outer = dustBoxMean(input, p, outerStep, limit);
    // Positive where the neighbourhood is darker than its surroundings.
    float hp = outer - inner;

    float faint = 1.0 - clamp(params.threshold, 0.0, 1.0);
    float t = 0.005 + 0.15 * faint * faint;
    float out = 1.0 - smoothstep(t, 3.0 * t, hp);
    output.write(float4(out, out, out, 1.0), gid);
}
