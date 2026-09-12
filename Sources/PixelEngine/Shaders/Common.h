#include <metal_stdlib>
using namespace metal;

// Packed 2x2 Bayer order, matching LibRaw's `filters` low byte
// (see CLibRawSummary.cfa_pattern / RawFile.CFAPattern).
//
// LibRaw's encoding uses FOUR values, not three: 0=R, 1=G, 2=B, 3=G2
// (the second green of the quad). Callers that index 3-element RGB
// arrays must collapse 3 -> 1 first, or they write out of bounds on
// every green-2 photosite — a quarter of the sensor. Use cfaColorRGB()
// for that; use cfaColorAt() only when you genuinely need to tell the
// two greens apart (some demosaic algorithms do).
inline uint8_t cfaColorAt(uint8_t pattern, uint x, uint y) {
    uint idx = ((y & 1) << 1) | (x & 1);
    return (pattern >> (idx * 2)) & 0x3;
}

// Same, but with the second green collapsed onto green, so the result is
// always a safe index into a 3-element RGB array.
inline uint8_t cfaColorRGB(uint8_t pattern, uint x, uint y) {
    uint8_t c = cfaColorAt(pattern, x, y);
    return (c == 3) ? 1 : c;
}
