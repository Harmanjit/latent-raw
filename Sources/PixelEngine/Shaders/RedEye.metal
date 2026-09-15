#include <metal_stdlib>
using namespace metal;

// Red-eye removal, in camera space right after spot removal and on the
// same working texture (HealStage.swift), so a spot's coordinates are
// sensor coordinates like a heal patch's.
//
// Inside the spot's circle, pixels that are flash-red become a neutral
// pupil. Colours are judged in linear Display P3, where the thresholds
// were tuned (minivu), and the result is converted back to camera RGB.
//
//   redEyeApply  the correction over the spot's box, into a scratch texture
//   redEyePaste  the scratch back into the working texture
//
// A smoothed mask of pupil-red pixels (a 5 x 5 Gaussian at a tenth of the
// radius) keeps a stray red pixel elsewhere in the circle as it was while
// the pupil's edge is corrected softly. Each pixel is also gated by its
// own colour, so the white catchlight, the iris and the skin keep theirs:
// pupil red, or pink where the pupil's red blends into the catchlight
// (redness above 1.03 with green and blue about equal), which would
// otherwise stay as a pink ring. The pupil becomes grey at the level of
// its green and blue, which the flash's red reflection doesn't reach, so
// it keeps its shading and reads as a pupil with depth, not a black disc.

struct RedEyeSpotGPU {
    float2 centre;     // texture pixels
    float radius;      // texture pixels
    float strength;    // 0...1
    int2 boxOrigin;    // texel at the scratch's top-left
    int2 boxSize;      // texels
};

// Must match RedEyeTuning in RedEye.swift.
constant float redEyeLowThreshold = 3.2;
constant float redEyeHighThreshold = 4.8;
constant float redEyeMaskGain = 1.8;      // so the whole pupil is corrected, not just its reddest middle
constant float redEyeDarkening = 0.85;    // the pupil's grey, as a fraction of its green and blue
constant float redEyeFeather = 0.15;      // the circle's edge fades over this fraction of the radius

// Red over the larger of green and blue. A red-eye pupil measures 5 to
// 15, skin 1.5 to 2, a brown iris about 3; the floor keeps near-black
// noise from counting. The floor is a fifth of minivu's: camera values
// sit a stop or two below display-referred ones (no baseline exposure
// yet, and the sensor's headroom above white), and minivu's floor
// swallowed a dim red cloth's green here.
inline float redEyeRedness(float3 c) {
    return c.r / max(max(c.g, c.b), 0.001);
}

// How close to magenta-red rather than orange-brown: blue over green,
// each lifted by a fiftieth of the red. A flash's red reflection leaves
// green and blue about equal (1); a dark, saturated brown iris keeps far
// more green than blue (about 0.35).
inline float redEyePurple(float3 c) {
    float lift = 0.02 * max(c.r, 0.0);
    return smoothstep(0.35, 0.6, (max(c.b, 0.0) + lift) / max(max(c.g, 0.0) + lift, 1e-6));
}

inline float redEyePupilRed(float3 c) {
    return smoothstep(redEyeLowThreshold, redEyeHighThreshold, redEyeRedness(c)) * redEyePurple(c);
}

inline float redEyeRadial(float2 p, constant RedEyeSpotGPU &e) {
    return 1.0 - smoothstep((1.0 - redEyeFeather) * e.radius, e.radius, length(p - e.centre));
}

kernel void redEyeApply(
    texture2d<float, access::sample> state   [[texture(0)]],
    texture2d<float, access::write>  scratch [[texture(1)]],
    constant RedEyeSpotGPU &e                [[buffer(0)]],
    constant float3x3 &toP3                  [[buffer(1)]],
    constant float3x3 &fromP3                [[buffer(2)]],
    uint2 gid                                [[thread_position_in_grid]])
{
    if (int(gid.x) >= e.boxSize.x || int(gid.y) >= e.boxSize.y) return;
    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);

    float2 here = float2(int2(gid) + e.boxOrigin) + 0.5;
    float4 c = state.sample(s, here);
    float radial = redEyeRadial(here, e);
    if (radial <= 0.0) { scratch.write(c, gid); return; }

    float3 p = toP3 * c.rgb;
    float pupil = redEyePupilRed(p);
    float greenBlue = max(max(p.g, p.b), 1e-6);
    float pink = smoothstep(1.03, 1.35, redEyeRedness(p)) * smoothstep(0.75, 0.9, min(p.g, p.b) / greenBlue);
    float gate = max(pupil, pink);
    if (gate <= 0.0) { scratch.write(c, gid); return; }

    float sigma = max(0.1 * e.radius, 0.5);
    float sum = 0.0, total = 0.0;
    for (int j = -2; j <= 2; j++) {
        for (int i = -2; i <= 2; i++) {
            float2 q = here + float2(i, j) * sigma;
            float w = exp(-0.5 * float(i * i + j * j));
            sum += w * redEyePupilRed(toP3 * state.sample(s, q).rgb) * redEyeRadial(q, e);
            total += w;
        }
    }
    float m = clamp(sum / total * redEyeMaskGain, 0.0, 1.0) * gate * radial * e.strength;
    if (m <= 0.0) { scratch.write(c, gid); return; }
    // Pink edges keep their brightness; only the pupil itself darkens.
    float grey = max(min(p.g, p.b), 0.0) * mix(1.0, redEyeDarkening, pupil);
    c.rgb = fromP3 * mix(p, float3(grey), clamp(m, 0.0, 1.0));
    scratch.write(c, gid);
}

kernel void redEyePaste(
    texture2d<float, access::read>  scratch [[texture(0)]],
    texture2d<float, access::write> state   [[texture(1)]],
    constant RedEyeSpotGPU &e               [[buffer(0)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    if (int(gid.x) >= e.boxSize.x || int(gid.y) >= e.boxSize.y) return;
    state.write(scratch.read(gid), uint2(int2(gid) + e.boxOrigin));
}
