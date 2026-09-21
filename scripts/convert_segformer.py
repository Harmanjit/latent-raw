#!/usr/bin/env python3
"""
Convert a SegFormer semantic-segmentation model (ADE20K, 150 classes) from
Hugging Face into a Core ML package for Latent's MLKit, and write the
manifest the model registry reads.

    source ~/latent-ml/bin/activate
    python scripts/convert_segformer.py                 # the bundled B2 into Sources/MLKit/Resources/Models
    python scripts/convert_segformer.py --verify-only   # re-check the package already there

What it does, step by step:

1. Downloads the PyTorch weights and config from Hugging Face at a pinned
   revision and checks the SHA-256 of the weights file against the value
   recorded here, so a changed upload cannot silently change the bundled
   model. At the pinned revision the repository holds `pytorch_model.bin`
   and no safetensors, so that is the file hashed and loaded
   (`use_safetensors=False`: otherwise transformers would fetch the Hub's
   auto-converted safetensors from another branch, which the pin does not
   cover).
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
   picks the Neural Engine where it can; this graph compiles for it).
5. Writes the .mlpackage plus a labels.json with the 150 class names, then
   verifies it against PyTorch fp32 on a test photo (max abs diff of the
   probabilities and how many pixels keep the same top class, on
   CPU_AND_GPU and CPU_ONLY) and on a flat sky-blue image, where 'sky'
   must win. Under 95 % agreement fails the run.
6. Writes `<id>.model.json` last, through scripts/latent_manifest.py, with
   the package content hash, feature names read from the package and the
   labels file name.

A re-conversion is never byte-identical, so the bundled package is
converted once and kept; a new conversion means a new hash and a new
manifest.
"""
import argparse, datetime, json, os, sys, time
import numpy as np
import torch
import coremltools as ct

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import latent_manifest

REPO_ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
MODELS_DIR = os.path.join(REPO_ROOT, "Sources", "MLKit", "Resources", "Models")
PLACEHOLDER = latent_manifest.PLACEHOLDER

# Pinned to the repository revision that was vetted and to the SHA-256 of
# its weights file (pytorch_model.bin at that revision; it has no
# safetensors). The hash is the one Hugging Face's LFS store names the
# blob by, checked again here after download.
SEGFORMER_REVISION = "de01bae28967510f9ddd496c60a969357195400c"
SEGFORMER_WEIGHTS = "pytorch_model.bin"
SEGFORMER_SHA256 = "187ca07bea003a5717c63d04ea90b07f33cd033c0ebf44b4b89fce5070d6c8f3"
LICENCE_NAME = "NVIDIA Source Code License"
LICENCE_URL = "https://github.com/NVlabs/SegFormer/blob/master/LICENSE"

parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--model", default="nvidia/segformer-b2-finetuned-ade-512-512",
                    help="the Hugging Face repository (the pins in the script belong to the default)")
parser.add_argument("--size", type=int, default=512, help="square input size in pixels")
parser.add_argument("--out", default=MODELS_DIR, help="directory for the package, labels and manifest")
parser.add_argument("--name", default=None, help="output package name (default from model)")
parser.add_argument("--id", default="segformer-b2-ade20k-512", help="the manifest id")
parser.add_argument("--display-name", default="SegFormer B2")
parser.add_argument("--test-image", default=None,
                    help="photo for the PyTorch comparison (default: TestAssets/HSB_6548.jpg, else the portrait)")
parser.add_argument("--skip-verify", action="store_true")
parser.add_argument("--verify-only", action="store_true",
                    help="no conversion: run the PyTorch comparison against the package already in --out")
parser.add_argument("--runs", type=int, default=5, help="timed predictions per compute unit after one warm-up")
args = parser.parse_args()

if SEGFORMER_REVISION == PLACEHOLDER or SEGFORMER_SHA256 == PLACEHOLDER:
    sys.exit(f"convert_segformer.py is not pinned yet: vet https://huggingface.co/{args.model}, then record its git "
             f"revision in SEGFORMER_REVISION and the SHA-256 of {SEGFORMER_WEIGHTS} in SEGFORMER_SHA256 before "
             f"converting. Nothing was downloaded.")
name = args.name or ("SegFormer_" + args.model.split("/")[-1].replace("-", "_"))
package = os.path.join(args.out, name + ".mlpackage")
labels_file = name + ".labels.json"
test_image_path = args.test_image
if test_image_path is None:
    for candidate in ("TestAssets/HSB_6548.jpg", "TestAssets/portrait/zena_cardman_nasa_portrait.jpg"):
        if os.path.isfile(os.path.join(REPO_ROOT, candidate)):
            test_image_path = os.path.join(REPO_ROOT, candidate)
            break
if test_image_path is None and not args.skip_verify:
    sys.exit("no test photo found under TestAssets; run scripts/fetch_test_assets.sh --portrait or pass --test-image")

t0 = time.time()

# ---------------------------------------------------------------- 1. download
print(f"Downloading {args.model} @ {SEGFORMER_REVISION[:12]} …")
from huggingface_hub import hf_hub_download
weights = hf_hub_download(args.model, SEGFORMER_WEIGHTS, revision=SEGFORMER_REVISION)
sha = latent_manifest.file_sha256(weights)
print(f"  {SEGFORMER_WEIGHTS} sha256 {sha} ({os.path.getsize(weights)/1e6:.1f} MB)")
if sha != SEGFORMER_SHA256:
    sys.exit(f"SHA-256 mismatch: expected {SEGFORMER_SHA256}; refusing to convert")

from transformers import SegformerForSemanticSegmentation
model = SegformerForSemanticSegmentation.from_pretrained(args.model, revision=SEGFORMER_REVISION,
                                                         use_safetensors=False).eval()
id2label = {int(k): v for k, v in model.config.id2label.items()}
print(f"  {len(id2label)} classes, {sum(p.numel() for p in model.parameters())/1e6:.1f} M parameters")


# -------------------------------------------------------------------- 2. wrap
class Wrapped(torch.nn.Module):
    """RGB 0-255 in, per-class probabilities at 1/4 of the input resolution out."""
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

reference = None
if not args.skip_verify:
    from PIL import Image
    test_img = Image.open(test_image_path).convert("RGB").resize((args.size, args.size), Image.BILINEAR)
    test_t = torch.from_numpy(np.asarray(test_img, dtype=np.float32)).permute(2, 0, 1)[None]
    print(f"PyTorch reference on {os.path.relpath(test_image_path, REPO_ROOT)} …")
    with torch.no_grad():
        reference = wrapped(test_t)[0].numpy()                      # (C, H/4, W/4)

if not args.verify_only:
    with torch.no_grad():
        traced = torch.jit.trace(wrapped, example)

    # ---------------------------------------------------------- 3-4. convert
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
    licence = f"{LICENCE_NAME} ({LICENCE_URL}): research and evaluation use only"
    mlmodel.short_description = f"SegFormer ({args.model}) semantic segmentation, ADE20K 150 classes"
    mlmodel.author = "Latent"
    mlmodel.license = licence
    mlmodel.user_defined_metadata["author"] = "Latent"
    mlmodel.user_defined_metadata["source"] = f"https://huggingface.co/{args.model}"
    mlmodel.user_defined_metadata["license"] = licence
    mlmodel.user_defined_metadata["revision"] = SEGFORMER_REVISION
    mlmodel.user_defined_metadata["weights"] = SEGFORMER_WEIGHTS
    mlmodel.user_defined_metadata["weights_sha256"] = SEGFORMER_SHA256
    mlmodel.user_defined_metadata["input_size"] = str(args.size)
    mlmodel.user_defined_metadata["input"] = "image: RGB 0-255, ImageNet normalisation is inside the graph"
    mlmodel.user_defined_metadata["output"] = "probabilities: (1, 150, H/4, W/4) float, softmax applied inside the graph"

    # ------------------------------------------------------------- 5. write
    os.makedirs(args.out, exist_ok=True)
    mlmodel.save(package)
    with open(os.path.join(args.out, labels_file), "w") as f:
        json.dump([id2label[i] for i in range(len(id2label))], f)
    print(f"Wrote {package} ({latent_manifest.package_size(package)/1e6:.0f} MB) in {time.time()-t0:.0f}s")

# ------------------------------------------------------------------ 5. verify
failed = False
if not args.skip_verify:
    print("Verifying …")
    for cu in (ct.ComputeUnit.CPU_AND_GPU, ct.ComputeUnit.CPU_ONLY):
        t2 = time.time()
        loaded = ct.models.MLModel(package, compute_units=cu)
        load_s = time.time() - t2
        out = loaded.predict({"image": test_img})["probabilities"]        # warm-up
        times = []
        for _ in range(args.runs):
            t3 = time.time(); out = loaded.predict({"image": test_img})["probabilities"]; times.append(time.time() - t3)
        got = np.asarray(out, dtype=np.float32)[0]
        agreement = float((got.argmax(0) == reference.argmax(0)).mean())
        print(f"  {cu.name:12s} load {load_s:.1f}s  predict {np.median(times)*1000:.0f} ms median "
              f"({args.runs} runs after warm-up)  output {out.shape} {out.dtype}")
        print(f"               vs PyTorch fp32: max |diff| {np.abs(got - reference).max():.4f}, "
              f"top class agrees on {agreement*100:.2f}% of pixels")
        if agreement < 0.95:
            print(f"  FAILED: only {agreement*100:.2f}% of pixels keep their class on {cu.name}")
            failed = True
    # A flat sky-blue image: 'sky' should dominate, or the classes are scrambled.
    blue = Image.new("RGB", (args.size, args.size), (135, 190, 235))
    probs = loaded.predict({"image": blue})["probabilities"]
    top = int(np.argmax(probs[0].mean(axis=(1, 2))))
    print(f"  most likely class on a flat blue image: {top} '{id2label[top]}'")
    if id2label[top] != "sky":
        print("  FAILED: a flat blue image is not 'sky'")
        failed = True
if failed:
    sys.exit("Verification failed; no manifest written")
if args.verify_only:
    print("Verified")
    sys.exit(0)

# ---------------------------------------------------------------- 6. manifest
row = latent_manifest.package_entry(package)
row["_bytes"] = latent_manifest.package_size(package)
manifest = latent_manifest.build_manifest(
    id=args.id, display_name=args.display_name,
    purpose=f"Select by class: sky, person, tree, water and {len(id2label) - 4} more", version=1,
    kind="semanticSegmentation", licence_name=LICENCE_NAME, licence_url=LICENCE_URL, commercial_use=False,
    source_url=f"https://huggingface.co/{args.model}", input_size=args.size, packages=[row],
    labels_file=labels_file,
    converter={"script": "scripts/convert_segformer.py", "sourceRevision": SEGFORMER_REVISION,
               "coremltools": ct.__version__, "torch": torch.__version__.split("+")[0],
               "date": datetime.date.today().isoformat()})
print(f"Wrote {latent_manifest.write_manifest(manifest, args.out)}")
