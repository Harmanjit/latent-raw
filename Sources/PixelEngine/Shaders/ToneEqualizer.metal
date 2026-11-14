#include <metal_stdlib>
using namespace metal;

// The tone equalizer (ToneEqualizer.swift, ToneEqualizerStage.swift): an
// exposure gain per pixel, read from nine bands at the pixel's smoothed
// brightness, in scene-linear camera space before the colour kernel.
//
// The smoothed brightness is a fast guided filter of log2 luminance:
//
//   toneEqPrepare       whole image -> (I, I^2) on a small grid, I = log2 Y
//   lcBlurH/V           (LocalContrast.metal) box-like means of that pair
//   toneEqCoefficients  means -> the filter's (a, b) per grid cell
//   lcBlurH/V           means of (a, b)
//   toneEqGridMask      a * I + b on the grid, read back for the panel
//   toneEqApply         per pixel: mask = a * I + b with the pixel's own I,
//                       (a, b) sampled from the grid, so edges stay sharp at
//                       full resolution; then the gain
//
// The grid covers the whole sensor whatever this render covers, so a
// 100 % tile and an export read the same mask as the preview.

struct ToneEqPrepareParams {
    float4 yRow;          // xyz: luminance row of the camera matrix
    float4 sourceRect;    // xy: sensor origin of the source, z: its bin span
    float4 sensorSize;    // xy: sensor size in pixels
};

kernel void toneEqPrepare(
    texture2d<float, access::read>  source  [[texture(0)]],
    texture2d<float, access::write> pair    [[texture(1)]],
    constant ToneEqPrepareParams &p         [[buffer(0)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    uint gw = pair.get_width(), gh = pair.get_height();
    if (gid.x >= gw || gid.y >= gh) return;
    int sw = int(source.get_width()), sh = int(source.get_height());
    float2 cell = p.sensorSize.xy / float2(gw, gh);
    float2 lo = (float2(gid) * cell - p.sourceRect.xy) / p.sourceRect.z;
    float2 hi = (float2(gid + 1) * cell - p.sourceRect.xy) / p.sourceRect.z;
    int x0 = clamp(int(floor(lo.x)), 0, sw - 1), x1 = clamp(int(ceil(hi.x)), x0 + 1, sw);
    int y0 = clamp(int(floor(lo.y)), 0, sh - 1), y1 = clamp(int(ceil(hi.y)), y0 + 1, sh);
    // At most 16 x 16 reads per cell, however large the source.
    int stepX = max(1, (x1 - x0) / 16), stepY = max(1, (y1 - y0) / 16);
    float sum = 0.0, n = 0.0;
    for (int y = y0; y < y1; y += stepY) {
        for (int x = x0; x < x1; x += stepX) {
            sum += max(dot(p.yRow.xyz, source.read(uint2(x, y)).rgb), 0.0);
            n += 1.0;
        }
    }
    float i = log2(max(sum / max(n, 1.0), 1.0 / 65536.0));
    pair.write(float4(i, i * i, 0, 1), gid);
}

kernel void toneEqCoefficients(
    texture2d<float, access::read>  means   [[texture(0)]],   // r: mean I, g: mean I^2
    texture2d<float, access::write> coeffs  [[texture(1)]],   // r: a, g: b
    constant float &epsilon                 [[buffer(0)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    if (gid.x >= coeffs.get_width() || gid.y >= coeffs.get_height()) return;
    float2 m = means.read(gid).rg;
    float variance = max(m.y - m.x * m.x, 0.0);
    float a = variance / (variance + epsilon);
    coeffs.write(float4(a, m.x * (1.0 - a), 0, 1), gid);
}

kernel void toneEqGridMask(
    texture2d<float, access::read>  pair    [[texture(0)]],
    texture2d<float, access::read>  coeffs  [[texture(1)]],
    texture2d<float, access::write> mask    [[texture(2)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    if (gid.x >= mask.get_width() || gid.y >= mask.get_height()) return;
    float2 ab = coeffs.read(gid).rg;
    mask.write(float4(ab.x * pair.read(gid).r + ab.y, 0, 0, 1), gid);
}

struct ToneEqApplyParams {
    float4 yRow;          // xyz: luminance row; w: log2 of the exposure
    float4 placement;     // xy: tile origin (sensor px), z: bin span
    float4 sensorSize;    // xy: sensor size; z: exposure compensation, w: contrast factor
    float4 clipLevel;     // xyz: where each channel clips; w: highlight threshold
    float4 table;         // x: highlight strength, y: table low EV, z: table high EV, w: entries
    uint4 flags;          // x: 1 = write the mask texture
};

// The colour kernel's highlight reconstruction (ColorPipeline.metal),
// repeated so a pixel this stage darkens is first rebuilt as the colour
// kernel would have rebuilt it: darkened, it no longer reads as clipped.
inline float3 toneEqReconstruct(float3 rgb, float3 clipLevel, float threshold, float strength) {
    float3 blendStart = clipLevel * threshold;
    float3 blendRange = max(clipLevel - blendStart, float3(1e-6));
    float3 t = saturate((rgb - blendStart) / blendRange);
    float brightest = max(rgb.r, max(rgb.g, rgb.b));
    return mix(rgb, mix(rgb, float3(brightest), t), strength);
}

inline float2 toneEqSampleCoefficients(texture2d<float, access::read> coeffs, float2 uv) {
    int w = int(coeffs.get_width()), h = int(coeffs.get_height());
    float2 f = clamp(uv * float2(w, h) - 0.5, float2(0.0), float2(w - 1, h - 1));
    int x0 = int(f.x), y0 = int(f.y);
    int x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1);
    float2 t = f - float2(x0, y0);
    float2 top = mix(coeffs.read(uint2(x0, y0)).rg, coeffs.read(uint2(x1, y0)).rg, t.x);
    float2 bottom = mix(coeffs.read(uint2(x0, y1)).rg, coeffs.read(uint2(x1, y1)).rg, t.x);
    return mix(top, bottom, t.y);
}

kernel void toneEqApply(
    texture2d<float, access::read>  input   [[texture(0)]],
    texture2d<float, access::write> output  [[texture(1)]],
    texture2d<float, access::read>  coeffs  [[texture(2)]],
    texture2d<float, access::write> maskOut [[texture(3)]],
    constant ToneEqApplyParams &p           [[buffer(0)]],
    constant float *table                   [[buffer(1)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) return;
    float4 px = input.read(gid);
    float3 rgb = px.rgb;
    float i = log2(max(dot(p.yRow.xyz, rgb), 1.0 / 65536.0));
    float2 sensor = p.placement.xy + (float2(gid) + 0.5) * p.placement.z;
    float2 ab = toneEqSampleCoefficients(coeffs, sensor / p.sensorSize.xy);
    float m = ab.x * i + ab.y + p.yRow.w;
    m = (m + p.sensorSize.z + 4.0) * p.sensorSize.w - 4.0;
    if (p.flags.x != 0) maskOut.write(float4(m, 0, 0, 1), gid);

    int entries = int(p.table.w);
    float pos = clamp((m - p.table.y) / (p.table.z - p.table.y), 0.0, 1.0) * float(entries - 1);
    int k0 = min(int(pos), entries - 1), k1 = min(k0 + 1, entries - 1);
    float gainEV = mix(table[k0], table[k1], pos - float(k0));
    float g = exp2(gainEV);

    float3 result = rgb * g;
    float threshold = p.clipLevel.w, strength = p.table.x;
    if (g < 1.0 && strength > 0.0) {
        // Fully rebuilt once the gain takes the pixel below the blend's
        // start (then the colour kernel leaves it alone); in between, part.
        float w = saturate((1.0 - g) / max(1.0 - threshold, 1e-3));
        float3 rebuilt = toneEqReconstruct(rgb, p.clipLevel.xyz, threshold, strength);
        result = mix(rgb, rebuilt, w) * g;
    }
    output.write(float4(result, px.a), gid);
}

// Show Mask: the mask in grey, −8 EV black to 0 EV white, evenly spaced to
// the eye, in place of the picture (viewport only).
kernel void toneEqMaskView(
    texture2d<float, access::read>  mask    [[texture(0)]],
    texture2d<float, access::write> output  [[texture(1)]],
    constant uint &linearOutput             [[buffer(0)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    uint2 src = min(gid, uint2(mask.get_width() - 1, mask.get_height() - 1));
    float grey = saturate((mask.read(src).r + 8.0) / 8.0);
    float v = linearOutput != 0 ? pow(grey, 2.2) : grey;
    output.write(float4(v, v, v, 1), gid);
}
