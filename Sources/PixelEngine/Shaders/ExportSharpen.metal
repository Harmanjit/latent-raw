#include <metal_stdlib>
using namespace metal;

// Output sharpening: the last step of an export before its pixels are
// quantised, after the resize, so it is tuned to the file's own pixel
// grid rather than the sensor's. ExportOutputSharpening.swift explains
// the settings and holds a CPU copy of this filter for the tests.
//
// An unsharp mask on luminance only: the detail is the pixel's luma minus
// a Gaussian blur of the luma around it, and that difference is added to
// all three channels equally. Sharpening R, G and B separately would
// sharpen colour noise and fringe saturated edges. Working on the encoded
// values (perceptual, not linear) keeps the halo on a dark edge as visible
// as on a bright one. Differences smaller than `threshold` are left alone
// so flat skies and gradients don't turn gritty.

// Mirror of OutputSharpenUniforms in ExportOutputSharpening.swift.
struct OutputSharpenUniforms {
    float sigma;      // Gaussian radius, output pixels
    float amount;     // how much of the detail is added back
    float threshold;  // detail below this (encoded 0...1) is ignored
    int   radius;     // taps either side
};

inline float outputSharpenLuma(float3 c) {
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

kernel void exportOutputSharpen(
    texture2d<float, access::read>  source [[texture(0)]],
    texture2d<float, access::write> dest   [[texture(1)]],
    constant OutputSharpenUniforms &u      [[buffer(0)]],
    uint2 gid                              [[thread_position_in_grid]])
{
    uint w = dest.get_width(), h = dest.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float3 c = source.read(gid).rgb;
    float sum = 0.0, weights = 0.0;
    float k = -0.5 / (u.sigma * u.sigma);
    for (int dy = -u.radius; dy <= u.radius; dy++) {
        int y = clamp(int(gid.y) + dy, 0, int(h) - 1);
        for (int dx = -u.radius; dx <= u.radius; dx++) {
            int x = clamp(int(gid.x) + dx, 0, int(w) - 1);
            float weight = exp(float(dx * dx + dy * dy) * k);
            sum += weight * outputSharpenLuma(source.read(uint2(x, y)).rgb);
            weights += weight;
        }
    }
    float detail = outputSharpenLuma(c) - sum / weights;
    // Soft threshold: shrink every difference by the threshold, so the
    // step from "left alone" to "sharpened" has no visible edge.
    detail = sign(detail) * max(abs(detail) - u.threshold, 0.0);
    dest.write(float4(clamp(c + u.amount * detail, 0.0, 1.0), 1.0), gid);
}
