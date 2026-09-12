#include <metal_stdlib>
using namespace metal;

// Waveform and vectorscope (DESIGN.md §8.3).
//
// Both are built from the small "analysis" render the app keeps for
// scopes — a few hundred thousand pixels — so plain global atomics are
// fast enough and there's no need for the threadgroup staging the
// histogram uses. (The waveform's 196K bins wouldn't fit in threadgroup
// memory anyway.)
//
// The input may be linear EDR (the viewport's output); both scopes
// encode it with the sRGB curve first so they show the same encoded
// view the histogram does, with anything above 1.0 landing on the top
// line — i.e. "would clip in SDR".

/// sRGB curve. Deliberately its own copy: kernel sources are compiled
/// as one concatenated unit at runtime, so every file needs a unique
/// function name, and a shared header isn't available in that mode.
inline float3 scopeEncodeSRGB(float3 c) {
    c = clamp(c, 0.0, 1.0);
    float3 low  = c * 12.92;
    float3 high = 1.055 * pow(c, 1.0 / 2.4) - 0.055;
    return select(low, high, c > 0.0031308);
}

constant uint kWaveformColumns = 256;
constant uint kWaveformRows = 256;

/// Brightness against horizontal position, one plane per channel.
/// Layout: channel * (rows*columns) + row * columns + column, with row 0
/// the darkest. Each image column maps onto one of 256 scope columns.
kernel void computeWaveform(
    texture2d<float, access::read> image      [[texture(0)]],
    device atomic_uint *bins                  [[buffer(0)]],
    constant uint &inputIsLinear              [[buffer(1)]],
    uint2 gid                                 [[thread_position_in_grid]])
{
    uint w = image.get_width(), h = image.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float3 c = image.read(gid).rgb;
    if (inputIsLinear != 0) c = scopeEncodeSRGB(c);

    uint column = min(gid.x * kWaveformColumns / w, kWaveformColumns - 1);
    uint3 row = uint3(clamp(c, 0.0, 1.0) * float(kWaveformRows - 1) + 0.5);

    uint plane = kWaveformRows * kWaveformColumns;
    atomic_fetch_add_explicit(&bins[0 * plane + row.r * kWaveformColumns + column], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[1 * plane + row.g * kWaveformColumns + column], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[2 * plane + row.b * kWaveformColumns + column], 1u, memory_order_relaxed);
}

constant uint kVectorscopeSize = 128;

/// Chroma only: Rec.709 Cb along x, Cr along y (up), brightness ignored.
/// Neutral colours land in the centre; saturation is distance from it.
kernel void computeVectorscope(
    texture2d<float, access::read> image      [[texture(0)]],
    device atomic_uint *bins                  [[buffer(0)]],
    constant uint &inputIsLinear              [[buffer(1)]],
    uint2 gid                                 [[thread_position_in_grid]])
{
    uint w = image.get_width(), h = image.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float3 c = image.read(gid).rgb;
    if (inputIsLinear != 0) c = scopeEncodeSRGB(c);

    // Rec.709 luma and the chroma differences scaled into [-0.5, 0.5].
    float y  = dot(c, float3(0.2126, 0.7152, 0.0722));
    float cb = (c.b - y) / 1.8556;
    float cr = (c.r - y) / 1.5748;

    float last = float(kVectorscopeSize - 1);
    uint bx = uint(clamp((cb + 0.5) * last + 0.5, 0.0, last));
    uint by = uint(clamp((0.5 - cr) * last + 0.5, 0.0, last));   // Cr increases upward

    atomic_fetch_add_explicit(&bins[by * kVectorscopeSize + bx], 1u, memory_order_relaxed);
}
