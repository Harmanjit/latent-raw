#!/usr/bin/env python
"""
Convert a SegFormer semantic-segmentation model (ADE20K, 150 classes) from
Hugging Face into a Core ML package for Latent's MLKit.

    source ~/latent-ml/bin/activate
    python scripts/convert_segformer.py --model nvidia/segformer-b2-finetuned-ade-512-512 \
        --size 512 --out Sources/MLKit/Resources/Models

What it does, step by step:

1. Downloads the PyTorch weights and config from Hugging Face.
2. Wraps the model so its input is a plain RGB image (0-255) and the
   ImageNet normalisation the network expects happens *inside* the graph.
   That lets Core ML take a CVPixelBuffer directly and keeps Swift simple.
3. Applies softmax at the network's native 1/4 resolution (128x128 for a
   512 input) so the output is a per-class probability map — a soft mask.
   It is NOT upsampled inside the graph: 150 classes at 512x512 is a
   157 MB output that took seconds to move; 128x128 is 10 MB and the one
   mask that's wanted is upsampled on the CPU in a millisecond.
4. Traces the graph with TorchScript and converts with coremltools to an
   ML Program in float16, targeting macOS 15, all compute units (Core ML
   picks the Neural Engine where it can).
5. Writes the .mlpackage plus a labels.json with the 150 class names, and
   runs one prediction on a synthetic image to prove the package loads.
"""
import argparse, json, os, sys, time
import numpy as np
import torch
import coremltools as ct
from transformers import SegformerForSemanticSegmentation

parser = argparse.ArgumentParser()
parser.add_argument("--model", default="nvidia/segformer-b2-finetuned-ade-512-512")
parser.add_argument("--size", type=int, default=512, help="square input size in pixels")
parser.add_argument("--out", default="Sources/MLKit/Resources/Models")
parser.add_argument("--name", default=None, help="output package name (default from model)")
args = parser.parse_args()

t0 = time.time()
print(f"Loading {args.model} …")
model = SegformerForSemanticSegmentation.from_pretrained(args.model).eval()
id2label = {int(k): v for k, v in model.config.id2label.items()}
print(f"  {len(id2label)} classes, {sum(p.numel() for p in model.parameters())/1e6:.1f} M parameters")

class Wrapped(torch.nn.Module):
    """RGB 0-255 in, per-class probabilities at full input resolution out."""
    def __init__(self, net, size):
        super().__init__()
        self.net = net
        self.size = size
        self.register_buffer("mean", torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1) * 255)
        self.register_buffer("std", torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1) * 255)
    def forward(self, image):
        x = (image - self.mean) / self.std
        logits = self.net(pixel_values=x, return_dict=True).logits   # (1, C, H/4, W/4)
        return torch.softmax(logits, dim=1)                          # (1, C, H/4, W/4)

wrapped = Wrapped(model, args.size).eval()
example = torch.rand(1, 3, args.size, args.size) * 255
with torch.no_grad():
    traced = torch.jit.trace(wrapped, example)

print("Converting to Core ML …")
mlmodel = ct.convert(
    traced,
    inputs=[ct.ImageType(name="image", shape=(1, 3, args.size, args.size),
                         color_layout=ct.colorlayout.RGB, scale=1.0)],
    outputs=[ct.TensorType(name="probabilities")],
    convert_to="mlprogram",
    compute_precision=ct.precision.FLOAT16,
    compute_units=ct.ComputeUnit.ALL,
    minimum_deployment_target=ct.target.macOS15,
)
mlmodel.short_description = f"SegFormer ({args.model}) semantic segmentation, ADE20K 150 classes"
mlmodel.author = "Converted for Latent from Hugging Face weights"
mlmodel.license = "Model weights: see the Hugging Face model card (NVIDIA license for SegFormer)"
mlmodel.user_defined_metadata["source"] = args.model
mlmodel.user_defined_metadata["input_size"] = str(args.size)

name = args.name or ("SegFormer_" + args.model.split("/")[-1].replace("-", "_"))
os.makedirs(args.out, exist_ok=True)
package = os.path.join(args.out, name + ".mlpackage")
mlmodel.save(package)
with open(os.path.join(args.out, name + ".labels.json"), "w") as f:
    json.dump([id2label[i] for i in range(len(id2label))], f)

# Smoke test: load and predict on a sky-blue image; 'sky' should dominate.
print("Verifying …")
from PIL import Image
loaded = ct.models.MLModel(package)
blue = Image.new("RGB", (args.size, args.size), (135, 190, 235))
probs = loaded.predict({"image": blue})["probabilities"]
top = int(np.argmax(probs[0].mean(axis=(1, 2))))
size_mb = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(package) for f in fs) / 1e6
print(f"  output shape {probs.shape}, most likely class on a flat blue image: {top} '{id2label[top]}'")
print(f"Wrote {package} ({size_mb:.0f} MB) in {time.time()-t0:.0f}s")
