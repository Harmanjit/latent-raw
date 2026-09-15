#include <metal_stdlib>
using namespace metal;

// Photo Merge kernels (see docs/PhotoMerge.md). Empty until Phase 6 fills it;
// registered in GPUContext.kernelNames up front so parallel work on the
// alignment and deghosting kernels never edits the same line.
