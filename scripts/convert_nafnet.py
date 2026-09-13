#!/usr/bin/env python3
"""
Converts NAFNet (SIDD, width 32) from the published PyTorch weights into a
Core ML package for Latent's AI noise reduction.

    source ~/rawhead-ml/bin/activate     # or wherever the venv lives
    python scripts/convert_nafnet.py

NAFNet ("Simple Baselines for Image Restoration", Chen et al. 2022, MIT
licence) is a plain convolutional U-Net with a "simple gate" in place of
activations. Trained on SIDD, real smartphone noise, it is among the
best published real-noise denoisers and, being pure convolutions, it
converts to Core ML cleanly and runs well on Apple GPUs.

The architecture is re-implemented here (about 80 lines) rather than
imported, so the conversion has no dependency on the original repo's
training framework. The state dict is loaded strictly, so any mismatch
with the published layout fails loudly.

Output: Sources/MLKit/Resources/Models/NAFNet_SIDD_width32.mlpackage
Input:  "image"  1x3x256x256 float, sRGB-like values in [0, 1]
Output: "denoised" 1x3x256x256
"""
import os
import sys
import time

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
import coremltools as ct
from huggingface_hub import hf_hub_download

import argparse
_args = argparse.ArgumentParser()
_args.add_argument("--width", type=int, default=32, help="32 (bundled) or 64 (optional download)")
_args.add_argument("--out", default=None, help="output directory (default: the bundled Models folder)")
ARGS = _args.parse_args()

TILE = 256
WIDTH = ARGS.width
ENC_BLKS = [2, 2, 4, 8]
MID_BLKS = 12
DEC_BLKS = [2, 2, 2, 2]
OUT_DIR = ARGS.out or os.path.join(os.path.dirname(__file__), "..", "Sources", "MLKit", "Resources", "Models")
PACKAGE = f"NAFNet_SIDD_width{WIDTH}.mlpackage"


class LayerNorm2d(nn.Module):
    """LayerNorm over channels, per pixel (the NAFNet layout)."""
    def __init__(self, channels, eps=1e-6):
        super().__init__()
        self.weight = nn.Parameter(torch.ones(channels))
        self.bias = nn.Parameter(torch.zeros(channels))
        self.eps = eps

    def forward(self, x):
        mu = x.mean(1, keepdim=True)
        var = (x - mu).pow(2).mean(1, keepdim=True)
        y = (x - mu) / torch.sqrt(var + self.eps)
        return self.weight.view(1, -1, 1, 1) * y + self.bias.view(1, -1, 1, 1)


class SimpleGate(nn.Module):
    def forward(self, x):
        a, b = x.chunk(2, dim=1)
        return a * b


class NAFBlock(nn.Module):
    def __init__(self, c, dw_expand=2, ffn_expand=2):
        super().__init__()
        dw = c * dw_expand
        self.conv1 = nn.Conv2d(c, dw, 1)
        self.conv2 = nn.Conv2d(dw, dw, 3, padding=1, groups=dw)
        self.conv3 = nn.Conv2d(dw // 2, c, 1)
        self.sca = nn.Sequential(nn.AdaptiveAvgPool2d(1), nn.Conv2d(dw // 2, dw // 2, 1))
        self.sg = SimpleGate()
        ffn = c * ffn_expand
        self.conv4 = nn.Conv2d(c, ffn, 1)
        self.conv5 = nn.Conv2d(ffn // 2, c, 1)
        self.norm1 = LayerNorm2d(c)
        self.norm2 = LayerNorm2d(c)
        self.beta = nn.Parameter(torch.zeros(1, c, 1, 1))
        self.gamma = nn.Parameter(torch.zeros(1, c, 1, 1))

    def forward(self, inp):
        x = self.norm1(inp)
        x = self.conv1(x)
        x = self.conv2(x)
        x = self.sg(x)
        x = x * self.sca(x)
        x = self.conv3(x)
        y = inp + x * self.beta
        x = self.conv4(self.norm2(y))
        x = self.sg(x)
        x = self.conv5(x)
        return y + x * self.gamma


class NAFNet(nn.Module):
    def __init__(self, img_channel=3, width=WIDTH, middle_blk_num=MID_BLKS,
                 enc_blk_nums=ENC_BLKS, dec_blk_nums=DEC_BLKS):
        super().__init__()
        self.intro = nn.Conv2d(img_channel, width, 3, padding=1)
        self.ending = nn.Conv2d(width, img_channel, 3, padding=1)
        self.encoders = nn.ModuleList()
        self.decoders = nn.ModuleList()
        self.middle_blks = nn.ModuleList()
        self.ups = nn.ModuleList()
        self.downs = nn.ModuleList()
        chan = width
        for num in enc_blk_nums:
            self.encoders.append(nn.Sequential(*[NAFBlock(chan) for _ in range(num)]))
            self.downs.append(nn.Conv2d(chan, 2 * chan, 2, 2))
            chan *= 2
        self.middle_blks = nn.Sequential(*[NAFBlock(chan) for _ in range(middle_blk_num)])
        for num in dec_blk_nums:
            self.ups.append(nn.Sequential(nn.Conv2d(chan, chan * 2, 1, bias=False), nn.PixelShuffle(2)))
            chan //= 2
            self.decoders.append(nn.Sequential(*[NAFBlock(chan) for _ in range(num)]))
        self.padder_size = 2 ** len(self.encoders)

    def forward(self, inp):
        x = self.intro(inp)
        skips = []
        for enc, down in zip(self.encoders, self.downs):
            x = enc(x)
            skips.append(x)
            x = down(x)
        x = self.middle_blks(x)
        for dec, up, skip in zip(self.decoders, self.ups, skips[::-1]):
            x = up(x)
            x = x + skip
            x = dec(x)
        return self.ending(x) + inp


def main():
    print(f"Downloading NAFNet-SIDD-width{WIDTH}.pth (official weights, MIT)…")
    path = hf_hub_download("nyanko7/nafnet-models", f"NAFNet-SIDD-width{WIDTH}.pth")
    state = torch.load(path, map_location="cpu", weights_only=False)
    if "params" in state:
        state = state["params"]
    model = NAFNet()
    missing, unexpected = model.load_state_dict(state, strict=False)
    if missing or unexpected:
        print("State dict mismatch.\n  missing:", missing[:10], "\n  unexpected:", unexpected[:10])
        sys.exit(1)
    model.eval()

    # Sanity: a noisy flat patch should come out flatter.
    with torch.no_grad():
        clean = torch.full((1, 3, TILE, TILE), 0.5)
        noisy = (clean + 0.05 * torch.randn_like(clean)).clamp(0, 1)
        out = model(noisy)
        print(f"noise std in {noisy.std():.4f} -> out {out.std():.4f}")
        assert out.std() < noisy.std() * 0.5, "model did not denoise; wrong weights?"

    example = torch.rand(1, 3, TILE, TILE)
    traced = torch.jit.trace(model, example)
    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[ct.TensorType(name="image", shape=(1, 3, TILE, TILE), dtype=np.float32)],
        outputs=[ct.TensorType(name="denoised", dtype=np.float32)],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS15,
    )
    mlmodel.author = "Converted for Latent from official NAFNet weights (Chen et al. 2022, MIT)"
    mlmodel.short_description = f"NAFNet SIDD width{WIDTH} real-noise denoiser, 256x256 tiles"
    os.makedirs(OUT_DIR, exist_ok=True)
    out_path = os.path.join(OUT_DIR, PACKAGE)
    mlmodel.save(out_path)
    print("Saved", out_path)

    # Time it the way the app runs it (GPU; the ANE compiler hangs on
    # macOS 15.7 for some graphs, so the app defaults to CPU+GPU).
    m = ct.models.MLModel(out_path, compute_units=ct.ComputeUnit.CPU_AND_GPU)
    x = {"image": noisy.numpy()}
    m.predict(x)
    t = time.time()
    for _ in range(5):
        y = m.predict(x)["denoised"]
    per = (time.time() - t) / 5
    print(f"Core ML (CPU+GPU): {per * 1000:.0f} ms per 256x256 tile; out std {y.std():.4f}")
    print(f"≈ {per * 400:.0f} s for a 24 MP image at 400 tiles (before overlap)")


if __name__ == "__main__":
    main()
