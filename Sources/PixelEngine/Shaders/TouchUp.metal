#include <metal_stdlib>
using namespace metal;

// Touch-up (docs/Retouch.md §7): skin smoothing, teeth whitening and
// brighter eyes over the faces' region masks, one stage on the
// display-referred image between the output transform and presence.
//
// Planned: the stage prepares perceptual luma and blurs it at a fine and
// a mid sigma with the LocalContrast passes; per pixel the skin band
// (fine - mid) is subtracted by the skin slider, the eyes brightened and
// gained, the teeth's yellow pulled back, all in linear light, and the
// overlay tints the skin mask red. Helpers are prefixed twins
// (touchUpPerceptual/ToLinear/FromLinear) of LocalContrast's file-local
// ones: make_app.sh compiles files separately while the runtime fallback
// concatenates them, so reusing or redefining the names fails one way or
// the other. Wave 1 (touch-up kernel) writes it; this Wave 0 kernel
// copies the input through so the stage can be wired and encoded.

// Mirror of `TouchUpParamsGPU` in TouchUpStage.swift.
struct TouchUpParamsGPU {
    float4 sliders;        // skin, teeth, eyes (0…1), overlay (0 or 1)
    float2 tileOrigin;     // sensor px
    float2 sensorSize;     // sensor px
    float binSpan;         // sensor px per texture px
    uint isLinear;         // 1 for the EDR viewport, 0 for an encoded file
    float headroom;
    float padding;
};

kernel void touchUpApply(
    texture2d<float, access::read>        input   [[texture(0)]],
    texture2d<float, access::write>       output  [[texture(1)]],
    texture2d_array<float, access::sample> masks  [[texture(2)]],   // skin, teeth, eyes
    constant TouchUpParamsGPU &params             [[buffer(0)]],
    uint2 gid                                     [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    output.write(input.read(gid), gid);
}
