#include <metal_stdlib>
using namespace metal;

// Visualise Spots (docs/Retouch.md §6): a high-pass view of the display
// texture, viewport only, that makes faint dust shadows stand out so the
// user can judge Find Spots and click the ones it missed.
//
// Planned: log2 luminance of the display texture; sigma = max(0.7,
// radiusSensorPx / binSpan); inner mean = 9x9 taps spaced max(1,
// round(sigma / 4)), outer mean = 9x9 taps spaced max(1, round(3 sigma /
// 4)); hp = outer - inner; t = 0.005 + 0.15 (1 - threshold)^2; out = 1 -
// smoothstep(t, 3t, hp). Wave 1 (pipeline) writes it; this Wave 0 kernel
// copies the input through so the stage can be wired and encoded.

// Mirror of `DustVisualiseGPU` in RenderPipeline.swift.
struct DustVisualiseParams {
    float threshold;        // 0…1, the Contrast slider
    float radiusSensorPx;   // the band's radius
    float binSpan;          // sensor px per texture px
    float padding;
};

kernel void dustVisualise(
    texture2d<float, access::read>  input   [[texture(0)]],
    texture2d<float, access::write> output  [[texture(1)]],
    constant DustVisualiseParams &params    [[buffer(0)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    output.write(input.read(gid), gid);
}
