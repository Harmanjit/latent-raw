#include <metal_stdlib>
using namespace metal;

// The entry to the pipeline for a linear source: a DNG whose pixels are
// already demosaiced camera RGB (a Photo Merge result, or a LinearRaw DNG
// from another converter). These two kernels stand in for the Bayer
// path's first stages and hand the rest of the pipeline exactly what
// those stages hand it (RenderPipeline.renderStages, "the camera-RGB
// seam"): an rgba16Float texture of camera RGB, black subtracted,
// scaled so white is 1.0, then multiplied by the white balance.
//
// The plane (`LinearPlane` in RawCore) is already black-subtracted,
// scaled and cleaned of NaN and negative values; it is four half floats
// per pixel, RGBA, row by row. What's left here is the white balance, and
// `gain`: the file's BaselineExposure as a factor, folded into `camMul`
// by the caller so a merge opens looking like its reference frame.
//
// `plane` is a shared-storage buffer wrapping the plane's IOSurface
// (GPUContext.makeSharedBuffer), not a texture, for the same reason as
// the Bayer sensor buffer: it is used in place, never copied.

// Full resolution: one output pixel per plane pixel. `origin` offsets the
// read, so a 100% zoom tile reads only the pixels it shows. Unlike the
// Bayer path it needn't be even (there is no mosaic parity to keep), but
// RenderPipeline.plan snaps it anyway, which keeps tiles in the same place
// for both kinds of source.
kernel void linearUpload(
    device const half *plane            [[buffer(0)]],
    constant uint32_t &planeWidth       [[buffer(1)]],
    constant float4 &camMul             [[buffer(2)]],
    constant uint2 &origin              [[buffer(3)]],
    texture2d<float, access::write> rgb [[texture(0)]],
    uint2 gid                           [[thread_position_in_grid]])
{
    if (gid.x >= rgb.get_width() || gid.y >= rgb.get_height()) return;

    uint index = ((gid.y + origin.y) * planeWidth + gid.x + origin.x) * 4;
    float3 camera = float3(plane[index], plane[index + 1], plane[index + 2]);
    rgb.write(float4(camera * camMul.rgb, 1.0), gid);
}

// Reduced resolution, for previews and small exports: each output pixel
// is the plain average of a `span` x `span` block of plane pixels (a box
// filter, the right filter for shrinking, as in DemosaicBinned.metal).
// Blocks that would run past the right or bottom edge are cut short and
// averaged over what they cover; the pipeline sizes the output with
// integer division, so in practice every block is whole.
//
// Any span works, not only powers of two, because RenderPipeline.plan
// can choose any number of quads (span = 2 x quads). White balance is
// applied once to the average: scaling the mean or every sample gives
// the same result.
kernel void linearBinned(
    device const half *plane            [[buffer(0)]],
    constant uint32_t &planeWidth       [[buffer(1)]],
    constant uint32_t &planeHeight      [[buffer(2)]],
    constant float4 &camMul             [[buffer(3)]],
    constant uint32_t &span             [[buffer(4)]],
    texture2d<float, access::write> rgb [[texture(0)]],
    uint2 gid                           [[thread_position_in_grid]])
{
    if (gid.x >= rgb.get_width() || gid.y >= rgb.get_height()) return;

    uint x0 = gid.x * span, y0 = gid.y * span;
    uint x1 = min(x0 + span, planeWidth), y1 = min(y0 + span, planeHeight);

    // Summed in 32-bit float: a block of up to a few thousand half-float
    // samples would overflow half precision long before it lost accuracy.
    float3 sum = float3(0.0);
    for (uint y = y0; y < y1; y++) {
        uint row = y * planeWidth;
        for (uint x = x0; x < x1; x++) {
            uint index = (row + x) * 4;
            sum += float3(plane[index], plane[index + 1], plane[index + 2]);
        }
    }
    float count = float((x1 - x0) * (y1 - y0));
    float3 mean = count > 0.0 ? sum / count : float3(0.0);
    rgb.write(float4(mean * camMul.rgb, 1.0), gid);
}
