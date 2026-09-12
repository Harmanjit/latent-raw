#include <metal_stdlib>
#include "Common.h"
using namespace metal;

// Stage 1+3 of the pipeline (DESIGN.md §8.1), fused into one kernel per the
// efficiency rule of minimizing memory round-trips (§3, Dynamic Caching note).
// Reads the raw uint16 sensor plane, applies black/white level normalization
// and the as-shot (or user) white balance multipliers, writes linear-ish
// float16 CFA data ready for demosaicing.
//
// `sensor` is the shared-storage buffer from GPUContext.makeSharedBuffer.
// `output` is a private-storage r16float texture (still one sample per
// pixel — this stage runs *before* demosaic fills in the other two channels).
kernel void blackLevelAndWhiteBalance(
    device const uint16_t *sensor       [[buffer(0)]],
    constant uint32_t &rawWidth         [[buffer(1)]],
    constant float &blackLevel          [[buffer(2)]],
    constant float &whiteLevel          [[buffer(3)]],
    constant float4 &camMul             [[buffer(4)]],
    constant uint8_t &cfaPattern        [[buffer(5)]],
    texture2d<float, access::write> output [[texture(0)]],
    uint2 gid                           [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;

    uint16_t raw = sensor[gid.y * rawWidth + gid.x];
    float normalized = (float(raw) - blackLevel) / (whiteLevel - blackLevel);
    normalized = max(normalized, 0.0);

    uint8_t color = cfaColorAt(cfaPattern, gid.x, gid.y);
    float mul = (color == 0) ? camMul.x : (color == 1) ? camMul.y
              : (color == 2) ? camMul.z : camMul.y; // second green shares G's multiplier

    output.write(float4(normalized * mul, 0, 0, 1), gid);
}
