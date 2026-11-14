#include <metal_stdlib>
#include "Common.h"
using namespace metal;

// LMMSE DEMOSAICING
//
// Linear minimum mean square-error estimation of the colour differences,
// after L. Zhang and X. Wu, "Color demosaicking via directional linear
// minimum mean square-error estimation" (IEEE TIP, 2005), the method
// behind RawTherapee's and darktable's "LMMSE". It is the demosaic to
// pick for high-ISO files: where RCD decides a direction from gradients,
// which noise can fool into mazes and zippers, LMMSE weighs a horizontal
// and a vertical estimate of green-minus-colour by how much each one's
// local signal stands above its own noise, so noisy areas get a smooth,
// statistically safe answer instead of a wrong guess.
//
// Five dependent passes (RenderPipeline+LMMSE.swift), each reading its
// predecessor's neighbourhood:
//   1. lmmseDifferences: horizontal and vertical estimates of G - C at
//      every photosite, from Hamilton-Adams 1D interpolation.
//   2. lmmseSmooth: the same differences low-passed along their own
//      direction (a 9-tap Gaussian): the "signal" part.
//   3. lmmseGreen: at each red and blue photosite, the LMMSE estimate of
//      each direction's difference (mean, signal and noise variance over a
//      9-pixel window), the two fused by their error variances, and green
//      as the photosite's own value plus the fused difference.
//   4. lmmseRedBlueAtOpposite: red at blue sites and blue at red sites,
//      from the mean colour difference of the four diagonal neighbours.
//   5. lmmseRedBlueAtGreen: red and blue at green sites, from the mean
//      colour difference of the four axial neighbours.
//
// Edges mirror about the edge photosite (reflect-101), as RCD does, which
// keeps every read on a photosite of the expected colour. The deepest read
// chain is 2 + 4 + 4 + 1 + 1 = 12 photosites, inside the 16-pixel apron a
// region render already keeps for RCD (RenderPipeline.lensApron).

constant float kLMMSEEps = 1e-9f;

/// Reflect-101 index into [0, n), as `rcdMirror`.
inline int lmmseMirror(int i, int n) {
    int last = n - 1;
    return clamp(last - abs(last - abs(i)), 0, last);
}

inline float lmmseRead(texture2d<float, access::read> tex, int x, int y) {
    return tex.read(uint2(lmmseMirror(x, int(tex.get_width())), lmmseMirror(y, int(tex.get_height())))).r;
}

inline float4 lmmseRead4(texture2d<float, access::read> tex, int x, int y) {
    return tex.read(uint2(lmmseMirror(x, int(tex.get_width())), lmmseMirror(y, int(tex.get_height()))));
}

/// The 9-tap Gaussian (sigma 2) of the smoothing pass, centre first.
constant float kLMMSEGauss[5] = {
    0.20416368871516755f, 0.18017382291138087f, 0.12383153680577530f,
    0.06628224528636122f, 0.02763055063889883f
};

// 1. Directional colour differences. rg = (horizontal, vertical).
kernel void lmmseDifferences(
    texture2d<float, access::read>  cfa   [[texture(0)]],
    texture2d<float, access::write> diff  [[texture(1)]],
    constant uint8_t &order               [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= diff.get_width() || gid.y >= diff.get_height()) return;
    int x = int(gid.x), y = int(gid.y);
    float c = lmmseRead(cfa, x, y);
    float h = 0.5f * (lmmseRead(cfa, x - 1, y) + lmmseRead(cfa, x + 1, y))
            + 0.25f * (2.0f * c - lmmseRead(cfa, x - 2, y) - lmmseRead(cfa, x + 2, y));
    float v = 0.5f * (lmmseRead(cfa, x, y - 1) + lmmseRead(cfa, x, y + 1))
            + 0.25f * (2.0f * c - lmmseRead(cfa, x, y - 2) - lmmseRead(cfa, x, y + 2));
    // At a red or blue photosite the estimate is green: G - C = est - c.
    // At a green one it is the missing colour: G - C = c - est.
    float sign = cfaColorRGB(order, gid.x, gid.y) == 1 ? -1.0f : 1.0f;
    diff.write(float4(sign * (h - c), sign * (v - c), 0, 0), gid);
}

// 2. Each difference low-passed along its own direction.
kernel void lmmseSmooth(
    texture2d<float, access::read>  diff   [[texture(0)]],
    texture2d<float, access::write> smooth [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= smooth.get_width() || gid.y >= smooth.get_height()) return;
    int x = int(gid.x), y = int(gid.y);
    float h = kLMMSEGauss[0] * lmmseRead4(diff, x, y).r;
    float v = kLMMSEGauss[0] * lmmseRead4(diff, x, y).g;
    for (int k = 1; k <= 4; k++) {
        h += kLMMSEGauss[k] * (lmmseRead4(diff, x - k, y).r + lmmseRead4(diff, x + k, y).r);
        v += kLMMSEGauss[k] * (lmmseRead4(diff, x, y - k).g + lmmseRead4(diff, x, y + k).g);
    }
    smooth.write(float4(h, v, 0, 0), gid);
}

// 3. Green everywhere: the fused LMMSE estimate of G - C at red and blue
// photosites, the measured value at green ones. The photosite's own
// colour is carried in its channel for the next passes.
kernel void lmmseGreen(
    texture2d<float, access::read>  cfa    [[texture(0)]],
    texture2d<float, access::read>  diff   [[texture(1)]],
    texture2d<float, access::read>  smooth [[texture(2)]],
    texture2d<float, access::write> rgb    [[texture(3)]],
    constant uint8_t &order                [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= rgb.get_width() || gid.y >= rgb.get_height()) return;
    int x = int(gid.x), y = int(gid.y);
    float c = lmmseRead(cfa, x, y);
    uint colour = cfaColorRGB(order, gid.x, gid.y);
    float3 out = float3(0.0f);
    if (colour == 1u) {
        out.g = c;
    } else {
        // Window statistics along each direction.
        float muH = 0, muV = 0, ssH = 0, ssV = 0, noiseH = 0, noiseV = 0;
        for (int k = -4; k <= 4; k++) {
            float sh = lmmseRead4(smooth, x + k, y).r;
            float sv = lmmseRead4(smooth, x, y + k).g;
            float dh = lmmseRead4(diff, x + k, y).r;
            float dv = lmmseRead4(diff, x, y + k).g;
            muH += sh; muV += sv;
            ssH += sh * sh; ssV += sv * sv;
            noiseH += (dh - sh) * (dh - sh);
            noiseV += (dv - sv) * (dv - sv);
        }
        muH /= 9.0f; muV /= 9.0f;
        float sigH = max(ssH / 9.0f - muH * muH, 0.0f) + kLMMSEEps;
        float sigV = max(ssV / 9.0f - muV * muV, 0.0f) + kLMMSEEps;
        noiseH = noiseH / 9.0f + kLMMSEEps;
        noiseV = noiseV / 9.0f + kLMMSEEps;
        float dh = lmmseRead4(diff, x, y).r;
        float dv = lmmseRead4(diff, x, y).g;
        // LMMSE estimate of each direction's difference, and its error.
        float estH = (dh * sigH + muH * noiseH) / (sigH + noiseH);
        float estV = (dv * sigV + muV * noiseV) / (sigV + noiseV);
        float errH = sigH * noiseH / (sigH + noiseH);
        float errV = sigV * noiseV / (sigV + noiseV);
        // Fused by inverse error variance.
        float d = (estH * errV + estV * errH) / (errH + errV);
        out.g = max(c + d, 0.0f);
        if (colour == 0u) out.r = c; else out.b = c;
    }
    rgb.write(float4(out, 1.0f), gid);
}

// 4. Red at blue photosites and blue at red ones, from the diagonal
// neighbours' colour differences (each of which is the wanted colour).
kernel void lmmseRedBlueAtOpposite(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant uint8_t &order                [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    int x = int(gid.x), y = int(gid.y);
    float4 p = lmmseRead4(input, x, y);
    uint colour = cfaColorRGB(order, gid.x, gid.y);
    if (colour != 1u) {
        uint want = colour == 0u ? 2u : 0u;
        float sum = 0;
        for (int dy = -1; dy <= 1; dy += 2) {
            for (int dx = -1; dx <= 1; dx += 2) {
                float4 q = lmmseRead4(input, x + dx, y + dy);
                sum += q.g - (want == 0u ? q.r : q.b);
            }
        }
        float value = max(p.g - 0.25f * sum, 0.0f);
        if (want == 0u) p.r = value; else p.b = value;
    }
    output.write(p, gid);
}

// 5. Red and blue at green photosites, from the four axial neighbours,
// which after pass 4 all hold both.
kernel void lmmseRedBlueAtGreen(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant uint8_t &order                [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    int x = int(gid.x), y = int(gid.y);
    float4 p = lmmseRead4(input, x, y);
    if (cfaColorRGB(order, gid.x, gid.y) == 1u) {
        float4 l = lmmseRead4(input, x - 1, y), r = lmmseRead4(input, x + 1, y);
        float4 u = lmmseRead4(input, x, y - 1), d = lmmseRead4(input, x, y + 1);
        float dr = (l.g - l.r) + (r.g - r.r) + (u.g - u.r) + (d.g - d.r);
        float db = (l.g - l.b) + (r.g - r.b) + (u.g - u.b) + (d.g - d.b);
        p.r = max(p.g - 0.25f * dr, 0.0f);
        p.b = max(p.g - 0.25f * db, 0.0f);
    }
    output.write(float4(p.rgb, 1.0f), gid);
}
