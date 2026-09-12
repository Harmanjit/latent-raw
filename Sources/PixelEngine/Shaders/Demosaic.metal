#include <metal_stdlib>
#include "Common.h"
using namespace metal;

// Correctness baseline only (DESIGN.md §13, task 3): simple bilinear
// interpolation of the missing two channels at every pixel. This exists to
// have *something* end-to-end working and colour-checkable before porting
// RawTherapee's RCD kernel, which is the real v1 demosaicer (DESIGN.md §8.1).
// Do not tune this for quality — replace it.
//
// Used only for full-resolution renders now; reduced-resolution viewport
// rendering goes through demosaicBinned instead (DESIGN.md §8.2).
kernel void demosaicBilinear(
    texture2d<float, access::read> cfa   [[texture(0)]],
    constant uint8_t &cfaPattern         [[buffer(0)]],
    texture2d<float, access::write> rgb  [[texture(1)]],
    uint2 gid                            [[thread_position_in_grid]])
{
    uint w = cfa.get_width(), h = cfa.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float sum[3] = {0, 0, 0};
    float count[3] = {0, 0, 0};

    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int sx = int(gid.x) + dx, sy = int(gid.y) + dy;
            if (sx < 0 || sy < 0 || sx >= int(w) || sy >= int(h)) continue;
            // cfaColorRGB, not cfaColorAt: LibRaw encodes the second green
            // as 3, which would index past the end of these 3-element arrays.
            uint8_t c = cfaColorRGB(cfaPattern, uint(sx), uint(sy));
            float v = cfa.read(uint2(sx, sy)).r;
            sum[c] += v;
            count[c] += 1.0;
        }
    }

    float3 out;
    out.r = count[0] > 0 ? sum[0] / count[0] : 0;
    out.g = count[1] > 0 ? sum[1] / count[1] : 0;
    out.b = count[2] > 0 ? sum[2] / count[2] : 0;

    // The centre pixel's own native colour is exact, not interpolated.
    uint8_t centerColor = cfaColorRGB(cfaPattern, gid.x, gid.y);
    float centerVal = cfa.read(gid).r;
    out[centerColor] = centerVal;

    rgb.write(float4(out, 1.0), gid);
}
