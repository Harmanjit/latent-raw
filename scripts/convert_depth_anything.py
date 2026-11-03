#!/usr/bin/env python3
"""
Convert Depth Anything V2 Small (relative depth, Apache-2.0) from the
published PyTorch weights into a Core ML package for Latent's Lens Blur,
and write the manifest the model registry reads.

    source ~/latent-ml/bin/activate
    python scripts/convert_depth_anything.py --weights ~/Downloads/depth_anything_v2_vits.pth
    python scripts/convert_depth_anything.py --weights … --verify-only   # re-check the package already in --out

The result is a folder (`./depth-anything-v2-small/` by default) holding
`DepthAnythingV2Small.mlpackage` and `depth-anything-v2-small.model.json`,
which the user adds through Settings › AI › Models. Latent never downloads
anything: without a depth model Lens Blur uses two planes made from the
subject mask, and this script is how a photographer gets a real depth map.

Depth Anything V2 (Yang et al. 2024, https://github.com/DepthAnything/Depth-Anything-V2)
is a DINOv2 ViT encoder with a DPT head. The Small variant (24.8 M
parameters) is the only one under Apache-2.0; Base and Large are
CC-BY-NC-4.0 and are not offered. The weights file is
`depth_anything_v2_vits.pth` from the Hugging Face repository
depth-anything/Depth-Anything-V2-Small. The script takes the downloaded file
with --weights and checks its SHA-256 against the value pinned here; a pin
that still reads `<pin me>` refuses to convert until someone has vetted the
upload and recorded it.

What it does, step by step:

1. Clones the model code at a pinned git commit (the commit hash is the
   pin: git verifies the content it names) into ~/.cache/latent-convert/,
   and hashes the weights file.
2. Loads DepthAnythingV2(encoder="vits") from the repository's own
   depth_anything_v2/dpt.py with the state dict strictly, so any layout
   mismatch fails loudly.
3. Wraps the model so its input is a plain RGB image (0-255) and the
   ImageNet normalisation the repository's `image2tensor` applies happens
   inside the graph. The output is the network's relative inverse depth,
   (1, H, W), larger nearer, unnormalised: Latent stretches it per image
   (`DepthEstimator.normalised`). The input is a fixed 518 x 518 square (a
   multiple of the ViT's 14-pixel patches, the size the model was trained
   at); Latent stretches the picture to it, as it does for the subject
   models, and the depth map is stretched back.
4. Traces with TorchScript and converts with coremltools to an ML Program in
   float16 targeting macOS 15, compute units CPU_AND_GPU (an imported model
   never runs above that in the app).
5. Writes the .mlpackage and metadata, then verifies it against PyTorch fp32
   on a test photo: both outputs stretched to 0…1, the largest and mean
   difference and the correlation, timing at CPU_AND_GPU and CPU_ONLY. A
   correlation under 0.99 on the GPU path fails the run.
6. Writes `<id>.model.json` last, through scripts/latent_manifest.py, with
   the package content hash and feature names read from the package.
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

CODE_URL = "https://github.com/DepthAnything/Depth-Anything-V2"
WEIGHTS_PAGE = "https://huggingface.co/depth-anything/Depth-Anything-V2-Small"
# The git commit of DepthAnything/Depth-Anything-V2 that was vetted, the
# revision of the Hugging Face repository the weights came from, and the
# SHA-256 of depth_anything_v2_vits.pth as that revision serves it.
CODE_REVISION = PLACEHOLDER
WEIGHTS_REVISION = PLACEHOLDER
WEIGHTS_NAME = "depth_anything_v2_vits.pth"
WEIGHTS_SHA256 = PLACEHOLDER
LICENCE_URL = "https://huggingface.co/depth-anything/Depth-Anything-V2-Small/blob/main/LICENSE"
MODEL_ID = "depth-anything-v2-small"
PACKAGE_NAME = "DepthAnythingV2Small"
INPUT_SIZE = 518          # 37 patches of 14 px: what the model was trained at
IMAGENET_MEAN = (0.485, 0.456, 0.406)
IMAGENET_STD = (0.229, 0.224, 0.225)

parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--weights", help=f"path to {WEIGHTS_NAME}, downloaded from {WEIGHTS_PAGE}")
parser.add_argument("--size", type=int, default=INPUT_SIZE, help="square input size in pixels (a multiple of 14)")
parser.add_argument("--out", default=None, help=f"directory for the package and manifest (default ./{MODEL_ID}/)")
parser.add_argument("--test-image", default=None,
                    help="photo for the PyTorch comparison (default: TestAssets/HSB_6548.jpg, else the portrait)")
parser.add_argument("--skip-verify", action="store_true")
parser.add_argument("--verify-only", action="store_true",
                    help="no conversion: run the PyTorch comparison against the package already in --out")
parser.add_argument("--runs", type=int, default=5, help="timed predictions per compute unit after one warm-up")
args = parser.parse_args()

if PLACEHOLDER in (CODE_REVISION, WEIGHTS_REVISION, WEIGHTS_SHA256):
    sys.exit(f"convert_depth_anything.py is not pinned yet: vet {CODE_URL} and {WEIGHTS_NAME} from {WEIGHTS_PAGE}, "
             f"then record the git commit in CODE_REVISION, the Hugging Face revision in WEIGHTS_REVISION and the "
             f"file's SHA-256 in WEIGHTS_SHA256 before converting. Nothing was fetched.")
if not args.weights:
    parser.error(f"--weights is needed: {WEIGHTS_NAME} from {WEIGHTS_PAGE}")
if args.size % 14 != 0:
    parser.error(f"--size {args.size} is not a multiple of the ViT's 14-pixel patches")
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
    """A clone of `url` at exactly `revision` under ~/.cache/latent-convert/.
    The commit hash is the pin, so a fetched repository can only ever
    yield the vetted files or fail."""
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
code = checkout(CODE_URL, CODE_REVISION, "Depth-Anything-V2")
sha = latent_manifest.file_sha256(args.weights)
print(f"  {os.path.basename(args.weights)} sha256 {sha} ({os.path.getsize(args.weights)/1e6:.1f} MB)")
if sha != WEIGHTS_SHA256:
    sys.exit(f"SHA-256 mismatch: expected {WEIGHTS_SHA256}; refusing to convert")

# -------------------------------------------------------------------- 2. load
import numpy as np
import torch
import coremltools as ct

sys.path.insert(0, code)
from depth_anything_v2.dpt import DepthAnythingV2   # the repository's own definition, at the pinned commit
# The configuration the repository's README gives for the Small model.
model = DepthAnythingV2(encoder="vits", features=64, out_channels=[48, 96, 192, 384])
state = torch.load(args.weights, map_location="cpu", weights_only=True)
model.load_state_dict(state, strict=True)
model.eval()
print(f"  DepthAnythingV2 vits, {sum(p.numel() for p in model.parameters())/1e6:.1f} M parameters")


# --------------------------------------------------------------------- 3. wrap
class Wrapped(torch.nn.Module):
    """RGB 0-255 in, relative inverse depth (1, H, W), larger nearer, out."""
    def __init__(self, net):
        super().__init__()
        self.net = net
        self.register_buffer("mean", torch.tensor(IMAGENET_MEAN).view(1, 3, 1, 1) * 255.0)
        self.register_buffer("std", torch.tensor(IMAGENET_STD).view(1, 3, 1, 1) * 255.0)

    def forward(self, image):
        x = (image - self.mean) / self.std    # image2tensor: x/255, then ImageNet mean and std
        return self.net(x)                    # (1, H, W) after the head's ReLU


wrapped = Wrapped(model).eval()
example = torch.rand(1, 3, args.size, args.size) * 255


def stretched(a):
    """A depth map stretched to 0…1, as Latent reads one."""
    a = np.asarray(a, dtype=np.float32)
    lo, hi = np.percentile(a, 1), np.percentile(a, 99)
    return np.clip((a - lo) / max(hi - lo, 1e-6), 0, 1)


reference = None
if not args.skip_verify:
    from PIL import Image
    test_img = Image.open(test_image_path).convert("RGB").resize((args.size, args.size), Image.BICUBIC)
    test_t = torch.from_numpy(np.asarray(test_img, dtype=np.float32)).permute(2, 0, 1)[None]
    print(f"PyTorch reference on {os.path.relpath(test_image_path, REPO_ROOT)} …")
    with torch.no_grad():
        reference = wrapped(test_t)[0].numpy()
    assert reference.ndim == 2 and reference.shape == (args.size, args.size), f"unexpected output {reference.shape}"

if not args.verify_only:
    print("Tracing …")
    with torch.no_grad():
        traced = torch.jit.trace(wrapped, example)

    # -------------------------------------------------------------- 4. convert
    print("Converting to Core ML …")
    t1 = time.time()
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, args.size, args.size),
                             color_layout=ct.colorlayout.RGB, scale=1.0)],
        outputs=[ct.TensorType(name="depth")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.CPU_AND_GPU,
        minimum_deployment_target=ct.target.macOS15,
    )
    print(f"  converted in {time.time()-t1:.0f}s")
    licence = f"Apache-2.0 ({WEIGHTS_PAGE})"
    mlmodel.short_description = ("Depth Anything V2 Small: RGB image in, relative inverse depth out "
                                 "(larger is nearer), for Latent's Lens Blur")
    mlmodel.author = "Latent"
    mlmodel.license = licence
    mlmodel.user_defined_metadata["author"] = "Latent"
    mlmodel.user_defined_metadata["source"] = CODE_URL
    mlmodel.user_defined_metadata["license"] = licence
    mlmodel.user_defined_metadata["revision"] = CODE_REVISION
    mlmodel.user_defined_metadata["weights"] = f"{WEIGHTS_PAGE}@{WEIGHTS_REVISION}/{WEIGHTS_NAME}"
    mlmodel.user_defined_metadata["weights_sha256"] = WEIGHTS_SHA256
    mlmodel.user_defined_metadata["input_size"] = str(args.size)
    mlmodel.user_defined_metadata["input"] = "image: RGB 0-255, ImageNet mean/std normalisation is inside the graph"
    mlmodel.user_defined_metadata["output"] = "depth: (1, H, W) float, relative inverse depth, larger is nearer, unnormalised"

    os.makedirs(out_dir, exist_ok=True)
    mlmodel.save(package)
    print(f"Wrote {package} ({latent_manifest.package_size(package)/1e6:.1f} MB) in {time.time()-t0:.0f}s")

# ------------------------------------------------------------------- 5. verify
failed = False
if not args.skip_verify:
    print("Verifying …")
    expected = stretched(reference)
    for cu in (ct.ComputeUnit.CPU_AND_GPU, ct.ComputeUnit.CPU_ONLY):
        t2 = time.time()
        loaded = ct.models.MLModel(package, compute_units=cu)
        load_s = time.time() - t2
        out = loaded.predict({"image": test_img})["depth"]        # warm-up
        times = []
        for _ in range(args.runs):
            t3 = time.time(); out = loaded.predict({"image": test_img})["depth"]; times.append(time.time() - t3)
        got = stretched(np.asarray(out, dtype=np.float32)[0])
        correlation = float(np.corrcoef(got.ravel(), expected.ravel())[0, 1])
        print(f"  {cu.name:12s} load {load_s:.1f}s  predict {np.median(times)*1000:.0f} ms median "
              f"({args.runs} runs after warm-up)  output {out.shape} {out.dtype}")
        print(f"               vs PyTorch fp32 (both stretched to 0-1): max |diff| {np.abs(got - expected).max():.4f}, "
              f"mean |diff| {np.abs(got - expected).mean():.5f}, correlation {correlation:.5f}")
        # The app runs imported models at cpuAndGPU at most, so the GPU
        # path is the one the criterion applies to.
        if cu == ct.ComputeUnit.CPU_AND_GPU and correlation < 0.99:
            print(f"  FAILED: correlation {correlation:.5f} on the GPU path is under 0.99")
            failed = True
if failed:
    sys.exit("Verification failed; no manifest written")
if args.verify_only:
    print("Verified")
    sys.exit(0)

# ----------------------------------------------------------------- 6. manifest
row = latent_manifest.package_entry(package)
row["_bytes"] = latent_manifest.package_size(package)
manifest = latent_manifest.build_manifest(
    id=MODEL_ID, display_name="Depth Anything V2 Small",
    purpose="Depth for Lens Blur: how near or far each part of the photo is",
    version=1, kind="depth", licence_name="Apache-2.0", licence_url=LICENCE_URL, commercial_use=True,
    source_url=WEIGHTS_PAGE, input_size=args.size, packages=[row], compute_units="cpuAndGPU",
    converter={"script": "scripts/convert_depth_anything.py", "sourceRevision": CODE_REVISION,
               "coremltools": ct.__version__, "torch": torch.__version__.split("+")[0],
               "date": datetime.date.today().isoformat()})
print(f"Wrote {latent_manifest.write_manifest(manifest, out_dir)}")
