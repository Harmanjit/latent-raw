#include <metal_stdlib>
#include "Common.h"
using namespace metal;

// RATIO CORRECTED DEMOSAICING (RCD)
//
// Ported to Metal from RawTherapee's rtengine/rcd_demosaic.cc.
// Original algorithm (c) 2017-2020 Luis Sanz Rodriguez; tiled C++
// implementation by Ingo Weyrich. Both RawTherapee and Latent are GPLv3,
// which is what makes this port possible.
//
// Why RCD over the bilinear placeholder: bilinear averages its neighbours
// blindly, so any edge that isn't axis-aligned turns into a zipper of
// alternating colour. RCD first works out which *direction* the local
// detail runs in — vertical, horizontal, or one of the two diagonals — and
// interpolates along that direction rather than across it. The "ratio
// corrected" part refers to using local colour ratios rather than raw
// differences, which keeps hue stable through brightness changes.
//
// Structural note: RawTherapee runs this in 194x194 tiles so the working
// set stays in cache. This port uses full-image passes instead — simpler,
// easier to verify, and it costs memory rather than correctness. Each stage
// needs its predecessor's *neighbourhood*, not just the matching pixel, so
// the stages genuinely cannot be fused into one kernel: GPU threads can't
// see each other's results within a dispatch.
//
// Epsilon note: the original uses eps=1e-5 and epssq=1e-10. Those are fine
// in 32-bit float but 1e-10 flushes to zero in half precision, which turns
// the guard divisions below into 0/0. The values here are raised enough to
// survive the half-precision intermediate textures while staying far below
// any real signal.

constant float kRCDEps = 1e-5f;
constant float kRCDEpsSq = 1e-4f;

/// Linear blend, matching RawTherapee's `intp`.
inline float rcdIntp(float t, float a, float b) {
    return t * a + (1.0f - t) * b;
}

inline float rcdSqr(float x) { return x * x; }

// Frame edges.
//
// RCD reads up to four pixels out, and the passes stack, so a pixel up to
// eleven in from the edge depends on reads past it. Those reads mirror
// back into the frame about the edge photosite (reflect-101: -1 reads 1,
// w reads w-2), which is what every stage below computes on: RCD of the
// frame extended by its own mirror image. The mirror keeps each read on a
// photosite of the colour the stage expects, because reflecting about a
// photosite preserves the parity of the index. Clamping to the edge, as
// this used to, lands odd offsets on the other colour of the edge row: at
// a green site on the top row of an RGGB frame, "blue one row up" read the
// same row's unfilled blue, so the outermost row and column came out with
// one channel at half its value. The perspective and lens stages fill what
// they pull in from outside the frame by repeating that edge pixel, which
// turned the error into coloured wedges.
//
// rcdMirror hands back an index inside the frame unchanged, so a pixel
// whose reads all stay inside comes out bit for bit as it did with the
// clamp; on a 24 MP frame nothing more than nine pixels in changed.

/// Reflect-101 index into [0, n). Exact for reads up to n-1 past either
/// edge, far beyond RCD's reach for any real frame; the clamp only keeps a
/// frame narrower than that reach (a few pixels) inside the texture.
/// Branchless and division-free, because it runs on every read: an
/// earlier version with a branch and a modulo took RCD from 33 to 53 ms
/// on a 24 MP frame.
inline int rcdMirror(int i, int n) {
    int last = n - 1;
    return clamp(last - abs(last - abs(i)), 0, last);
}

/// Whether `rcdMirror` turns the axis around for this index. Only the
/// diagonal statistics care, because a mirror in one axis swaps the
/// down-right diagonal for the down-left one.
inline bool rcdMirrorFlips(int i, int n) {
    return i < 0 || i >= n;
}

inline float rcdRead(texture2d<float, access::read> tex, int x, int y) {
    int w = int(tex.get_width());
    int h = int(tex.get_height());
    return tex.read(uint2(rcdMirror(x, w), rcdMirror(y, h))).r;
}

inline float4 rcdRead4(texture2d<float, access::read> tex, int x, int y) {
    int w = int(tex.get_width());
    int h = int(tex.get_height());
    return tex.read(uint2(rcdMirror(x, w), rcdMirror(y, h)));
}

/// True when a read at (x, y) is mirrored in exactly one axis, so a
/// diagonal statistic read there belongs to the other diagonal.
inline bool rcdDiagonalsSwap(texture2d<float, access::read> tex, int x, int y) {
    return rcdMirrorFlips(x, int(tex.get_width())) != rcdMirrorFlips(y, int(tex.get_height()));
}

/// The P (red) and Q (green) diagonal statistics as seen from (x, y).
inline float2 rcdReadPQ(texture2d<float, access::read> tex, int x, int y) {
    float2 pq = rcdRead4(tex, x, y).rg;
    return rcdDiagonalsSwap(tex, x, y) ? pq.yx : pq;
}

/// The P-over-Q discrimination as seen from (x, y): mirrored in one axis,
/// P and Q trade places, so the ratio becomes its complement.
inline float rcdReadPQDir(texture2d<float, access::read> tex, int x, int y) {
    float v = rcdRead(tex, x, y);
    return rcdDiagonalsSwap(tex, x, y) ? 1.0f - v : v;
}

inline float rcdChannel(texture2d<float, access::read> tex, int x, int y, uint c) {
    float4 v = rcdRead4(tex, x, y);
    return c == 0u ? v.r : (c == 1u ? v.g : v.b);
}

/// The vertical colour-difference high-pass filter, squared.
inline float rcdVerticalHPF(texture2d<float, access::read> cfa, int x, int y) {
    float v = (rcdRead(cfa, x, y - 3) - rcdRead(cfa, x, y - 1)
               - rcdRead(cfa, x, y + 1) + rcdRead(cfa, x, y + 3))
            - 3.0f * (rcdRead(cfa, x, y - 2) + rcdRead(cfa, x, y + 2))
            + 6.0f * rcdRead(cfa, x, y);
    return rcdSqr(v);
}

/// The horizontal colour-difference high-pass filter, squared.
inline float rcdHorizontalHPF(texture2d<float, access::read> cfa, int x, int y) {
    float v = (rcdRead(cfa, x - 3, y) - rcdRead(cfa, x - 1, y)
               - rcdRead(cfa, x + 1, y) + rcdRead(cfa, x + 3, y))
            - 3.0f * (rcdRead(cfa, x - 2, y) + rcdRead(cfa, x + 2, y))
            + 6.0f * rcdRead(cfa, x, y);
    return rcdSqr(v);
}

// ---------------------------------------------------------------------
// Step 1: vertical vs. horizontal directional discrimination.
//
// Produces, for every pixel, a value in [0,1] saying how much the local
// detail runs vertically rather than horizontally. 0.5 means no preference.
// Later stages weight their interpolation by this.
// ---------------------------------------------------------------------
kernel void rcdDirectionsVH(
    texture2d<float, access::read>  cfa    [[texture(0)]],
    texture2d<float, access::write> vhDir  [[texture(1)]],
    uint2 gid                              [[thread_position_in_grid]])
{
    if (gid.x >= vhDir.get_width() || gid.y >= vhDir.get_height()) return;
    int x = int(gid.x), y = int(gid.y);

    // Three-tap sums either side of the centre, matching the rolling
    // row/column buffers in the original.
    float vStat = max(kRCDEpsSq,
                       rcdVerticalHPF(cfa, x, y - 1)
                       + rcdVerticalHPF(cfa, x, y)
                       + rcdVerticalHPF(cfa, x, y + 1));
    float hStat = max(kRCDEpsSq,
                       rcdHorizontalHPF(cfa, x - 1, y)
                       + rcdHorizontalHPF(cfa, x, y)
                       + rcdHorizontalHPF(cfa, x + 1, y));

    vhDir.write(float4(vStat / (vStat + hStat), 0, 0, 1), gid);
}

// ---------------------------------------------------------------------
// Step 2: low-pass filter over the raw samples.
//
// A local average that mixes all three colours. Step 3 uses the *ratio*
// between this value at neighbouring same-colour sites to correct its
// estimates, which is where "ratio corrected" comes from — it keeps hue
// stable across a brightness gradient instead of letting the interpolation
// drift.
//
// The original packs this at half resolution since only non-green sites are
// read. Computed at every pixel here; the waste is memory, not time, and it
// removes a layer of index arithmetic that's easy to get wrong.
// ---------------------------------------------------------------------
kernel void rcdLowPass(
    texture2d<float, access::read>  cfa  [[texture(0)]],
    texture2d<float, access::write> lpf  [[texture(1)]],
    uint2 gid                            [[thread_position_in_grid]])
{
    if (gid.x >= lpf.get_width() || gid.y >= lpf.get_height()) return;
    int x = int(gid.x), y = int(gid.y);

    float value = rcdRead(cfa, x, y)
        + 0.5f * (rcdRead(cfa, x, y - 1) + rcdRead(cfa, x, y + 1)
                   + rcdRead(cfa, x - 1, y) + rcdRead(cfa, x + 1, y))
        + 0.25f * (rcdRead(cfa, x - 1, y - 1) + rcdRead(cfa, x + 1, y - 1)
                    + rcdRead(cfa, x - 1, y + 1) + rcdRead(cfa, x + 1, y + 1));

    lpf.write(float4(value, 0, 0, 1), gid);
}

// ---------------------------------------------------------------------
// Step 3: green at red and blue sites.
//
// Green is interpolated first because it's sampled at twice the density of
// red and blue, so it carries most of the luminance detail. Everything
// after this leans on the reconstructed green.
//
// Also seeds the output texture: each site keeps its own measured colour in
// its native channel.
// ---------------------------------------------------------------------
kernel void rcdGreen(
    texture2d<float, access::read>  cfa    [[texture(0)]],
    texture2d<float, access::read>  vhDir  [[texture(1)]],
    texture2d<float, access::read>  lpf    [[texture(2)]],
    texture2d<float, access::write> rgb    [[texture(3)]],
    constant uint8_t &cfaPattern           [[buffer(0)]],
    uint2 gid                              [[thread_position_in_grid]])
{
    if (gid.x >= rgb.get_width() || gid.y >= rgb.get_height()) return;
    int x = int(gid.x), y = int(gid.y);

    float centre = rcdRead(cfa, x, y);
    uint8_t colour = cfaColorRGB(cfaPattern, gid.x, gid.y);

    if (colour == 1) {
        // Green site: the measurement is already green.
        rgb.write(float4(0.0f, centre, 0.0f, 1.0f), gid);
        return;
    }

    // Cardinal gradients: how much the signal changes in each direction,
    // out to four pixels. Small gradient means the estimate from that
    // direction is trustworthy.
    float n1 = rcdRead(cfa, x, y - 1), s1 = rcdRead(cfa, x, y + 1);
    float w1 = rcdRead(cfa, x - 1, y), e1 = rcdRead(cfa, x + 1, y);
    float vDiff = abs(n1 - s1);
    float hDiff = abs(w1 - e1);

    float nGrad = kRCDEps + vDiff + abs(centre - rcdRead(cfa, x, y - 2))
                + abs(n1 - rcdRead(cfa, x, y - 3)) + abs(rcdRead(cfa, x, y - 2) - rcdRead(cfa, x, y - 4));
    float sGrad = kRCDEps + vDiff + abs(centre - rcdRead(cfa, x, y + 2))
                + abs(s1 - rcdRead(cfa, x, y + 3)) + abs(rcdRead(cfa, x, y + 2) - rcdRead(cfa, x, y + 4));
    float wGrad = kRCDEps + hDiff + abs(centre - rcdRead(cfa, x - 2, y))
                + abs(w1 - rcdRead(cfa, x - 3, y)) + abs(rcdRead(cfa, x - 2, y) - rcdRead(cfa, x - 4, y));
    float eGrad = kRCDEps + hDiff + abs(centre - rcdRead(cfa, x + 2, y))
                + abs(e1 - rcdRead(cfa, x + 3, y)) + abs(rcdRead(cfa, x + 2, y) - rcdRead(cfa, x + 4, y));

    // Ratio correction: each neighbouring green is scaled by how the local
    // average here compares with the local average two pixels away (the
    // nearest same-colour site in that direction).
    float lpfCentre = rcdRead(lpf, x, y);
    float nEst = n1 * (lpfCentre + lpfCentre) / (kRCDEps + lpfCentre + rcdRead(lpf, x, y - 2));
    float sEst = s1 * (lpfCentre + lpfCentre) / (kRCDEps + lpfCentre + rcdRead(lpf, x, y + 2));
    float wEst = w1 * (lpfCentre + lpfCentre) / (kRCDEps + lpfCentre + rcdRead(lpf, x - 2, y));
    float eEst = e1 * (lpfCentre + lpfCentre) / (kRCDEps + lpfCentre + rcdRead(lpf, x + 2, y));

    // Each axis blends its two estimates, weighted *against* the gradients
    // — the direction that changes less contributes more.
    float vEst = (sGrad * nEst + nGrad * sEst) / (nGrad + sGrad);
    float hEst = (wGrad * eEst + eGrad * wEst) / (eGrad + wGrad);

    // Choose between the two axes using the discrimination from step 1,
    // preferring whichever of the centre or its neighbourhood expresses a
    // stronger opinion (further from the undecided 0.5).
    float vhCentre = rcdRead(vhDir, x, y);
    float vhNeighbourhood = 0.25f * ((rcdRead(vhDir, x - 1, y - 1) + rcdRead(vhDir, x + 1, y - 1))
                                      + (rcdRead(vhDir, x - 1, y + 1) + rcdRead(vhDir, x + 1, y + 1)));
    float vhDisc = abs(0.5f - vhCentre) < abs(0.5f - vhNeighbourhood)
                 ? vhNeighbourhood : vhCentre;

    float green = rcdIntp(vhDisc, hEst, vEst);

    float3 out = float3(0.0f);
    out[colour] = centre;   // keep the native measurement
    out.g = green;
    rgb.write(float4(out, 1.0f), gid);
}

// ---------------------------------------------------------------------
// Step 4.0: diagonal high-pass statistics.
//
// Red and blue sit on a diagonal lattice relative to each other, so their
// interpolation needs diagonal direction-finding rather than the vertical/
// horizontal pair used for green. P is the down-right diagonal, Q the
// down-left.
// ---------------------------------------------------------------------
kernel void rcdDiagonalStats(
    texture2d<float, access::read>  cfa  [[texture(0)]],
    texture2d<float, access::write> pq   [[texture(1)]],
    uint2 gid                            [[thread_position_in_grid]])
{
    if (gid.x >= pq.get_width() || gid.y >= pq.get_height()) return;
    int x = int(gid.x), y = int(gid.y);
    float centre = rcdRead(cfa, x, y);

    float p = (rcdRead(cfa, x - 3, y - 3) - rcdRead(cfa, x - 1, y - 1)
               - rcdRead(cfa, x + 1, y + 1) + rcdRead(cfa, x + 3, y + 3))
            - 3.0f * (rcdRead(cfa, x - 2, y - 2) + rcdRead(cfa, x + 2, y + 2))
            + 6.0f * centre;

    float q = (rcdRead(cfa, x + 3, y - 3) - rcdRead(cfa, x + 1, y - 1)
               - rcdRead(cfa, x - 1, y + 1) + rcdRead(cfa, x - 3, y + 3))
            - 3.0f * (rcdRead(cfa, x + 2, y - 2) + rcdRead(cfa, x - 2, y + 2))
            + 6.0f * centre;

    pq.write(float4(rcdSqr(p), rcdSqr(q), 0, 1), gid);
}

// ---------------------------------------------------------------------
// Step 4.1: diagonal directional discrimination, the diagonal counterpart
// of step 1.
// ---------------------------------------------------------------------
kernel void rcdDirectionsPQ(
    texture2d<float, access::read>  pq     [[texture(0)]],
    texture2d<float, access::write> pqDir  [[texture(1)]],
    uint2 gid                              [[thread_position_in_grid]])
{
    if (gid.x >= pqDir.get_width() || gid.y >= pqDir.get_height()) return;
    int x = int(gid.x), y = int(gid.y);

    // Each statistic is summed along its own diagonal.
    float pStat = max(kRCDEpsSq,
                       rcdReadPQ(pq, x - 1, y - 1).x + rcdReadPQ(pq, x, y).x
                       + rcdReadPQ(pq, x + 1, y + 1).x);
    float qStat = max(kRCDEpsSq,
                       rcdReadPQ(pq, x + 1, y - 1).y + rcdReadPQ(pq, x, y).y
                       + rcdReadPQ(pq, x - 1, y + 1).y);

    pqDir.write(float4(pStat / (pStat + qStat), 0, 0, 1), gid);
}

// ---------------------------------------------------------------------
// Step 4.2: red at blue sites and blue at red sites.
//
// These are the diagonal neighbours. Interpolation happens on the colour
// *difference* against green rather than on the colour itself — green is
// already known everywhere after step 3, and differences vary far more
// smoothly across an image than absolute channel values do.
// ---------------------------------------------------------------------
kernel void rcdRedBlueAtOpposite(
    texture2d<float, access::read>  rgbIn   [[texture(0)]],
    texture2d<float, access::read>  pqDir   [[texture(1)]],
    texture2d<float, access::write> rgbOut  [[texture(2)]],
    constant uint8_t &cfaPattern            [[buffer(0)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    if (gid.x >= rgbOut.get_width() || gid.y >= rgbOut.get_height()) return;
    int x = int(gid.x), y = int(gid.y);

    float4 centre = rcdRead4(rgbIn, x, y);
    uint8_t colour = cfaColorRGB(cfaPattern, gid.x, gid.y);

    if (colour == 1) {
        rgbOut.write(centre, gid);   // green sites handled in the next pass
        return;
    }

    // The channel to fill in: red at a blue site, blue at a red site.
    uint c = (colour == 0) ? 2u : 0u;
    float green = centre.g;

    float pqCentre = rcdRead(pqDir, x, y);
    float pqNeighbourhood = 0.25f * (rcdReadPQDir(pqDir, x - 1, y - 1) + rcdReadPQDir(pqDir, x + 1, y - 1)
                                      + rcdReadPQDir(pqDir, x - 1, y + 1) + rcdReadPQDir(pqDir, x + 1, y + 1));
    float pqDisc = abs(0.5f - pqCentre) < abs(0.5f - pqNeighbourhood)
                 ? pqNeighbourhood : pqCentre;

    float nw = rcdChannel(rgbIn, x - 1, y - 1, c);
    float ne = rcdChannel(rgbIn, x + 1, y - 1, c);
    float sw = rcdChannel(rgbIn, x - 1, y + 1, c);
    float se = rcdChannel(rgbIn, x + 1, y + 1, c);

    float nwGrad = kRCDEps + abs(nw - se) + abs(nw - rcdChannel(rgbIn, x - 3, y - 3, c))
                 + abs(green - rcdChannel(rgbIn, x - 2, y - 2, 1u));
    float neGrad = kRCDEps + abs(ne - sw) + abs(ne - rcdChannel(rgbIn, x + 3, y - 3, c))
                 + abs(green - rcdChannel(rgbIn, x + 2, y - 2, 1u));
    float swGrad = kRCDEps + abs(ne - sw) + abs(sw - rcdChannel(rgbIn, x - 3, y + 3, c))
                 + abs(green - rcdChannel(rgbIn, x - 2, y + 2, 1u));
    float seGrad = kRCDEps + abs(nw - se) + abs(se - rcdChannel(rgbIn, x + 3, y + 3, c))
                 + abs(green - rcdChannel(rgbIn, x + 2, y + 2, 1u));

    // Colour differences at the four diagonal neighbours.
    float nwEst = nw - rcdChannel(rgbIn, x - 1, y - 1, 1u);
    float neEst = ne - rcdChannel(rgbIn, x + 1, y - 1, 1u);
    float swEst = sw - rcdChannel(rgbIn, x - 1, y + 1, 1u);
    float seEst = se - rcdChannel(rgbIn, x + 1, y + 1, 1u);

    float pEst = (nwGrad * seEst + seGrad * nwEst) / (nwGrad + seGrad);
    float qEst = (neGrad * swEst + swGrad * neEst) / (neGrad + swGrad);

    float3 out = centre.rgb;
    out[c] = green + rcdIntp(pqDisc, qEst, pEst);
    rgbOut.write(float4(out, 1.0f), gid);
}

// ---------------------------------------------------------------------
// Step 4.3: red and blue at green sites.
//
// Back to vertical/horizontal, because from a green site the nearest red
// and blue samples lie along the axes. Both channels are filled here, again
// working on differences against green.
// ---------------------------------------------------------------------
kernel void rcdRedBlueAtGreen(
    texture2d<float, access::read>  rgbIn   [[texture(0)]],
    texture2d<float, access::read>  vhDir   [[texture(1)]],
    texture2d<float, access::write> rgbOut  [[texture(2)]],
    constant uint8_t &cfaPattern            [[buffer(0)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    if (gid.x >= rgbOut.get_width() || gid.y >= rgbOut.get_height()) return;
    int x = int(gid.x), y = int(gid.y);

    float4 centre = rcdRead4(rgbIn, x, y);
    uint8_t colour = cfaColorRGB(cfaPattern, gid.x, gid.y);

    if (colour != 1) {
        rgbOut.write(centre, gid);   // already complete
        return;
    }

    float green = centre.g;

    float vhCentre = rcdRead(vhDir, x, y);
    float vhNeighbourhood = 0.25f * ((rcdRead(vhDir, x - 1, y - 1) + rcdRead(vhDir, x + 1, y - 1))
                                      + (rcdRead(vhDir, x - 1, y + 1) + rcdRead(vhDir, x + 1, y + 1)));
    float vhDisc = abs(0.5f - vhCentre) < abs(0.5f - vhNeighbourhood)
                 ? vhNeighbourhood : vhCentre;

    float n1 = kRCDEps + abs(green - rcdChannel(rgbIn, x, y - 2, 1u));
    float s1 = kRCDEps + abs(green - rcdChannel(rgbIn, x, y + 2, 1u));
    float w1 = kRCDEps + abs(green - rcdChannel(rgbIn, x - 2, y, 1u));
    float e1 = kRCDEps + abs(green - rcdChannel(rgbIn, x + 2, y, 1u));

    float greenN = rcdChannel(rgbIn, x, y - 1, 1u);
    float greenS = rcdChannel(rgbIn, x, y + 1, 1u);
    float greenW = rcdChannel(rgbIn, x - 1, y, 1u);
    float greenE = rcdChannel(rgbIn, x + 1, y, 1u);

    float3 out = centre.rgb;

    for (uint c = 0u; c <= 2u; c += 2u) {
        float cN = rcdChannel(rgbIn, x, y - 1, c);
        float cS = rcdChannel(rgbIn, x, y + 1, c);
        float cW = rcdChannel(rgbIn, x - 1, y, c);
        float cE = rcdChannel(rgbIn, x + 1, y, c);

        float snAbs = abs(cN - cS);
        float ewAbs = abs(cW - cE);

        float nGrad = n1 + snAbs + abs(cN - rcdChannel(rgbIn, x, y - 3, c));
        float sGrad = s1 + snAbs + abs(cS - rcdChannel(rgbIn, x, y + 3, c));
        float wGrad = w1 + ewAbs + abs(cW - rcdChannel(rgbIn, x - 3, y, c));
        float eGrad = e1 + ewAbs + abs(cE - rcdChannel(rgbIn, x + 3, y, c));

        float nEst = cN - greenN;
        float sEst = cS - greenS;
        float wEst = cW - greenW;
        float eEst = cE - greenE;

        float vEst = (nGrad * sEst + sGrad * nEst) / (nGrad + sGrad);
        float hEst = (eGrad * wEst + wGrad * eEst) / (eGrad + wGrad);

        out[c] = green + rcdIntp(vhDisc, hEst, vEst);
    }

    rgbOut.write(float4(out, 1.0f), gid);
}
