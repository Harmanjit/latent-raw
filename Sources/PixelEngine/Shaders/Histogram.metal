#include <metal_stdlib>
using namespace metal;

// GPU histogram (DESIGN.md §8.3).
//
// The naive approach — every thread atomically incrementing one of 768
// global counters — would serialize millions of threads onto a handful of
// memory locations and stall badly. Instead each threadgroup builds a
// private histogram in on-chip threadgroup memory, where atomics are far
// cheaper, and only merges into the global histogram once at the end. That
// turns millions of global atomic operations into a few thousand.
//
// Layout: 3 channels x 256 bins, packed as channel * 256 + bin.
//   red   0..255
//   green 256..511
//   blue  512..767

constant uint kBinCount = 256;
constant uint kTotalBins = 768;   // 3 channels x 256

/// sRGB curve, duplicated from ColorPipeline.metal because runtime
/// compilation concatenates the kernel sources and can't share inline
/// functions across them without a header. Keep the two in step.
inline float3 histogramEncodeSRGB(float3 c) {
    c = clamp(c, 0.0, 1.0);
    float3 low  = c * 12.92;
    float3 high = 1.055 * pow(c, 1.0 / 2.4) - 0.055;
    return select(low, high, c > 0.0031308);
}

kernel void computeHistogram(
    texture2d<float, access::read> image      [[texture(0)]],
    device atomic_uint *histogram             [[buffer(0)]],
    constant uint &inputIsLinear              [[buffer(1)]],
    uint2 gid                                 [[thread_position_in_grid]],
    uint tindex                               [[thread_index_in_threadgroup]],
    uint2 threadsPerGroup                     [[threads_per_threadgroup]])
{
    threadgroup atomic_uint local[kTotalBins];

    uint stride = threadsPerGroup.x * threadsPerGroup.y;

    // Zero the threadgroup histogram. Threads cooperate so this works for
    // any threadgroup size, including ones smaller than the bin count.
    for (uint i = tindex; i < kTotalBins; i += stride) {
        atomic_store_explicit(&local[i], 0u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Accumulate this thread's pixel. Threads outside the image still take
    // part in the barriers above and below — skipping the barrier for
    // out-of-bounds threads would deadlock the threadgroup.
    if (gid.x < image.get_width() && gid.y < image.get_height()) {
        float3 color = image.read(gid).rgb;

        // The histogram always shows the encoded, SDR view of the image —
        // the shape photographers know. When the texture is linear EDR
        // (the on-screen preview), encode it here first; anything above
        // 1.0 clamps into the top bin, which is exactly "would clip in
        // SDR" and what the clipping readout should report.
        if (inputIsLinear != 0) {
            color = histogramEncodeSRGB(color);
        }
        uint r = uint(clamp(color.r, 0.0, 1.0) * float(kBinCount - 1) + 0.5);
        uint g = uint(clamp(color.g, 0.0, 1.0) * float(kBinCount - 1) + 0.5);
        uint b = uint(clamp(color.b, 0.0, 1.0) * float(kBinCount - 1) + 0.5);

        atomic_fetch_add_explicit(&local[r], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&local[kBinCount + g], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&local[2 * kBinCount + b], 1u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Merge into the global histogram. Empty bins are skipped, which is
    // most of them for a typical image.
    for (uint i = tindex; i < kTotalBins; i += stride) {
        uint count = atomic_load_explicit(&local[i], memory_order_relaxed);
        if (count > 0) {
            atomic_fetch_add_explicit(&histogram[i], count, memory_order_relaxed);
        }
    }
}
