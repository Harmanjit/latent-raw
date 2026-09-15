#include <metal_stdlib>
using namespace metal;

// Photo Merge's panorama stitcher (docs/PhotoMerge.md section 4, stages 7
// and 8). MergePanoBlendKernels.swift encodes these; MergeKit/Pano/Blend
// decides what runs where.
//
// The stitch, in the order the kernels run:
// - `mergePanoBlendPremultiply` and `mergePanoBlendMipDown` get a prepared
//   frame ready: colour multiplied by alpha, then halved again and again (a
//   mip chain), so a sample can average as many pixels as it covers.
// - `mergePanoBlendWarp` looks up, for every panorama pixel, where it lands
//   in one frame (the projection maths of MergeKit/Pano/PanoramaAPI.swift,
//   mirrored exactly) and samples the frame there.
// - `mergePanoBlendLabel` picks each pixel's seam owner: the frame whose
//   optical axis points nearest to it (a Voronoi diagram on the sphere),
//   among the frames that cover the pixel.
// - `mergePanoBlendLog`, `mergePanoBlendReduceH`/`V`, `mergePanoBlendExpandFill`
//   and `mergePanoBlendCollapse` are the multi-band blend: a Laplacian
//   pyramid per frame in log(x + eps), each band blended with its own
//   softened copy of the seam masks, then added back together.
// - `mergePanoBlendFinish` turns the result back into linear light.
//
// Every name here starts with `mergePanoBlend`: the runtime compiler joins
// all shader files into one source, so names must be unique across them.

// MARK: - Shared layouts (MergePanoBlendKernels.swift mirrors these)

// One frame's placement, prepared on the CPU in double precision so the
// GPU's 32-bit floats only ever handle small numbers.
struct MergePanoBlendFrame {
    // xy: how much the local coordinates (a, b) change per level-0 output
    // pixel (1 / (output scale x pixels per radian)).
    float4 unitsPerPixel;
    // x: focal length, yz: principal point (full-resolution pixels);
    // w: prepared pixels per full-resolution pixel.
    float4 camera;
    // xy: the prepared frame's size; z: exposure gain; w: mip level count.
    float4 frame;
    // xy: the first block (level-0 output pixel >> blockShift); zw: how
    // many blocks across and down the frame's `MergePanoBlendBlock`s cover.
    int4 blocks;
    // x: projection (0 perspective, 1 cylindrical, 2 spherical); y: the
    // frame's position in the layout (its seam label); z: blockShift.
    int4 info;
};

// The mapping near one block of output pixels (512 x 512 at level 0).
struct MergePanoBlendBlock {
    // Columns 0 to 2: turn a pixel's local direction (see
    // `mergePanoBlendMap`) into its ray in the camera's axes; column 3: the
    // anchor's ray, scaled so its z is 1, with w 0 if the anchor is behind
    // the camera (the block then maps nowhere).
    float4x4 matrix;
    // xy: the cosine and sine of the anchor's tilt; zw: the anchor's frame
    // pixel, full-resolution pixels from the principal point.
    float4 tilt;
    // xy: the anchor, the block's centre pixel (level-0 output pixels).
    int4 anchor;
};

// Where a kernel's destination sits on the panorama.
struct MergePanoBlendGrid {
    // xy: global coordinates, in this grid's pixels, of the destination's
    // pixel (0, 0); zw: how many pixels to process.
    int4 origin;
    // xy: the panorama's size in this grid's pixels; z: the grid's step,
    // level-0 output pixels per grid pixel (1, 2, 4, ...).
    int4 canvas;
};

// Three textures' placements for the pyramid kernels, each as
// (origin x, origin y, width, height) in global pixels of its level.
struct MergePanoBlendLevel {
    int4 fine;
    int4 coarse;
    int4 accumulator;
};

// MARK: - Projection

// Sine and versine (1 - cosine) by their Taylor series, to the 15th and
// 16th power in Horner form: exact to about 1e-10 for |x| <= 1.6, beyond
// which the built-in functions take over. Two reasons. The GPU's own sin
// and cos are only good to about 1e-7, which at a focal length of 8,000 px
// moves a sample by 1e-3 px. And 1 - cos(x) for a small x, computed as
// such, loses most of its digits; the series keeps them.
inline float mergePanoBlendSin(float x) {
    if (abs(x) > 1.6) return sin(x);
    float x2 = x * x;
    return x * (1.0 - x2 / 6.0 * (1.0 - x2 / 20.0 * (1.0 - x2 / 42.0 * (1.0 - x2 / 72.0 * (1.0 - x2 / 110.0
        * (1.0 - x2 / 156.0 * (1.0 - x2 / 210.0)))))));
}

inline float mergePanoBlendVersine(float x) {
    if (abs(x) > 1.6) return 1.0 - cos(x);
    float x2 = x * x;
    return x2 / 2.0 * (1.0 - x2 / 12.0 * (1.0 - x2 / 30.0 * (1.0 - x2 / 56.0 * (1.0 - x2 / 90.0
        * (1.0 - x2 / 132.0 * (1.0 - x2 / 182.0 * (1.0 - x2 / 240.0)))))));
}

// The ray, in the camera's axes, that grid pixel (gx, gy) sees.
//
// A pixel's centre sits at level-0 output coordinate (g + 0.5) * step, and
// canvas pixel (that / output scale), so it shows projected point
// canvas + origin. Rather than rebuild those large numbers, the kernel
// counts from the anchor of the 512 x 512 block of output pixels the pixel
// is in: u = output pixels from the anchor's centre (a whole number, exact
// in a float, plus a half-step, never more than about 260), and the local
// coordinates are a = u * unitsPerPixel.x, likewise b. The pixel's ray is
// then a small change from the anchor's ray, which the CPU works out in
// double precision (column 3 of the block's matrix):
//
// - Perspective: (a, b) is the change in projected point / pixels per
//   radian; the ray is a * column 0 + b * column 1 + column 3.
// - Cylindrical: a is longitude from the anchor's, b height (projected y /
//   pixels per radian) from the anchor's. With the anchor's direction
//   tilted up by phi = atan(anchor height) (tilt.xy = cos, sin), the
//   direction (sin a, height, cos a), turned back by phi, is
//   (sin a, b cos phi + vers a sin phi, sec phi + b sin phi - vers a cos phi),
//   whose sec phi part is folded into column 3.
// - Spherical: a as above, b latitude (downwards) from the anchor's, phi.
//   With L the latitude, the direction (cos L sin a, sin L, cos L cos a)
//   turned back by phi is (cos L sin a, sin b + sin phi cos L vers a,
//   1 - vers b - cos phi cos L vers a), its 1 folded into column 3.
//
// The frame pixel is then the anchor's (tilt.zw, worked out on the CPU)
// plus a correction from the small change d = ray - anchor ray (whose z is
// 1): f (anchor.xy + d.xy) / (1 + d.z) - f anchor.xy
//   = f (d.xy - anchor.xy d.z) / (1 + d.z).
//
// Why all this: a 32-bit float holding an angle of 0.4 rad, or a ray
// component of 0.36, is only good to about 2e-8, which is 2e-4 px at a
// focal length of 8,000 px, and whole-frame maths needs several such
// numbers (absolute canvas coordinates on a 40,000 px panorama alone would
// be 4e-3 px coarse). From a nearby anchor every float is small or only
// multiplied, and the frame pixel stays within a few 1e-4 px of
// PanoramaMath's (PanoBlendMappingTests). Blocks are fixed on the output,
// so a pixel maps the same way whichever tile it is in.
//
// `pixel` is in full-resolution pixels from the principal point; `ray` is
// the pixel's ray. Returns false behind the camera and outside the frame's
// blocks.
inline bool mergePanoBlendMap(const MergePanoBlendFrame f, constant MergePanoBlendBlock *blocks,
                              int gx, int gy, int step, thread float2 &pixel, thread float3 &ray) {
    int x = gx * step, y = gy * step;
    int bx = (x >> f.info.z) - f.blocks.x, by = (y >> f.info.z) - f.blocks.y;
    if (bx < 0 || by < 0 || bx >= f.blocks.z || by >= f.blocks.w) return false;
    const MergePanoBlendBlock block = blocks[by * f.blocks.z + bx];
    if (block.matrix[3].w == 0.0) return false;
    float halfStep = 0.5 * float(step) - 0.5;
    float a = (float(x - block.anchor.x) + halfStep) * f.unitsPerPixel.x;
    float b = (float(y - block.anchor.y) + halfStep) * f.unitsPerPixel.y;
    float cosPhi = block.tilt.x, sinPhi = block.tilt.y;
    float3 local;
    if (f.info.x == 0) {
        local = float3(a, b, 0.0);
    } else if (f.info.x == 1) {
        float va = mergePanoBlendVersine(a);
        local = float3(mergePanoBlendSin(a), b * cosPhi + va * sinPhi, b * sinPhi - va * cosPhi);
    } else {
        float va = mergePanoBlendVersine(a), vb = mergePanoBlendVersine(b), sb = mergePanoBlendSin(b);
        float cosLatitude = cosPhi * (1.0 - vb) - sinPhi * sb;
        local = float3(cosLatitude * mergePanoBlendSin(a), sb + sinPhi * cosLatitude * va,
                       -vb - cosPhi * cosLatitude * va);
    }
    float3 change = block.matrix[0].xyz * local.x + block.matrix[1].xyz * local.y + block.matrix[2].xyz * local.z;
    float3 anchorRay = block.matrix[3].xyz;
    ray = anchorRay + change;
    if (!(ray.z > 1e-6 * length(ray))) return false;
    pixel = block.tilt.zw + f.camera.x * (change.xy - anchorRay.xy * change.z) / (1.0 + change.z);
    return true;
}

// MARK: - Frame preparation

// Colour times alpha, in place. A premultiplied frame can be averaged and
// interpolated like any image: a pixel half inside the frame then counts
// half, instead of dragging its (meaningless) outside colour in at full
// weight. Negative and NaN colours become 0.
kernel void mergePanoBlendPremultiply(
    texture2d<float, access::read_write> frame [[texture(0)]],
    uint2 gid                                   [[thread_position_in_grid]])
{
    if (gid.x >= frame.get_width() || gid.y >= frame.get_height()) return;
    float4 p = frame.read(gid);
    float a = clamp(p.a, 0.0, 1.0);
    a = isnan(p.a) ? 0.0 : a;
    float3 rgb = max(p.rgb, float3(0.0));
    rgb = select(rgb, float3(0.0), isnan(p.rgb));
    frame.write(float4(rgb * a, a), gid);
}

// One mip level from the one above: each pixel the mean of the 2 x 2 it
// covers (on premultiplied data, so coverage is averaged too). Mip sizes
// round down, so an odd width's last column has no pixel below it.
kernel void mergePanoBlendMipDown(
    texture2d<float, access::read> larger   [[texture(0)]],
    texture2d<float, access::write> smaller [[texture(1)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    if (gid.x >= smaller.get_width() || gid.y >= smaller.get_height()) return;
    uint2 p = gid * 2;
    float4 sum = larger.read(p) + larger.read(p + uint2(1, 0)) + larger.read(p + uint2(0, 1))
        + larger.read(p + uint2(1, 1));
    smaller.write(0.25 * sum, gid);
}

// MARK: - Warping

// Catmull-Rom weights for the four samples around a point a fraction `t`
// past the second one (the same cubic as MergeWarp.metal: sharp, and exact
// at whole-pixel positions).
inline float4 mergePanoBlendCatmullRom(float t) {
    float t2 = t * t, t3 = t2 * t;
    return float4(-0.5 * t3 + t2 - 0.5 * t,
                  1.5 * t3 - 2.5 * t2 + 1.0,
                  -1.5 * t3 + 2.0 * t2 + 0.5 * t,
                  0.5 * t3 - 0.5 * t2);
}

// A Catmull-Rom sample of mip level `level` at level-0 prepared pixel `p`.
// Taps outside the frame count as transparent black, not as copies of the
// edge: coverage then fades out across the frame's border like the colour.
inline float4 mergePanoBlendSample(texture2d<float, access::read> frame, uint level, float2 p) {
    int width = int(frame.get_width(level)), height = int(frame.get_height(level));
    float2 index = p / float(1u << level) - 0.5;
    float2 base = floor(index);
    float4 wx = mergePanoBlendCatmullRom(index.x - base.x), wy = mergePanoBlendCatmullRom(index.y - base.y);
    int bx = int(base.x), by = int(base.y);
    float4 sum = float4(0.0);
    for (int j = 0; j < 4; j++) {
        int row = by - 1 + j;
        if (row < 0 || row >= height) continue;
        float4 rowSum = float4(0.0);
        for (int i = 0; i < 4; i++) {
            int column = bx - 1 + i;
            if (column < 0 || column >= width) continue;
            rowSum += wx[i] * frame.read(uint2(column, row), level);
        }
        sum += wy[j] * rowSum;
    }
    return sum;
}

// One frame, warped onto a patch of the panorama's grid (a tile at level 0,
// or the whole panorama at a coarse level).
//
// For each destination pixel: the frame pixel it lands on, and the
// footprint, how many prepared pixels one grid step spans there (from the
// neighbours' landing points). The frame is sampled with Catmull-Rom on the
// mip level matching the footprint, blending the two nearest levels (like
// trilinear filtering), so shrinking a frame averages all the pixels an
// output pixel covers instead of skipping some and aliasing.
//
// Writes straight colour times the exposure gain, and coverage in alpha
// (0 outside the frame and outside the panorama, where colour is 0 too).
// The cubic's overshoot can make colour negative next to an edge: negative
// light doesn't exist, so it is clamped to 0.
kernel void mergePanoBlendWarp(
    texture2d<float, access::read> frame   [[texture(0)]],
    texture2d<float, access::write> warped [[texture(1)]],
    constant MergePanoBlendFrame &f        [[buffer(0)]],
    constant MergePanoBlendGrid &grid      [[buffer(1)]],
    constant MergePanoBlendBlock *blocks   [[buffer(3)]],
    uint2 gid                              [[thread_position_in_grid]])
{
    if (gid.x >= uint(grid.origin.z) || gid.y >= uint(grid.origin.w)) return;
    int gx = int(gid.x) + grid.origin.x, gy = int(gid.y) + grid.origin.y, step = grid.canvas.z;
    float3 ray;
    float2 pixel;
    if (gx < 0 || gy < 0 || gx >= grid.canvas.x || gy >= grid.canvas.y
        || !mergePanoBlendMap(f, blocks, gx, gy, step, pixel, ray)) {
        warped.write(float4(0.0), gid);
        return;
    }
    float sampleScale = f.camera.w;
    float2 p = (pixel + f.camera.yz) * sampleScale;

    // Far outside the frame: skip the footprint and the sample (both
    // would find nothing).
    uint maxLevel = uint(max(f.frame.w, 1.0)) - 1;
    float farReach = 2.0 * float(1u << maxLevel) + 1.0;
    if (!(p.x > -farReach && p.y > -farReach && p.x < f.frame.x + farReach && p.y < f.frame.y + farReach)) {
        warped.write(float4(0.0), gid);
        return;
    }

    float footprint = 0.0;
    float3 neighbourRay;
    float2 neighbour;
    if (mergePanoBlendMap(f, blocks, gx + 1, gy, step, neighbour, neighbourRay)) {
        footprint = max(footprint, distance(neighbour, pixel) * sampleScale);
    }
    if (mergePanoBlendMap(f, blocks, gx, gy + 1, step, neighbour, neighbourRay)) {
        footprint = max(footprint, distance(neighbour, pixel) * sampleScale);
    }
    float lambda = footprint > 1.0 ? min(log2(footprint), float(maxLevel)) : 0.0;
    uint level = uint(floor(lambda));
    float t = lambda - float(level);

    // Two taps at the coarser level reach this far past the frame's edge.
    float reach = 2.0 * float(1u << min(level + 1, maxLevel)) + 1.0;
    if (!(p.x > -reach && p.y > -reach && p.x < f.frame.x + reach && p.y < f.frame.y + reach)) {
        warped.write(float4(0.0), gid);
        return;
    }
    float4 s = mergePanoBlendSample(frame, level, p);
    if (t > 0.0 && level < maxLevel) s = mix(s, mergePanoBlendSample(frame, level + 1, p), t);
    // Below a thousandth of coverage the colour (s / coverage) is mostly
    // rounding; count the pixel as uncovered.
    if (!(s.a > 1e-3)) {
        warped.write(float4(0.0), gid);
        return;
    }
    float3 rgb = max(s.rgb / s.a, float3(0.0)) * f.frame.z;
    rgb = min(select(rgb, float3(0.0), isnan(rgb)), float3(60000.0));
    warped.write(float4(rgb, min(s.a, 1.0)), gid);
}

// Debugging and tests: where each grid pixel lands in the frame, in
// full-resolution pixels from the principal point (xy), 1 in z where the
// ray is in front of the camera, and the footprint in prepared pixels in w.
kernel void mergePanoBlendMapDebug(
    texture2d<float, access::write> mapped [[texture(0)]],
    constant MergePanoBlendFrame &f        [[buffer(0)]],
    constant MergePanoBlendGrid &grid      [[buffer(1)]],
    constant MergePanoBlendBlock *blocks   [[buffer(3)]],
    uint2 gid                              [[thread_position_in_grid]])
{
    if (gid.x >= uint(grid.origin.z) || gid.y >= uint(grid.origin.w)) return;
    int gx = int(gid.x) + grid.origin.x, gy = int(gid.y) + grid.origin.y, step = grid.canvas.z;
    float3 ray, neighbourRay;
    float2 p, neighbour;
    if (!mergePanoBlendMap(f, blocks, gx, gy, step, p, ray)) {
        mapped.write(float4(0.0), gid);
        return;
    }
    float footprint = 0.0;
    if (mergePanoBlendMap(f, blocks, gx + 1, gy, step, neighbour, neighbourRay)) {
        footprint = max(footprint, distance(neighbour, p) * f.camera.w);
    }
    if (mergePanoBlendMap(f, blocks, gx, gy + 1, step, neighbour, neighbourRay)) {
        footprint = max(footprint, distance(neighbour, p) * f.camera.w);
    }
    mapped.write(float4(p, 1.0, footprint), gid);
}

// MARK: - Seams

// Fills `size` pixels of a texture with one value.
kernel void mergePanoBlendClear(
    texture2d<float, access::write> target [[texture(0)]],
    constant float4 &value                 [[buffer(0)]],
    constant int4 &size                    [[buffer(1)]],
    uint2 gid                              [[thread_position_in_grid]])
{
    if (gid.x >= uint(size.x) || gid.y >= uint(size.y)) return;
    target.write(value, gid);
}

// Offers one frame's pixels to the seam labels, frame by frame in layout
// order. `best` holds, per pixel: r the best score so far (below 0: none),
// g the owning frame's position, b the largest coverage of any frame.
//
// The score is the cosine of the angle between the pixel's direction and
// the frame's optical axis (ray.z over its length: the nearest axis wins,
// which is a Voronoi diagram on the sphere), plus 8 where the frame covers
// the pixel fully and 4 where it only partly does (its border's soft
// edge). So a frame that really covers a pixel always beats one whose edge
// merely reaches it, and a pixel no frame covers gets no owner. Ties keep
// the earlier frame, in every tile alike.
//
// The warped patch sits at `grid` on the panorama; `best` at `bestPlace`
// (origin x, origin y, width, height in global pixels of the same level).
kernel void mergePanoBlendLabel(
    texture2d<float, access::read> warped     [[texture(0)]],
    texture2d<float, access::read_write> best [[texture(1)]],
    constant MergePanoBlendFrame &f           [[buffer(0)]],
    constant MergePanoBlendGrid &grid         [[buffer(1)]],
    constant int4 &bestPlace                  [[buffer(2)]],
    constant MergePanoBlendBlock *blocks      [[buffer(3)]],
    uint2 gid                                 [[thread_position_in_grid]])
{
    if (gid.x >= uint(grid.origin.z) || gid.y >= uint(grid.origin.w)) return;
    int gx = int(gid.x) + grid.origin.x, gy = int(gid.y) + grid.origin.y;
    int bx = gx - bestPlace.x, by = gy - bestPlace.y;
    if (bx < 0 || by < 0 || bx >= bestPlace.z || by >= bestPlace.w) return;
    float coverage = warped.read(gid).a;
    if (!(coverage > 0.0)) return;
    float3 ray;
    float2 pixel;
    if (!mergePanoBlendMap(f, blocks, gx, gy, grid.canvas.z, pixel, ray)) return;
    float score = (coverage >= 0.999 ? 8.0 : 4.0) + ray.z / length(ray);
    uint2 b = uint2(bx, by);
    float4 current = best.read(b);
    if (score > current.r) {
        best.write(float4(score, float(f.info.y), max(current.b, coverage), 0.0), b);
    } else if (coverage > current.b) {
        best.write(float4(current.r, current.g, coverage, 0.0), b);
    }
}

// MARK: - Multi-band blend

// A warped frame into the blend's working form: log(colour + eps) in rgb
// and coverage in alpha (`pyramid`), and the frame's seam mask, 1 where it
// owns the pixel (`weight`).
//
// Why log: exposure differences left between frames are ratios, and a
// ratio becomes an offset in log space, which the coarse bands spread
// smoothly across the overlap. Blending linear values instead lets a
// bright frame's coarse band lift a dark frame's shadows into a halo.
// eps (about 1e-3 of the clip level) keeps log finite at black and stops
// noise in the deepest shadows from dominating.
//
// The patch sits at `grid`; `best` at `bestPlace`. params: x eps, y the
// frame's position.
kernel void mergePanoBlendLog(
    texture2d<float, access::read> warped   [[texture(0)]],
    texture2d<float, access::read> best     [[texture(1)]],
    texture2d<float, access::write> pyramid [[texture(2)]],
    texture2d<float, access::write> weight  [[texture(3)]],
    constant MergePanoBlendGrid &grid       [[buffer(0)]],
    constant int4 &bestPlace                [[buffer(1)]],
    constant float4 &params                 [[buffer(2)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    if (gid.x >= uint(grid.origin.z) || gid.y >= uint(grid.origin.w)) return;
    float4 w = warped.read(gid);
    pyramid.write(float4(log(max(w.rgb, float3(0.0)) + params.x), w.a), gid);
    int bx = int(gid.x) + grid.origin.x - bestPlace.x, by = int(gid.y) + grid.origin.y - bestPlace.y;
    float owned = 0.0;
    if (bx >= 0 && by >= 0 && bx < bestPlace.z && by < bestPlace.w) {
        float4 label = best.read(uint2(bx, by));
        owned = (label.r > 0.0 && label.g == params.y) ? 1.0 : 0.0;
    }
    weight.write(float4(owned, 0.0, 0.0, 0.0), gid);
}

// The pyramid's reduce filter: binomial [1 5 10 10 5 1] / 32. Coarse pixel
// j covers fine pixels 2j and 2j + 1, so the six taps are 2j - 2 ... 2j + 3,
// centred on the pair. It is smoother than the classic five-tap filter
// (less aliasing into the coarse bands), and its mirror image, the expand
// below, needs only three taps.
constant float mergePanoBlendReduceWeights[6] = {1.0 / 32.0, 5.0 / 32.0, 10.0 / 32.0, 10.0 / 32.0, 5.0 / 32.0, 1.0 / 32.0};

// Horizontal half of a reduce. `source` and `destination` are placed as
// (origin x, origin y, width, height) in global pixels; the destination's
// columns are one level coarser, its rows the same. Pixels beyond the
// source count as 0: nothing of the panorama lies past a patch's real edge,
// and inside a tile the apron keeps the difference away from kept pixels.
//
// mode 0 (colour, rgb + coverage): sums coverage-weighted colour and
//   coverage, which the vertical half divides out. This is normalised
//   convolution: pixels a frame doesn't cover don't pull its colour
//   towards black.
// mode 1 (plain, weights): sums the values.
kernel void mergePanoBlendReduceH(
    texture2d<float, access::read> source       [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant int4 &sourcePlace                  [[buffer(0)]],
    constant int4 &destinationPlace             [[buffer(1)]],
    constant uint &mode                         [[buffer(2)]],
    uint2 gid                                   [[thread_position_in_grid]])
{
    if (gid.x >= uint(destinationPlace.z) || gid.y >= uint(destinationPlace.w)) return;
    int j = int(gid.x) + destinationPlace.x;
    int row = int(gid.y) + destinationPlace.y - sourcePlace.y;
    float4 sum = float4(0.0);
    if (row >= 0 && row < sourcePlace.w) {
        for (int m = 0; m < 6; m++) {
            int x = 2 * j - 2 + m - sourcePlace.x;
            if (x < 0 || x >= sourcePlace.z) continue;
            float4 v = source.read(uint2(x, row));
            sum += mergePanoBlendReduceWeights[m] * (mode == 0 ? float4(v.rgb * v.a, v.a) : v);
        }
    }
    destination.write(sum, gid);
}

// Vertical half of a reduce: rows one level coarser. In mode 0 the colour
// is divided by the coverage summed with it, leaving the coverage-weighted
// mean colour and the mean coverage (0 colour where nothing covers).
kernel void mergePanoBlendReduceV(
    texture2d<float, access::read> source       [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant int4 &sourcePlace                  [[buffer(0)]],
    constant int4 &destinationPlace             [[buffer(1)]],
    constant uint &mode                         [[buffer(2)]],
    uint2 gid                                   [[thread_position_in_grid]])
{
    if (gid.x >= uint(destinationPlace.z) || gid.y >= uint(destinationPlace.w)) return;
    int j = int(gid.y) + destinationPlace.y;
    int column = int(gid.x) + destinationPlace.x - sourcePlace.x;
    float4 sum = float4(0.0);
    if (column >= 0 && column < sourcePlace.z) {
        for (int m = 0; m < 6; m++) {
            int y = 2 * j - 2 + m - sourcePlace.y;
            if (y < 0 || y >= sourcePlace.w) continue;
            sum += mergePanoBlendReduceWeights[m] * source.read(uint2(column, y));
        }
    }
    if (mode == 0) {
        sum = sum.a > 1e-12 ? float4(sum.rgb / sum.a, sum.a) : float4(0.0);
    }
    destination.write(sum, gid);
}

// The expand filter at global fine pixel (i, j): the mirror image of the
// reduce, reading coarse pixels m - 1, m, m + 1 (m = i / 2) with weights
// (5, 10, 1) / 16 for an even i and (1, 10, 5) / 16 for an odd one, each
// axis. Reads beyond the coarse texture repeat its edge.
inline float3 mergePanoBlendExpand(texture2d<float, access::read> coarse, int4 place, int i, int j) {
    float3 wx = (i & 1) == 0 ? float3(5.0, 10.0, 1.0) : float3(1.0, 10.0, 5.0);
    float3 wy = (j & 1) == 0 ? float3(5.0, 10.0, 1.0) : float3(1.0, 10.0, 5.0);
    int mx = (i >> 1) - place.x, my = (j >> 1) - place.y;
    float3 sum = float3(0.0);
    for (int dy = -1; dy <= 1; dy++) {
        int y = clamp(my + dy, 0, place.w - 1);
        float3 rowSum = float3(0.0);
        for (int dx = -1; dx <= 1; dx++) {
            int x = clamp(mx + dx, 0, place.z - 1);
            rowSum += wx[dx + 1] * coarse.read(uint2(x, y)).rgb;
        }
        sum += wy[dy + 1] * rowSum;
    }
    return sum / 256.0;
}

// One level of one frame's Laplacian pyramid, added into the blend.
//
// `pyramid` holds the frame's Gaussian level (mean log colour, coverage)
// and is overwritten with the filled level F: where the frame covers the
// pixel its own value, where it doesn't the coarser level's prediction
// E = expand(coarser F), mixing over a soft edge (trust = saturate(4 x
// coverage)). Filling ("push-pull") continues the frame smoothly past its
// border, so its detail bands, L = F - E, are 0 outside the frame instead
// of holding a cliff down to black that the blend would smear inwards.
//
// Then adds weight x L and weight into `accumulator` (rgb and alpha), where
// the weight (the frame's seam mask, reduced to this level) is above 0.
//
// mode 0: an ordinary level, E from `coarse`. mode 1: the coarsest level,
// where E is the frame's mean log colour (params.rgb) and the band is F
// itself.
kernel void mergePanoBlendExpandFill(
    texture2d<float, access::read_write> pyramid     [[texture(0)]],
    texture2d<float, access::read> weight            [[texture(1)]],
    texture2d<float, access::read> coarse            [[texture(2)]],
    texture2d<float, access::read_write> accumulator [[texture(3)]],
    constant MergePanoBlendLevel &place              [[buffer(0)]],
    constant float4 &params                          [[buffer(1)]],
    constant uint &mode                              [[buffer(2)]],
    uint2 gid                                        [[thread_position_in_grid]])
{
    if (gid.x >= uint(place.fine.z) || gid.y >= uint(place.fine.w)) return;
    int i = int(gid.x) + place.fine.x, j = int(gid.y) + place.fine.y;
    float4 g = pyramid.read(gid);
    float3 e = mode == 0 ? mergePanoBlendExpand(coarse, place.coarse, i, j) : params.rgb;
    float trust = saturate(4.0 * g.a);
    float3 filled = trust * g.rgb + (1.0 - trust) * e;
    pyramid.write(float4(filled, g.a), gid);

    float w = weight.read(gid).r;
    int ax = i - place.accumulator.x, ay = j - place.accumulator.y;
    if (w > 0.0 && ax >= 0 && ay >= 0 && ax < place.accumulator.z && ay < place.accumulator.w) {
        float3 band = mode == 0 ? filled - e : filled;
        uint2 a = uint2(ax, ay);
        accumulator.write(accumulator.read(a) + float4(w * band, w), a);
    }
}

// Collapses one level of the blended pyramid, in place: the weighted mean
// band (sum of w x L over sum of w) plus the expanded coarser result.
// Where no frame's weight reaches, the band is 0, so the result there is
// the coarser level's smooth continuation. mode 1 is the coarsest level:
// nothing coarser, and uncovered pixels take `fill` (the mean result).
kernel void mergePanoBlendCollapse(
    texture2d<float, access::read_write> accumulator [[texture(0)]],
    texture2d<float, access::read> coarse            [[texture(1)]],
    constant MergePanoBlendLevel &place              [[buffer(0)]],
    constant float4 &fill                            [[buffer(1)]],
    constant uint &mode                              [[buffer(2)]],
    uint2 gid                                        [[thread_position_in_grid]])
{
    if (gid.x >= uint(place.fine.z) || gid.y >= uint(place.fine.w)) return;
    float4 sum = accumulator.read(gid);
    float3 band = sum.a > 0.0 ? sum.rgb / sum.a : (mode == 0 ? float3(0.0) : fill.rgb);
    if (mode == 0) {
        band += mergePanoBlendExpand(coarse, place.coarse, int(gid.x) + place.fine.x, int(gid.y) + place.fine.y);
    }
    accumulator.write(float4(band, sum.a), gid);
}

// The blended log colour back to linear light, with the panorama's coverage
// (the largest of any frame's) as alpha; black where nothing covers.
// `region`: xy the output's offset inside the collapsed and label textures,
// zw its size. params: x eps.
kernel void mergePanoBlendFinish(
    texture2d<float, access::read> collapsed [[texture(0)]],
    texture2d<float, access::read> best      [[texture(1)]],
    texture2d<float, access::write> output   [[texture(2)]],
    constant int4 &region                    [[buffer(0)]],
    constant float4 &params                  [[buffer(1)]],
    uint2 gid                                [[thread_position_in_grid]])
{
    if (gid.x >= uint(region.z) || gid.y >= uint(region.w)) return;
    uint2 source = gid + uint2(region.xy);
    float coverage = best.read(source).b;
    if (!(coverage > 0.0)) {
        output.write(float4(0.0), gid);
        return;
    }
    float3 rgb = exp(collapsed.read(source).rgb) - params.x;
    rgb = clamp(select(rgb, float3(0.0), isnan(rgb)), float3(0.0), float3(60000.0));
    output.write(float4(rgb, min(coverage, 1.0)), gid);
}
