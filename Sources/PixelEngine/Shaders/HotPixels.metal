#include <metal_stdlib>
using namespace metal;

// Hot pixel removal (HotPixels.swift), on the raw Bayer sensor plane
// before black level, white balance and demosaic (WhiteBalance.metal):
// a stuck photosite caught here is one wrong sample; after demosaic it
// would be a coloured cross.
//
// One thread per photosite. Its eight nearest neighbours of the same
// colour sit two photosites away (on a Bayer mosaic that is true of red,
// blue and both greens), mirrored at the plane's edges. The photosite is
// replaced by their median when it stands above them by more than
// `margin` (a fraction of the range above black): above all eight in
// mode 0, or also above their median (and twice it) in mode 1. Every
// other photosite is copied unchanged, so the output is the whole plane
// and every render reads it as it would the original. Each replacement
// bumps `fixed`, which the panel shows.
//
// Helpers are prefixed (hotPixels…): the runtime fallback concatenates
// every .metal file, so names must not collide with another file's.

// Mirror of `HotPixelParamsGPU` in HotPixels.swift.
struct HotPixelParamsGPU {
    uint rawWidth;
    uint rawHeight;
    float blackLevel;
    float whiteLevel;
    float margin;
    uint mode;   // 0 stuck only, 1 also outliers
};

// A coordinate two photosites beyond the edge mirrored back inside,
// keeping its parity so it lands on the same colour.
inline int hotPixelsMirror(int v, int size) {
    if (v < 0) v = -v;
    if (v >= size) v = 2 * (size - 1) - v;
    return clamp(v, 0, size - 1);
}

kernel void hotPixelsRemove(
    device const uint16_t *sensor        [[buffer(0)]],
    device uint16_t *cleaned             [[buffer(1)]],
    constant HotPixelParamsGPU &p        [[buffer(2)]],
    device atomic_uint *fixed            [[buffer(3)]],
    uint2 gid                            [[thread_position_in_grid]])
{
    if (gid.x >= p.rawWidth || gid.y >= p.rawHeight) return;
    int w = int(p.rawWidth), h = int(p.rawHeight);
    uint index = gid.y * p.rawWidth + gid.x;
    uint16_t raw = sensor[index];
    float range = max(p.whiteLevel - p.blackLevel, 1.0);
    float v = max(float(raw) - p.blackLevel, 0.0) / range;

    // The eight same-colour neighbours, sorted (insertion sort; eight
    // values in registers).
    float n[8];
    int k = 0;
    for (int dy = -2; dy <= 2; dy += 2) {
        for (int dx = -2; dx <= 2; dx += 2) {
            if (dx == 0 && dy == 0) continue;
            int x = hotPixelsMirror(int(gid.x) + dx, w);
            int y = hotPixelsMirror(int(gid.y) + dy, h);
            n[k++] = max(float(sensor[uint(y) * p.rawWidth + uint(x)]) - p.blackLevel, 0.0) / range;
        }
    }
    for (int i = 1; i < 8; i++) {
        float key = n[i];
        int j = i - 1;
        while (j >= 0 && n[j] > key) { n[j + 1] = n[j]; j--; }
        n[j + 1] = key;
    }
    float median = 0.5 * (n[3] + n[4]);
    bool defect = v - n[7] > p.margin;
    if (p.mode == 1 && !defect) defect = v - median > p.margin && v > 2.0 * median;

    if (defect) {
        float replaced = median * range + p.blackLevel;
        cleaned[index] = uint16_t(clamp(rint(replaced), 0.0, 65535.0));
        atomic_fetch_add_explicit(fixed, 1u, memory_order_relaxed);
    } else {
        cleaned[index] = raw;
    }
}
