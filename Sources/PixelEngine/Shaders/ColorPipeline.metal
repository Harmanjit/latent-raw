#include <metal_stdlib>
using namespace metal;

// Pipeline stages 2, 5, 6, 9 and 13 (DESIGN.md §8.1), fused into one pass:
// highlight reconstruction -> camera matrix -> exposure -> tone mapping ->
// output transform.
//
// Fusing them matters because each is only a handful of arithmetic ops per
// pixel. Running them as separate kernels would mean several round trips
// through memory for the same data, and this pipeline is bandwidth-bound
// rather than compute-bound. The arithmetic is nearly free; moving the
// pixels is not.
//
// Input is white-balanced camera RGB, scene-linear.
// Output is display-referred, encoded, ready for the screen or a PNG.

/// Pulls clipped highlights back toward neutral.
///
/// The sensor saturates at a single value for every photosite, but white
/// balance then scales each channel differently (on a D750 in daylight,
/// R x2.01, G x1.00, B x1.32). So a pixel where all three channels truly
/// clipped arrives here as (2.01, 1.00, 1.32) — which reads as magenta.
/// That cast is an artifact of the white balance step, not anything the
/// scene contained.
///
/// `clipLevel` is where each channel saturates *after* white balance, which
/// is exactly the white balance multiplier (raw values are normalized so
/// sensor maximum is 1.0 before scaling).
///
/// The reconstruction pulls each channel toward the brightest channel
/// present, which neutralizes the cast: (2.01, 1.00, 1.32) becomes roughly
/// (2.01, 2.01, 2.01), and tone mapping then renders that as clean near-
/// white. `threshold` sets how far below the clip point the blend begins,
/// so the transition into reconstructed territory is gradual rather than a
/// visible edge.
///
/// Limitation worth being clear about: this recovers *colour*, not detail.
/// Structure inside a blown region is genuinely gone from the file. Methods
/// that appear to recover texture (darktable's inpainting, for instance)
/// infer it from surrounding unclipped pixels — a far more involved
/// approach, and a candidate for later.
inline float3 reconstructHighlights(float3 rgb, float3 clipLevel,
                                     float threshold, float strength) {
    float3 blendStart = clipLevel * threshold;
    float3 blendRange = max(clipLevel - blendStart, float3(1e-6));

    // 0 where a channel is comfortably below clipping, 1 at or past it.
    float3 t = saturate((rgb - blendStart) / blendRange);

    float brightest = max(rgb.r, max(rgb.g, rgb.b));
    float3 neutralized = mix(rgb, float3(brightest), t);

    return mix(rgb, neutralized, strength);
}

/// Naka-Rushton sigmoid with a ceiling: y = H * x^c / (x^c + k'^c).
///
/// Maps unbounded scene-linear values onto [0, H) without ever clipping.
/// `headroom` (H) is how bright the display can go relative to paper
/// white: 1.0 for an ordinary SDR screen, around 2 for a MacBook Pro XDR
/// at normal brightness. Middle grey always lands on exactly 0.5 whatever
/// H is — k' is solved so that y(k) = 0.5 — so raising the ceiling only
/// stretches the highlights upward; it never brightens the whole image.
///
/// With H = 1 this is the plain sigmoid, which is what export uses.
inline float3 toneMapSigmoid(float3 x, float contrast, float greyPoint, float headroom) {
    float3 xc = pow(max(x, 0.0), contrast);
    float kc = pow(max(greyPoint, 1e-6), contrast);
    // y(k) = H * k^c / (k^c + k'^c) = 0.5  =>  k'^c = k^c * (2H - 1)
    float kPrime = kc * max(2.0 * headroom - 1.0, 1e-6);
    return headroom * xc / (xc + kPrime);
}

/// sRGB opto-electronic transfer function (the "gamma" encoding).
///
/// Not a plain power curve: sRGB has a short linear segment near black to
/// avoid the infinite slope a pure power function has at zero. Using
/// pow(x, 1/2.2) instead is a common shortcut that visibly lifts and
/// muddies deep shadows.
inline float3 encodeSRGB(float3 c) {
    c = clamp(c, 0.0, 1.0);
    float3 low  = c * 12.92;
    float3 high = 1.055 * pow(c, 1.0 / 2.4) - 0.055;
    return select(low, high, c > 0.0031308);
}

kernel void colorAndTone(
    texture2d<float, access::read>  input        [[texture(0)]],
    texture2d<float, access::write> output       [[texture(1)]],
    constant float3x3 &cameraToWorking           [[buffer(0)]],
    constant float3x3 &workingToOutput           [[buffer(1)]],
    constant float &exposureScale                [[buffer(2)]],
    constant float &contrast                     [[buffer(3)]],
    constant float &greyPoint                    [[buffer(4)]],
    constant float3 &clipLevel                   [[buffer(5)]],
    constant float &highlightThreshold           [[buffer(6)]],
    constant float &highlightStrength            [[buffer(7)]],
    constant float &headroom                     [[buffer(8)]],
    constant uint  &encodeOutput                 [[buffer(9)]],
    constant uint  &applyToneMap                 [[buffer(10)]],
    uint2 gid                                    [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;

    float3 camera = input.read(gid).rgb;

    // Stage 2: highlight reconstruction, before the camera matrix — the
    // clip levels are only meaningful in camera space.
    if (highlightStrength > 0.0) {
        camera = reconstructHighlights(camera, clipLevel,
                                        highlightThreshold, highlightStrength);
    }

    // Stage 5: camera response -> linear Rec.2020 working space.
    float3 working = cameraToWorking * camera;

    // Stage 6: exposure, in linear light (the only place it's meaningful).
    working *= exposureScale;

    // Stage 9: scene-referred -> display-referred, up to the headroom.
    // Analysis renders skip this to get scene-linear numbers out.
    float3 display = (applyToneMap != 0)
        ? toneMapSigmoid(working, contrast, greyPoint, headroom)
        : working;

    // Stage 13: working space -> output space, then encode — or not.
    // Files want the sRGB curve applied and values clamped to [0,1].
    // An EDR screen buffer wants linear light, above 1.0 where the scene
    // was, and the compositor handles the rest.
    float3 outputLinear = workingToOutput * display;
    float3 result = (encodeOutput != 0) ? encodeSRGB(outputLinear) : max(outputLinear, 0.0);

    output.write(float4(result, 1.0), gid);
}
