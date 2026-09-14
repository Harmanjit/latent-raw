#include <metal_stdlib>
using namespace metal;

// Packs a rendered (display-encoded) texture into the final export
// pixels in one pass: crop, straighten, rotation and the last resize are
// all folded into one affine map from destination coordinates to source
// texture coordinates, and the write converts to 8- or 16-bit unorm
// because that's the destination texture's format. This replaces
// per-pixel CPU loops that took seconds for a 24 MP frame.
//
// `map` takes a normalized destination point (0...1 across the output)
// to a normalized source coordinate — the same inverse-mapping idea as
// the lens and present kernels. It's built on the CPU by CropFrame.
kernel void packForExport(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::write>  dest   [[texture(1)]],
    constant float3x2 &map                  [[buffer(0)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    if (gid.x >= dest.get_width() || gid.y >= dest.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

    float2 p = (float2(gid) + 0.5) / float2(dest.get_width(), dest.get_height());
    float2 uv = map * float3(p, 1.0);
    float4 c = source.sample(s, uv);
    dest.write(float4(clamp(c.rgb, 0.0, 1.0), 1.0), gid);
}

// ---------------------------------------------------------------------
// Resized exports: a proper resampling filter, in linear light.
//
// Sampling the render at the output size (what packForExport does) is a
// single bilinear tap per output pixel. When shrinking, that reads only
// the texels nearest each output pixel and skips the rest, so fine
// detail aliases into moire and jagged edges. Here a resize runs as three
// passes instead: the crop/straighten/rotation map at the render's own
// scale into a float intermediate (decoding to linear light on the way),
// then a Lanczos 3 filter along rows, then along columns, stretched by the
// reduction so every texel contributes. Filtering happens in linear light
// because averaging encoded values darkens fine bright detail (a one-pixel
// black and white checkerboard would come out 0.5 encoded, about 21%
// linear, instead of 50%). ExportResampler.swift mirrors the filter for
// CPU reference tests.

// The sRGB curve the colour stage applies to files, and its inverse.
// Named apart from ColorPipeline.metal's encodeSRGB because the runtime
// shader compile concatenates every file into one source.
inline float3 exportEncodeSRGB(float3 c) {
    c = clamp(c, 0.0, 1.0);
    return select(c * 12.92, 1.055 * pow(c, 1.0 / 2.4) - 0.055, c > 0.0031308);
}

inline float3 exportDecodeSRGB(float3 c) {
    c = clamp(c, 0.0, 1.0);
    return select(c / 12.92, pow((c + 0.055) / 1.055, 2.4), c > 0.04045);
}

inline float exportSinc(float x) {
    if (abs(x) < 1e-6) return 1.0;
    float px = M_PI_F * x;
    return sin(px) / px;
}

// Lanczos 3: a sinc windowed by a wider sinc, zero beyond three units.
// Sharp, with small negative lobes; a common choice for shrinking photos
// because it keeps detail without the softness of a cubic.
inline float exportLanczos3(float x) {
    return abs(x) < 3.0 ? exportSinc(x) * exportSinc(x / 3.0) : 0.0;
}

// Pass 1: the same map and bilinear sample as packForExport, at the
// render's own scale, into a half-float intermediate. `decode` is 1 for a
// display-encoded render, 0 for one that is already linear (the HDR
// render of a gain-map export).
//
// Intermediates are written as half4, not float4: a float4 written to a
// half-float texture is truncated towards zero rather than rounded
// (measured: 0.99999994 stored as 0.99951), which would bias every
// resized export a hair darker.
kernel void exportSampleLinear(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<half, access::write>   dest   [[texture(1)]],
    constant float3x2 &map                  [[buffer(0)]],
    constant uint &decode                   [[buffer(1)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    if (gid.x >= dest.get_width() || gid.y >= dest.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

    float2 p = (float2(gid) + 0.5) / float2(dest.get_width(), dest.get_height());
    float3 c = source.sample(s, map * float3(p, 1.0)).rgb;
    dest.write(half4(float4(decode != 0 ? exportDecodeSRGB(c) : max(c, 0.0), 1.0)), gid);
}

// Mirror of ExportResampleUniforms in ExportResampler.swift.
struct ExportResampleUniforms {
    float scale;        // output pixels per input pixel along the axis
    float filterScale;  // the scale the filter is evaluated at (<= scale)
    uint  encode;       // columns only: 1 applies the sRGB curve and clamps
    uint  unused;
};

// One axis of the separable filter. For the output pixel at `position`
// along the axis, find the input position its centre maps to, read every
// input pixel the stretched filter reaches (edge pixels repeat past the
// border) and take the weighted average. Weights are divided by their sum
// so a flat area stays exactly flat whatever the phase of the grid.
// Negative lobes can push a value below zero or above one; that is kept
// between the passes and only clamped by the final encode.
inline float3 exportFilterAxis(texture2d<float, access::read> source, uint position, uint across,
                               bool vertical, constant ExportResampleUniforms &u)
{
    int length = int(vertical ? source.get_height() : source.get_width());
    float centre = (float(position) + 0.5) / u.scale;
    float radius = 3.0 / u.filterScale;
    int first = int(floor(centre - radius));
    int last = int(ceil(centre + radius));

    float3 sum = float3(0.0);
    float weights = 0.0;
    for (int i = first; i <= last; i++) {
        float w = exportLanczos3((float(i) + 0.5 - centre) * u.filterScale);
        if (w == 0.0) continue;
        uint index = uint(clamp(i, 0, length - 1));
        sum += source.read(vertical ? uint2(across, index) : uint2(index, across)).rgb * w;
        weights += w;
    }
    // The tap nearest the centre always has a large positive weight, so
    // the sum can't be zero; guarded anyway, since a NaN would spread.
    return abs(weights) > 1e-6 ? sum / weights : float3(0.0);
}

// Pass 2: rows, into a half-float intermediate (rounded, as pass 1).
kernel void exportResampleRows(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<half, access::write> dest   [[texture(1)]],
    constant ExportResampleUniforms &u    [[buffer(0)]],
    uint2 gid                             [[thread_position_in_grid]])
{
    if (gid.x >= dest.get_width() || gid.y >= dest.get_height()) return;
    dest.write(half4(float4(exportFilterAxis(source, gid.x, gid.y, false, u), 1.0)), gid);
}

// Pass 3: columns, into the destination: 8- or 16-bit file pixels
// (encoded), or linear float for a gain map's inputs.
kernel void exportResampleColumns(
    texture2d<float, access::read>  source [[texture(0)]],
    texture2d<float, access::write> dest   [[texture(1)]],
    constant ExportResampleUniforms &u     [[buffer(0)]],
    uint2 gid                              [[thread_position_in_grid]])
{
    if (gid.x >= dest.get_width() || gid.y >= dest.get_height()) return;
    float3 rgb = exportFilterAxis(source, gid.y, gid.x, true, u);
    dest.write(float4(u.encode != 0 ? exportEncodeSRGB(rgb) : rgb, 1.0), gid);
}

// ---------------------------------------------------------------------
// HDR gain map (ISO 21496-1). Both inputs are linear, at the gain map's
// size, in the file's primaries: `base` is the SDR export, `alternate`
// the same edit rendered with headroom. Each channel stores
// log2((alternate + offset) / (base + offset)), scaled from
// [minLog2, maxLog2] to [0, 1] (gamma 1), which is exactly what a reader
// undoes to rebuild the HDR picture from the SDR one. Mirror of
// GainMapUniforms in GainMap.swift.
struct GainMapUniforms {
    float minLog2;
    float maxLog2;
    float baseOffset;
    float alternateOffset;
};

kernel void exportGainMap(
    texture2d<float, access::read>  base      [[texture(0)]],
    texture2d<float, access::read>  alternate [[texture(1)]],
    texture2d<float, access::write> gain      [[texture(2)]],
    constant GainMapUniforms &u               [[buffer(0)]],
    uint2 gid                                 [[thread_position_in_grid]])
{
    if (gid.x >= gain.get_width() || gid.y >= gain.get_height()) return;
    float3 sdr = max(base.read(gid).rgb, 0.0);
    float3 hdr = max(alternate.read(gid).rgb, 0.0);
    float3 g = log2((hdr + u.alternateOffset) / (sdr + u.baseOffset));
    float3 n = clamp((g - u.minLog2) / (u.maxLog2 - u.minLog2), 0.0, 1.0);
    gain.write(float4(n, 1.0), gid);
}
