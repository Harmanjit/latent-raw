#include <metal_stdlib>
#include "Common.h"
using namespace metal;

// Viewport-resolution rendering (DESIGN.md §8.2).
//
// Fuses three pipeline stages into one pass: black/white level
// normalization, white balance, and demosaic-by-binning. Reads the raw
// sensor buffer directly and writes the reduced-resolution RGB result,
// so the full-resolution intermediate textures are never allocated at all.
//
// The trick: a Bayer quad already contains one red, one blue and two green
// samples. When the output is smaller than the sensor, there's no need to
// interpolate the missing colors at every photosite — just average each
// color across a block of quads. That's box-filter downsampling, which is
// the correct filter for reduction anyway, and it's strictly better than
// interpolating first and shrinking afterwards (which invents data only to
// throw it away).
//
// `binQuads` = how many 2x2 Bayer quads map to one output pixel.
//   binQuads=1 -> half-size (each quad -> one pixel)
//   binQuads=2 -> quarter-size, and so on.
// Each output pixel therefore covers (binQuads*2) x (binQuads*2) sensor
// samples, containing binQuads^2 reds, binQuads^2 blues and 2*binQuads^2
// greens.
//
// Black level is subtracted BEFORE averaging — averaging raw values and
// subtracting afterwards would be wrong at the block edges and would bias
// the result wherever the block is clipped by the sensor bounds.
kernel void demosaicBinned(
    device const uint16_t *sensor         [[buffer(0)]],
    constant uint32_t &rawWidth           [[buffer(1)]],
    constant uint32_t &rawHeight          [[buffer(2)]],
    constant float &blackLevel            [[buffer(3)]],
    constant float &whiteLevel            [[buffer(4)]],
    constant float4 &camMul                [[buffer(5)]],
    constant uint8_t &cfaPattern          [[buffer(6)]],
    constant uint32_t &binQuads           [[buffer(7)]],
    texture2d<float, access::write> rgb   [[texture(0)]],
    uint2 gid                             [[thread_position_in_grid]])
{
    if (gid.x >= rgb.get_width() || gid.y >= rgb.get_height()) return;

    uint span = binQuads * 2;
    uint x0 = gid.x * span;
    uint y0 = gid.y * span;

    float range = whiteLevel - blackLevel;
    float invRange = (range > 0.0) ? (1.0 / range) : 0.0;

    float sum[3]   = {0.0, 0.0, 0.0};
    float count[3] = {0.0, 0.0, 0.0};

    for (uint dy = 0; dy < span; dy++) {
        uint sy = y0 + dy;
        if (sy >= rawHeight) break;
        for (uint dx = 0; dx < span; dx++) {
            uint sx = x0 + dx;
            if (sx >= rawWidth) break;

            uint8_t c = cfaColorRGB(cfaPattern, sx, sy);
            float v = (float(sensor[sy * rawWidth + sx]) - blackLevel) * invRange;
            sum[c]   += max(v, 0.0);
            count[c] += 1.0;
        }
    }

    // White balance is applied after averaging: it's a per-channel scalar,
    // so scaling each sample or scaling the mean gives the same answer, and
    // doing it once per output pixel is cheaper than once per sample.
    float3 outColor;
    outColor.r = (count[0] > 0.0) ? (sum[0] / count[0]) * camMul.x : 0.0;
    outColor.g = (count[1] > 0.0) ? (sum[1] / count[1]) * camMul.y : 0.0;
    outColor.b = (count[2] > 0.0) ? (sum[2] / count[2]) * camMul.z : 0.0;

    rgb.write(float4(outColor, 1.0), gid);
}
