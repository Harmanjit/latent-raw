#include <metal_stdlib>
using namespace metal;

// Detail stages: noise reduction and sharpening (DESIGN.md §8.1 stages
// 4 and 17).

// ---------------------------------------------------------------------
// Denoise: a bilateral filter in linear camera space, run before the
// colour matrix so the noise still has its physical character.
//
// Photon shot noise has a standard deviation proportional to the square
// root of the signal, so the filter's tolerance for "this neighbour is
// the same thing, just noisy" grows with sqrt(brightness). That single
// idea is what stops it smearing real edges in the highlights while
// still cleaning up shadows. Luminance and chroma are filtered with
// separate tolerances: colour noise is coarser and can take a looser
// filter without visible loss.
//
// `noiseScale` compensates for binning — a preview binned 2N x 2N has
// noise reduced by 2N, so the tolerance shrinks to match and the
// preview predicts the full-resolution result.
// ---------------------------------------------------------------------
constant int kDenoiseRadius = 3;

inline float cameraLuma(float3 c) { return dot(c, float3(0.25, 0.5, 0.25)); }

kernel void denoiseBilateral(
    texture2d<float, access::read>  input   [[texture(0)]],
    texture2d<float, access::write> output  [[texture(1)]],
    constant float &lumaStrength            [[buffer(0)]],
    constant float &chromaStrength          [[buffer(1)]],
    constant float &noiseScale              [[buffer(2)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    int w = int(input.get_width()), h = int(input.get_height());
    if (gid.x >= uint(w) || gid.y >= uint(h)) return;

    float3 centre = input.read(gid).rgb;
    float yc = max(cameraLuma(centre), 0.0);
    float noise = sqrt(yc + 1e-4) * noiseScale;

    // Tolerances in the same units as the signal. 0.06 at full strength
    // means: at mid grey on a 14-bit sensor, roughly ISO 6400 noise.
    float sigmaL = max(lumaStrength * 0.06 * noise, 1e-6);
    float sigmaC = max(chromaStrength * 0.25 * noise, 1e-6);
    float invL = 1.0 / (2.0 * sigmaL * sigmaL);
    float invC = 1.0 / (2.0 * sigmaC * sigmaC);
    // Spatial falloff: sigma ~ radius/2.
    float invS = 1.0 / (2.0 * 1.5 * 1.5);

    float sumL = 0.0, wL = 0.0;
    float3 sumC = float3(0.0); float wC = 0.0;

    for (int dy = -kDenoiseRadius; dy <= kDenoiseRadius; dy++) {
        for (int dx = -kDenoiseRadius; dx <= kDenoiseRadius; dx++) {
            int x = clamp(int(gid.x) + dx, 0, w - 1);
            int y = clamp(int(gid.y) + dy, 0, h - 1);
            float3 n = input.read(uint2(x, y)).rgb;
            float yn = max(cameraLuma(n), 0.0);
            float d = yn - yc;
            float spatial = exp(-float(dx * dx + dy * dy) * invS);
            float wl = spatial * exp(-d * d * invL);
            float wc = spatial * exp(-d * d * invC);
            sumL += wl * yn; wL += wl;
            // Chroma as ratios to luma, so brightness changes don't leak
            // into the colour average.
            sumC += wc * (n / max(yn, 1e-4)); wC += wc;
        }
    }

    float lumaOut = (lumaStrength > 0.0) ? sumL / max(wL, 1e-6) : yc;
    float3 chromaOut = (chromaStrength > 0.0) ? sumC / max(wC, 1e-6)
                                              : centre / max(yc, 1e-4);
    output.write(float4(lumaOut * chromaOut, 1.0), gid);
}

// ---------------------------------------------------------------------
// Sharpening: unsharp mask on perceptual luminance, applied to the
// display-referred image as the last stage.
//
// Luminance only, so nothing changes colour, and perceptual (gamma-ish)
// rather than linear so highlights and shadows get the same treatment
// to the eye. Three passes: blur horizontally, blur vertically, then
// apply — a separable Gaussian is far cheaper than a 2D one.
//
// `inputIsLinear` says whether the texture holds linear light (the EDR
// screen buffer) or already-encoded values (a file); luminance is taken
// to the perceptual domain either way and the result mapped back.
// ---------------------------------------------------------------------
constant int kMaxBlurTaps = 33;

inline float perceptualLuma(float3 c, bool isLinear) {
    float y = dot(max(c, 0.0), float3(0.2126, 0.7152, 0.0722));
    return isLinear ? pow(y, 1.0 / 2.2) : y;
}

kernel void sharpenBlurH(
    texture2d<float, access::read>  image   [[texture(0)]],
    texture2d<float, access::write> blurred [[texture(1)]],
    constant float *weights                 [[buffer(0)]],
    constant int &taps                      [[buffer(1)]],
    constant uint &inputIsLinear            [[buffer(2)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    int w = int(image.get_width()), h = int(image.get_height());
    if (gid.x >= uint(w) || gid.y >= uint(h)) return;
    int halfTaps = taps / 2;
    float sum = 0.0;
    for (int i = 0; i < taps && i < kMaxBlurTaps; i++) {
        int x = clamp(int(gid.x) + i - halfTaps, 0, w - 1);
        sum += weights[i] * perceptualLuma(image.read(uint2(x, gid.y)).rgb, inputIsLinear != 0);
    }
    blurred.write(float4(sum, 0, 0, 1), gid);
}

kernel void sharpenBlurV(
    texture2d<float, access::read>  input   [[texture(0)]],
    texture2d<float, access::write> blurred [[texture(1)]],
    constant float *weights                 [[buffer(0)]],
    constant int &taps                      [[buffer(1)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    int w = int(input.get_width()), h = int(input.get_height());
    if (gid.x >= uint(w) || gid.y >= uint(h)) return;
    int halfTaps = taps / 2;
    float sum = 0.0;
    for (int i = 0; i < taps && i < kMaxBlurTaps; i++) {
        int y = clamp(int(gid.y) + i - halfTaps, 0, h - 1);
        sum += weights[i] * input.read(uint2(gid.x, y)).r;
    }
    blurred.write(float4(sum, 0, 0, 1), gid);
}

kernel void sharpenApply(
    texture2d<float, access::read>  image   [[texture(0)]],
    texture2d<float, access::read>  blurred [[texture(1)]],
    texture2d<float, access::write> output  [[texture(2)]],
    constant float &amount                  [[buffer(0)]],
    constant float &threshold               [[buffer(1)]],
    constant uint &inputIsLinear            [[buffer(2)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    bool isLinear = inputIsLinear != 0;
    float3 c = image.read(gid).rgb;
    float l = perceptualLuma(c, isLinear);
    float detail = l - blurred.read(gid).r;

    // Soft threshold: detail below it (noise, grain) is left alone; the
    // transition is smooth so there's no visible cutoff.
    float mag = abs(detail);
    float pass = smoothstep(threshold, threshold * 2.0 + 1e-4, mag);
    float lSharp = max(l + amount * detail * pass, 0.0);

    // Scale RGB by the luminance change, back in the image's own domain.
    float ratio = (l > 1e-5) ? lSharp / l : 1.0;
    if (isLinear) ratio = pow(ratio, 2.2);
    output.write(float4(c * ratio, 1.0), gid);
}
