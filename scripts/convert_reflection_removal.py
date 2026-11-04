#!/usr/bin/env python3
"""
Convert a single-image reflection-removal network from its published
PyTorch weights into a Core ML package for Latent's Distraction Removal ›
Reflections, and write the manifest the model registry reads.

    source ~/latent-ml/bin/activate
    python scripts/convert_reflection_removal.py --weights ~/Downloads/<weights file>
    python scripts/convert_reflection_removal.py --weights … --verify-only   # re-check the package in --out

The result is a folder (`./reflection-removal/` by default) holding
`ReflectionRemoval.mlpackage` and `reflection-removal.model.json`, which the
user adds through Settings › AI › Models. Latent never downloads anything,
and no reflection model is bundled or named in the catalogue: without one
the Reflections slider stays off and says so.

Which network: none is chosen here yet. Every value below that reads
`<pin me>` must be filled in by whoever vets a network for licence (it
must allow use in a free app; many reflection-removal releases are
research-only), code and weights before the script will convert anything.
The network must take one RGB photo and return the transmission layer (the
scene behind the glass) as RGB of the same size; networks that also return
the reflection layer are fine, the wrapper keeps only the transmission.

The contract with the app (ReflectionRemover.swift):

- input: a Core ML image, RGB, 0-255, a fixed square of INPUT_SIZE (the app
  stretches the upright photo to it, as for the depth model);
- output: a float tensor named "transmission", (1, 3, H, W), 0…1 (0…255 is
  recognised too). The app divides it by its input, in linear light, to get
  a gain map, so the output must keep the input's framing and exposure.

What it does, step by step:

1. Clones the model code at the pinned git commit (the commit is the pin)
   into ~/.cache/latent-convert/ and checks the weights file's SHA-256.
2. Imports MODEL_MODULE.MODEL_CLASS from that checkout and loads the state
   dict strictly, so any layout mismatch fails loudly.
3. Wraps it: 0-255 in, normalisation inside the graph, transmission clamped
   to 0…1 out.
4. Traces with TorchScript and converts with coremltools to an ML Program in
   float16 targeting macOS 15, compute units CPU_AND_GPU.
5. Verifies the package against PyTorch fp32 on a test photo (largest and
   mean difference); a mean difference above 0.02 fails the run.
6. Writes `<id>.model.json` last, through scripts/latent_manifest.py.
"""
import argparse
import datetime
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import latent_manifest

REPO_ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
PLACEHOLDER = latent_manifest.PLACEHOLDER

# The network, once vetted: its code repository, the git commit, the module
# and class that define it inside that repository, the keyword arguments
# its constructor takes for the released weights, and the weights file's
# name, page and SHA-256. Licence: the name, its URL and whether it allows
# commercial use (the app's catalogue shows the licence beside the model).
CODE_URL = PLACEHOLDER
CODE_REVISION = PLACEHOLDER
MODEL_MODULE = PLACEHOLDER        # e.g. "models.net", relative to the checkout
MODEL_CLASS = PLACEHOLDER
MODEL_KWARGS = {}
WEIGHTS_NAME = PLACEHOLDER
WEIGHTS_PAGE = PLACEHOLDER
WEIGHTS_SHA256 = PLACEHOLDER
STATE_DICT_KEY = None             # set when the checkpoint nests the weights, e.g. "state_dict"
LICENCE_NAME = PLACEHOLDER
LICENCE_URL = PLACEHOLDER
COMMERCIAL_USE = False
# Input normalisation the network was trained with: x/255, then (x - mean) / std.
INPUT_MEAN = (0.0, 0.0, 0.0)
INPUT_STD = (1.0, 1.0, 1.0)
# True when the network's output is in the normalised space too and needs
# the mean and std put back; False when it already returns 0…1.
OUTPUT_DENORMALISE = False
MODEL_ID = "reflection-removal"
DISPLAY_NAME = "Reflection Removal"
PACKAGE_NAME = "ReflectionRemoval"
INPUT_SIZE = 512

parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--weights", help="path to the vetted weights file")
parser.add_argument("--size", type=int, default=INPUT_SIZE, help="square input size in pixels")
parser.add_argument("--out", default=None, help=f"directory for the package and manifest (default ./{MODEL_ID}/)")
parser.add_argument("--test-image", default=None,
                    help="photo for the PyTorch comparison (default: TestAssets/HSB_6548.jpg, else the portrait)")
parser.add_argument("--skip-verify", action="store_true")
parser.add_argument("--verify-only", action="store_true",
                    help="no conversion: run the PyTorch comparison against the package already in --out")
args = parser.parse_args()

pins = dict(CODE_URL=CODE_URL, CODE_REVISION=CODE_REVISION, MODEL_MODULE=MODEL_MODULE, MODEL_CLASS=MODEL_CLASS,
            WEIGHTS_NAME=WEIGHTS_NAME, WEIGHTS_PAGE=WEIGHTS_PAGE, WEIGHTS_SHA256=WEIGHTS_SHA256,
            LICENCE_NAME=LICENCE_NAME, LICENCE_URL=LICENCE_URL)
unpinned = [name for name, value in pins.items() if value == PLACEHOLDER]
if unpinned:
    sys.exit("convert_reflection_removal.py is not pinned yet: vet a reflection-removal network (licence, code, "
             "weights) and record " + ", ".join(unpinned) + " before converting. Nothing was fetched.")
if not args.weights:
    parser.error(f"--weights is needed: {WEIGHTS_NAME} from {WEIGHTS_PAGE}")
out_dir = args.out or MODEL_ID
package = os.path.join(out_dir, PACKAGE_NAME + ".mlpackage")
test_image_path = args.test_image
if test_image_path is None:
    for candidate in ("TestAssets/HSB_6548.jpg", "TestAssets/portrait/zena_cardman_nasa_portrait.jpg"):
        if os.path.isfile(os.path.join(REPO_ROOT, candidate)):
            test_image_path = os.path.join(REPO_ROOT, candidate)
            break
if test_image_path is None and not args.skip_verify:
    sys.exit("no test photo found under TestAssets; run scripts/fetch_test_assets.sh --portrait or pass --test-image")

t0 = time.time()


def checkout(url, revision, name):
    """A clone of `url` at exactly `revision` under ~/.cache/latent-convert/."""
    root = os.path.join(os.path.expanduser("~/.cache/latent-convert"), name)
    if not os.path.isdir(os.path.join(root, ".git")):
        print(f"Cloning {url} …")
        subprocess.run(["git", "clone", "--quiet", url, root], check=True)
    head = lambda: subprocess.run(["git", "-C", root, "rev-parse", "HEAD"],
                                  capture_output=True, text=True, check=True).stdout.strip()
    if head() != revision:
        subprocess.run(["git", "-C", root, "fetch", "--quiet", "origin"], check=True)
        subprocess.run(["git", "-C", root, "checkout", "--quiet", "--detach", revision], check=True)
    if head() != revision:
        sys.exit(f"{root} is at {head()}, not the pinned {revision}")
    return root


# ------------------------------------------------------ 1. code and weights
code = checkout(CODE_URL, CODE_REVISION, "reflection-removal")
sha = latent_manifest.file_sha256(args.weights)
print(f"  {os.path.basename(args.weights)} sha256 {sha} ({os.path.getsize(args.weights)/1e6:.1f} MB)")
if sha != WEIGHTS_SHA256:
    sys.exit(f"SHA-256 mismatch: expected {WEIGHTS_SHA256}; refusing to convert")

# -------------------------------------------------------------------- 2. load
import importlib
import numpy as np
import torch
import coremltools as ct

sys.path.insert(0, code)
net_class = getattr(importlib.import_module(MODEL_MODULE), MODEL_CLASS)
model = net_class(**MODEL_KWARGS)
state = torch.load(args.weights, map_location="cpu", weights_only=True)
if STATE_DICT_KEY:
    state = state[STATE_DICT_KEY]
model.load_state_dict(state, strict=True)
model.eval()
print(f"  {MODEL_CLASS}, {sum(p.numel() for p in model.parameters())/1e6:.1f} M parameters")


# --------------------------------------------------------------------- 3. wrap
class Wrapped(torch.nn.Module):
    """RGB 0-255 in, the transmission layer (1, 3, H, W), 0…1, out."""
    def __init__(self, net):
        super().__init__()
        self.net = net
        self.register_buffer("mean", torch.tensor(INPUT_MEAN).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(INPUT_STD).view(1, 3, 1, 1))

    def forward(self, image):
        x = (image / 255.0 - self.mean) / self.std
        out = self.net(x)
        if isinstance(out, (tuple, list)):
            out = out[0]                      # (transmission, reflection): keep the scene
        if OUTPUT_DENORMALISE:
            out = out * self.std + self.mean
        return torch.clamp(out, 0.0, 1.0)


wrapped = Wrapped(model).eval()
example = torch.rand(1, 3, args.size, args.size) * 255

reference = None
if not args.skip_verify:
    from PIL import Image
    test_img = Image.open(test_image_path).convert("RGB").resize((args.size, args.size), Image.BICUBIC)
    test_t = torch.from_numpy(np.asarray(test_img, dtype=np.float32)).permute(2, 0, 1)[None]
    print(f"PyTorch reference on {os.path.relpath(test_image_path, REPO_ROOT)} …")
    with torch.no_grad():
        reference = wrapped(test_t)[0].numpy()
    assert reference.shape == (3, args.size, args.size), f"unexpected output {reference.shape}"

if not args.verify_only:
    print("Tracing …")
    with torch.no_grad():
        traced = torch.jit.trace(wrapped, example)

    # -------------------------------------------------------------- 4. convert
    print("Converting to Core ML …")
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, args.size, args.size),
                             color_layout=ct.colorlayout.RGB, scale=1.0)],
        outputs=[ct.TensorType(name="transmission")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.CPU_AND_GPU,
        minimum_deployment_target=ct.target.macOS15,
    )
    licence = f"{LICENCE_NAME} ({LICENCE_URL})"
    mlmodel.short_description = "Reflection removal: RGB photo in, the scene behind the glass out, for Latent"
    mlmodel.author = "Latent"
    mlmodel.license = licence
    mlmodel.user_defined_metadata["source"] = CODE_URL
    mlmodel.user_defined_metadata["revision"] = CODE_REVISION
    mlmodel.user_defined_metadata["weights_sha256"] = WEIGHTS_SHA256
    mlmodel.user_defined_metadata["output"] = "transmission: (1, 3, H, W) float, 0-1"
    os.makedirs(out_dir, exist_ok=True)
    mlmodel.save(package)
    print(f"Wrote {package} ({latent_manifest.package_size(package)/1e6:.1f} MB) in {time.time()-t0:.0f}s")

# ------------------------------------------------------------------- 5. verify
if not args.skip_verify:
    print("Verifying …")
    loaded = ct.models.MLModel(package, compute_units=ct.ComputeUnit.CPU_AND_GPU)
    got = np.asarray(loaded.predict({"image": test_img})["transmission"], dtype=np.float32)[0]
    diff = np.abs(got - reference)
    print(f"  vs PyTorch fp32: max |diff| {diff.max():.4f}, mean |diff| {diff.mean():.5f}")
    if diff.mean() > 0.02:
        sys.exit("Verification failed (mean difference over 0.02); no manifest written")
if args.verify_only:
    print("Verified")
    sys.exit(0)

# ----------------------------------------------------------------- 6. manifest
row = latent_manifest.package_entry(package)
row["_bytes"] = latent_manifest.package_size(package)
manifest = latent_manifest.build_manifest(
    id=MODEL_ID, display_name=DISPLAY_NAME,
    purpose="Reflections: takes window and glass reflections off the scene behind them",
    version=1, kind="reflectionRemoval", licence_name=LICENCE_NAME, licence_url=LICENCE_URL,
    commercial_use=COMMERCIAL_USE, source_url=WEIGHTS_PAGE, input_size=args.size, packages=[row],
    compute_units="cpuAndGPU",
    converter={"script": "scripts/convert_reflection_removal.py", "sourceRevision": CODE_REVISION,
               "coremltools": ct.__version__, "torch": torch.__version__.split("+")[0],
               "date": datetime.date.today().isoformat()})
print(f"Wrote {latent_manifest.write_manifest(manifest, out_dir)}")
