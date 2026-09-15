#include <metal_stdlib>
using namespace metal;

// Photo Merge panorama kernels (see docs/PhotoMerge.md section 4). Empty until
// Phase 8 fills it; registered in GPUContext.kernelNames up front so parallel
// work on the geometry and the stitcher never edits the same line.
