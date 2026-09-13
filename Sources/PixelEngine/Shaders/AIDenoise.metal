#include <metal_stdlib>
using namespace metal;

// Blends the neural denoiser's result into the camera-RGB stage.
//
// The denoised image is kept once, at full resolution and at the
// camera's own white balance, so it never has to be recomputed for a
// zoom, a pan or a white-balance change. This kernel adapts it to
// whatever the pipeline is rendering: `origin`/`span` pick the region
// and bin factor (box-averaging span×span texels, exactly like the
// binned demosaic does), `wbRatio` rescales each channel from as-shot
// to the current white balance (white balance is a per-channel gain in
// camera space, so this is exact), and `strength` mixes it in.
kernel void aiDenoiseBlend(
    texture2d<float, access::read>  camera    [[texture(0)]],   // this render's camera RGB
    texture2d<float, access::read>  denoised  [[texture(1)]],   // full-res, as-shot WB
    texture2d<float, access::write> output    [[texture(2)]],
    constant float &strength                  [[buffer(0)]],
    constant float4 &wbRatio                  [[buffer(1)]],
    constant uint2 &origin                    [[buffer(2)]],    // sensor px of output (0,0)
    constant uint &span                       [[buffer(3)]],    // sensor px per output px
    uint2 gid                                 [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    uint w = denoised.get_width(), h = denoised.get_height();
    float3 sum = 0.0; float n = 0.0;
    for (uint dy = 0; dy < span; dy++) {
        for (uint dx = 0; dx < span; dx++) {
            uint x = origin.x + gid.x * span + dx, y = origin.y + gid.y * span + dy;
            if (x < w && y < h) { sum += denoised.read(uint2(x, y)).rgb; n += 1.0; }
        }
    }
    float3 c = camera.read(gid).rgb;
    if (n > 0.0) {
        float3 d = (sum / n) * wbRatio.rgb;
        c = mix(c, d, strength);
    }
    output.write(float4(c, 1.0), gid);
}
