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

kernel void computeHistogram(
    texture2d<float, access::read> image      [[texture(0)]],
    device atomic_uint *histogram             [[buffer(0)]],
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

        // The input is display-referred and already encoded, so values are
        // nominally 0..1 and map straight onto bins.
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
