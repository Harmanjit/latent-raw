#!/usr/bin/env python3
"""
Convert MODNet (portrait matting: a soft matte with hair, people only) from
the published PyTorch weights into a Core ML package for Latent's MLKit,
and write the manifest the model registry reads.

    source ~/latent-ml/bin/activate
    python scripts/convert_modnet.py --weights ~/Downloads/modnet_photographic_portrait_matting.ckpt
    python scripts/convert_modnet.py --weights … --verify-only   # re-check the package already in --out

The result is a folder (`./modnet/` by default) holding `MODNet.mlpackage`
and `modnet.model.json`, which the user adds through Settings › AI › Models.

MODNet (Ke et al. 2022, https://github.com/ZHKKKe/MODNet, Apache-2.0) is a
MobileNetV2 trunk with three branches (semantic, detail, fusion); only the
fused matte is kept. The weights are not on Hugging Face: the repository's
README links `modnet_photographic_portrait_matting.ckpt` on Google Drive,
so the script takes the downloaded file with --weights and checks its
SHA-256 against the value pinned here. A pin that still reads `<pin me>`
refuses to convert until someone has vetted the upload and recorded it.

What it does, step by step:

1. Clones the model code at a pinned git commit (the commit hash is the
   pin: git verifies the content it names) into ~/.cache/latent-convert/,
   and hashes the weights file.
2. Loads MODNet from the repository's own src/models/modnet.py with the
   state dict strictly (the checkpoint was saved from nn.DataParallel, so
   its `module.` prefix is stripped first), so any layout mismatch fails
   loudly.
3. Wraps the model so its input is a plain RGB image (0-255) and the
   (x/255 - 0.5)/0.5 normalisation MODNet expects happens inside the graph;
   the matte is already a sigmoid inside the network, so the output is a
   [0, 1] soft mask at the input resolution.
4. Traces with TorchScript and converts with coremltools to an ML Program in
   float16 targeting macOS 15. The in-process compute units are CPU_AND_GPU:
   an imported model never runs above cpuAndGPU in the app (the registry's
   ceiling for non-bundled models), and the ANE compiler is not exercised
   here.
5. Writes the .mlpackage and metadata, then verifies it against PyTorch fp32
   on a test photo (a portrait when one is there: MODNet is trained on
   people): max abs diff, IoU at 0.5, timing at CPU_AND_GPU and CPU_ONLY.
   IoU under 0.97 on the GPU path fails the run.
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

CODE_URL = "https://github.com/ZHKKKe/MODNet"
# The git commit of ZHKKKe/MODNet that was vetted, and the SHA-256 of
# modnet_photographic_portrait_matting.ckpt as the README links it.
CODE_REVISION = PLACEHOLDER
WEIGHTS_NAME = "modnet_photographic_portrait_matting.ckpt"
WEIGHTS_SHA256 = PLACEHOLDER
LICENCE_URL = "https://github.com/ZHKKKe/MODNet/blob/master/LICENSE"
MODEL_ID = "modnet"
PACKAGE_NAME = "MODNet"
INPUT_SIZE = 512          # MODNet wants a multiple of 32; 512 is what its inference script targets

parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--weights", help=f"path to {WEIGHTS_NAME}, downloaded from the link in the MODNet README")
parser.add_argument("--size", type=int, default=INPUT_SIZE, help="square input size in pixels (a multiple of 32)")
parser.add_argument("--out", default=None, help=f"directory for the package and manifest (default ./{MODEL_ID}/)")
parser.add_argument("--test-image", default=None,
                    help="photo for the PyTorch comparison (default: the portrait, else TestAssets/HSB_6548.jpg)")
parser.add_argument("--skip-verify", action="store_true")
parser.add_argument("--verify-only", action="store_true",
                    help="no conversion: run the PyTorch comparison against the package already in --out")
parser.add_argument("--runs", type=int, default=5, help="timed predictions per compute unit after one warm-up")
args = parser.parse_args()

if CODE_REVISION == PLACEHOLDER or WEIGHTS_SHA256 == PLACEHOLDER:
    sys.exit(f"convert_modnet.py is not pinned yet: vet {CODE_URL} and {WEIGHTS_NAME}, then record the git commit "
             f"in CODE_REVISION and the file's SHA-256 in WEIGHTS_SHA256 before converting. Nothing was fetched.")
if not args.weights:
    parser.error(f"--weights is needed: {WEIGHTS_NAME} from the link in the MODNet README")
if args.size % 32:
    parser.error("--size must be a multiple of 32")
out_dir = args.out or MODEL_ID
package = os.path.join(out_dir, PACKAGE_NAME + ".mlpackage")
test_image_path = args.test_image
if test_image_path is None:
    for candidate in ("TestAssets/portrait/zena_cardman_nasa_portrait.jpg", "TestAssets/HSB_6548.jpg"):
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
code = checkout(CODE_URL, CODE_REVISION, "MODNet")
sha = latent_manifest.file_sha256(args.weights)
print(f"  {os.path.basename(args.weights)} sha256 {sha} ({os.path.getsize(args.weights)/1e6:.1f} MB)")
if sha != WEIGHTS_SHA256:
    sys.exit(f"SHA-256 mismatch: expected {WEIGHTS_SHA256}; refusing to convert")

# -------------------------------------------------------------------- 2. load
import numpy as np
import torch
import coremltools as ct

sys.path.insert(0, os.path.join(code, "src"))
from models.modnet import MODNet      # the repository's own definition, at the pinned commit
model = MODNet(backbone_pretrained=False)
state = torch.load(args.weights, map_location="cpu", weights_only=True)
state = {k[len("module."):] if k.startswith("module.") else k: v for k, v in state.items()}
model.load_state_dict(state, strict=True)
model.eval()
print(f"  MODNet, {sum(p.numel() for p in model.parameters())/1e6:.1f} M parameters")


# --------------------------------------------------------------------- 3. wrap
class Wrapped(torch.nn.Module):
    """RGB 0-255 in, soft matte in [0, 1] at the input resolution out."""
    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, image):
        x = image / 127.5 - 1.0               # MODNet's Normalize(mean 0.5, std 0.5) after /255
        return self.net(x, True)[2]            # (semantic, detail, matte); matte is sigmoid'ed inside


wrapped = Wrapped(model).eval()
example = torch.rand(1, 3, args.size, args.size) * 255

reference = None
if not args.skip_verify:
    from PIL import Image
    test_img = Image.open(test_image_path).convert("RGB").resize((args.size, args.size), Image.BILINEAR)
    test_t = torch.from_numpy(np.asarray(test_img, dtype=np.float32)).permute(2, 0, 1)[None]
    print(f"PyTorch reference on {os.path.relpath(test_image_path, REPO_ROOT)} …")
    with torch.no_grad():
        reference = wrapped(test_t)[0, 0].numpy()
    assert 0 <= reference.min() and reference.max() <= 1, "the matte is not in [0, 1]; wrong output picked?"

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
        outputs=[ct.TensorType(name="mask")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.CPU_AND_GPU,
        minimum_deployment_target=ct.target.macOS15,
    )
    print(f"  converted in {time.time()-t1:.0f}s")
    licence = f"Apache-2.0 ({CODE_URL})"
    mlmodel.short_description = "MODNet portrait matting: RGB image in, soft matte [0,1] out"
    mlmodel.author = "Latent"
    mlmodel.license = licence
    mlmodel.user_defined_metadata["author"] = "Latent"
    mlmodel.user_defined_metadata["source"] = CODE_URL
    mlmodel.user_defined_metadata["license"] = licence
    mlmodel.user_defined_metadata["revision"] = CODE_REVISION
    mlmodel.user_defined_metadata["weights"] = WEIGHTS_NAME
    mlmodel.user_defined_metadata["weights_sha256"] = WEIGHTS_SHA256
    mlmodel.user_defined_metadata["input_size"] = str(args.size)
    mlmodel.user_defined_metadata["input"] = "image: RGB 0-255, (x/255 - 0.5)/0.5 normalisation is inside the graph"
    mlmodel.user_defined_metadata["output"] = "mask: (1, 1, H, W) float, sigmoid applied inside the graph, 1 = foreground"

    os.makedirs(out_dir, exist_ok=True)
    mlmodel.save(package)
    print(f"Wrote {package} ({latent_manifest.package_size(package)/1e6:.1f} MB) in {time.time()-t0:.0f}s")

# ------------------------------------------------------------------- 5. verify
failed = False
if not args.skip_verify:
    print("Verifying …")

    def iou(a, b, thr=0.5):
        a, b = a > thr, b > thr
        return (a & b).sum() / max((a | b).sum(), 1)

    for cu in (ct.ComputeUnit.CPU_AND_GPU, ct.ComputeUnit.CPU_ONLY):
        t2 = time.time()
        loaded = ct.models.MLModel(package, compute_units=cu)
        load_s = time.time() - t2
        out = loaded.predict({"image": test_img})["mask"]        # warm-up
        times = []
        for _ in range(args.runs):
            t3 = time.time(); out = loaded.predict({"image": test_img})["mask"]; times.append(time.time() - t3)
        got = np.asarray(out, dtype=np.float32)[0, 0]
        score = iou(got, reference)
        print(f"  {cu.name:12s} load {load_s:.1f}s  predict {np.median(times)*1000:.0f} ms median "
              f"({args.runs} runs after warm-up)  output {out.shape} {out.dtype}")
        print(f"               vs PyTorch fp32: max |diff| {np.abs(got - reference).max():.4f}, "
              f"mean |diff| {np.abs(got - reference).mean():.5f}, IoU@0.5 {score:.4f}")
        # The app runs imported models at cpuAndGPU at most, so the GPU
        # path is the one the IoU criterion applies to.
        if cu == ct.ComputeUnit.CPU_AND_GPU and score < 0.97:
            print(f"  FAILED: IoU {score:.4f} on the GPU path is under 0.97")
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
    id=MODEL_ID, display_name="MODNet", purpose="Subject masks for portraits: a soft matte with hair, people only",
    version=1, kind="subjectSegmentation", licence_name="Apache-2.0", licence_url=LICENCE_URL, commercial_use=True,
    source_url=CODE_URL, input_size=args.size, packages=[row],
    output_activation="probabilities", refine="guided",
    converter={"script": "scripts/convert_modnet.py", "sourceRevision": CODE_REVISION,
               "coremltools": ct.__version__, "torch": torch.__version__.split("+")[0],
               "date": datetime.date.today().isoformat()})
print(f"Wrote {latent_manifest.write_manifest(manifest, out_dir)}")
