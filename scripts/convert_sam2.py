#!/usr/bin/env python3
"""
Fetch one of Apple's Core ML conversions of Segment Anything 2.1 (click to
select) and write the folder Latent's Settings › AI › Models adds: the three
packages plus the `<id>.model.json` manifest the model registry reads.

    source ~/latent-ml/bin/activate
    python scripts/convert_sam2.py --size tiny                # writes ./sam2.1-tiny/
    python scripts/convert_sam2.py --size large --out ~/Models/sam2.1-large
    python scripts/convert_sam2.py --size small --from-local Sources/MLKit/Resources/Models --out /tmp/sam2.1-small
    python scripts/convert_sam2.py --size tiny --verify-only  # re-check the packages already in --out

There is nothing to convert: Apple publishes the fp16 ML Programs
(apple/coreml-sam2.1-tiny, -small, -baseplus, -large on Hugging Face, from
Meta's Apache-2.0 weights), so this script downloads, checks, verifies and
describes them. The bundled SAM 2.1 Small came from the same place, which
is what `--from-local` is for: it takes a folder that already holds a set of
three packages (the bundled ones, or a download made by hand) and writes
the manifest for them, so the bundled manifest can be reproduced and
diffed.

What it does, step by step:

1. Downloads the repository at a pinned revision (the HF git commit that
   was vetted) and picks the three packages by name: `<prefix>ImageEncoder`,
   `<prefix>PromptEncoder` and `<prefix>MaskDecoder`, FLOAT16. A size whose
   revision or package hashes are still the `<pin me>` placeholder refuses
   to download until someone has looked at the upload and recorded them.
2. Copies the packages into the output folder (the HF cache holds symlinks
   into its blob store, and the folder the user adds must stand alone) and
   hashes each one with the package content hash `latent_manifest.py`
   defines. A hash that differs from the pinned value stops the run: a
   changed upload must be looked at, not silently trusted.
3. Verifies the chain the app runs: image encoder on a test photo, prompt
   encoder with one foreground point at the centre, mask decoder with the
   embeddings (the decoder names its prompt inputs `sparse_embedding` and
   `dense_embedding` while the prompt encoder outputs the plural forms;
   MLKit's SAM2Models maps them the same way). Shapes, finite scores, a
   mask that covers some but not all of the photo, and two identical runs;
   plus timing on CPU_AND_GPU and CPU_ONLY. There is no PyTorch reference to
   compare against here (Apple did the conversion), so this is a
   plausibility check, not an accuracy one.
4. Writes `<id>.model.json` last, through scripts/latent_manifest.py, with
   each package's role, content hash and the feature names read from the
   package spec.
"""
import argparse
import datetime
import glob
import os
import shutil
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import latent_manifest

REPO_ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
LICENCE_URL = "https://github.com/facebookresearch/sam2/blob/main/LICENSE"
ROLES = {"imageEncoder": "ImageEncoder", "promptEncoder": "PromptEncoder", "maskDecoder": "MaskDecoder"}
PLACEHOLDER = latent_manifest.PLACEHOLDER

# Each size is pinned to the Hugging Face repository revision that was
# vetted and to the content hash of each package at that revision (the
# same value the manifest records, so `latent_manifest.py --check` agrees
# with the pin). Small is bundled; its row exists for --from-local.
SIZES = {
    "tiny": dict(
        repo="apple/coreml-sam2.1-tiny", prefix="SAM2_1Tiny",
        revision=PLACEHOLDER,
        package_sha256={"imageEncoder": PLACEHOLDER, "promptEncoder": PLACEHOLDER, "maskDecoder": PLACEHOLDER},
        id="sam2.1-tiny", display_name="SAM 2.1 Tiny",
        purpose="Click to select: the smallest SAM, quickest to encode",
    ),
    "small": dict(
        repo="apple/coreml-sam2.1-small", prefix="SAM2_1Small",
        revision=PLACEHOLDER,
        package_sha256={"imageEncoder": PLACEHOLDER, "promptEncoder": PLACEHOLDER, "maskDecoder": PLACEHOLDER},
        id="sam2.1-small", display_name="SAM 2.1 Small",
        purpose="Click to select: masks from points you place",
    ),
    "base-plus": dict(
        repo="apple/coreml-sam2.1-baseplus", prefix="SAM2_1BasePlus",
        revision=PLACEHOLDER,
        package_sha256={"imageEncoder": PLACEHOLDER, "promptEncoder": PLACEHOLDER, "maskDecoder": PLACEHOLDER},
        id="sam2.1-base-plus", display_name="SAM 2.1 Base+",
        purpose="Click to select: better edges than Small at twice the size",
    ),
    "large": dict(
        repo="apple/coreml-sam2.1-large", prefix="SAM2_1Large",
        revision="e830c0874326be7ada2bdc9dff23b7073f884a83",
        package_sha256={"imageEncoder": "74e9fc4ab5a99c3352a38a869840c984d8a7d92b80607db99c205c992e161968", "promptEncoder": "30bff6bec4a99b8fddab20e9f5bc70ef49818c4511b8ad387c740b66a5f44117", "maskDecoder": "8e7289117c6555061fd25b303465e6daafd101462511e9e0efae30d73dc019a1"},
        id="sam2.1-large", display_name="SAM 2.1 Large",
        purpose="Click to select: the best hair and fine edges, needs memory",
    ),
}


def find_packages(folder, prefix):
    """The three packages of one size in `folder`, by role. Refuses a
    folder with a role missing or given twice, naming what it found, so a
    renamed upload is noticed rather than guessed at."""
    found = {}
    names = sorted(os.path.basename(p) for p in glob.glob(os.path.join(folder, "*.mlpackage")))
    for role, marker in ROLES.items():
        matches = [n for n in names if n.startswith(prefix) and marker in n and "FLOAT16" in n]
        if len(matches) != 1:
            sys.exit(f"expected exactly one {prefix}{marker}…FLOAT16.mlpackage in {folder}, "
                     f"found {matches or 'none'} among {names or 'no packages'}")
        found[role] = os.path.join(folder, matches[0])
    return found


def check_hashes(packages, pins):
    """Content hash of each package against its pin. A placeholder pin is
    only reported (the caller decides whether that is allowed); a real pin
    that differs stops the run."""
    hashes = {}
    for role, package in packages.items():
        digest = latent_manifest.package_hash(package)
        hashes[role] = digest
        pin = pins[role]
        if pin == PLACEHOLDER:
            print(f"  {os.path.basename(package)} {digest} (no pin recorded)")
        elif digest != pin:
            sys.exit(f"{os.path.basename(package)}: content hash {digest} != pinned {pin}; "
                     f"refusing to describe a package that is not the vetted one")
        else:
            print(f"  {os.path.basename(package)} {digest} (matches pin)")
    return hashes


def verify(packages, test_image_path, runs):
    """Runs encoder → prompt encoder → decoder on `test_image_path` with one
    centre point, on the two compute units the app can use, and returns
    False when anything looks wrong."""
    import numpy as np
    import coremltools as ct
    from PIL import Image

    encoder_spec = ct.utils.load_spec(packages["imageEncoder"])
    image_input = encoder_spec.description.input[0].type.imageType
    size = int(image_input.width)
    image = Image.open(test_image_path).convert("RGB").resize((size, size), Image.BILINEAR)
    points = np.array([[[size / 2, size / 2]]], dtype=np.float32)   # (1, N, 2), pixels of the 1024² input
    labels = np.array([[1]], dtype=np.float32)                       # 1 = foreground
    ok = True
    previous = None
    for cu in (ct.ComputeUnit.CPU_AND_GPU, ct.ComputeUnit.CPU_ONLY):
        t0 = time.time()
        encoder = ct.models.MLModel(packages["imageEncoder"], compute_units=cu)
        prompt = ct.models.MLModel(packages["promptEncoder"], compute_units=cu)
        decoder = ct.models.MLModel(packages["maskDecoder"], compute_units=cu)
        load_s = time.time() - t0

        def run():
            embeddings = encoder.predict({"image": image})
            prompts = prompt.predict({"points": points, "labels": labels})
            inputs = {}
            for feature in decoder.get_spec().description.input:
                name = feature.name
                if name in embeddings:
                    inputs[name] = embeddings[name]
                elif name in prompts:
                    inputs[name] = prompts[name]
                elif name + "s" in prompts:              # sparse_embedding ← sparse_embeddings
                    inputs[name] = prompts[name + "s"]
                else:
                    sys.exit(f"decoder input {name!r} is fed by neither the encoder {sorted(embeddings)} "
                             f"nor the prompt encoder {sorted(prompts)}")
            return decoder.predict(inputs)

        out = run()                                       # warm-up
        times = []
        for _ in range(runs):
            t1 = time.time(); out = run(); times.append(time.time() - t1)
        masks = np.asarray(out["low_res_masks"], dtype=np.float32)
        scores = np.asarray(out["scores"], dtype=np.float32)
        best = int(scores.reshape(-1).argmax())
        coverage = float((masks[0, best] > 0).mean())
        print(f"  {cu.name:12s} load {load_s:.1f}s  encode+decode {np.median(times)*1000:.0f} ms median "
              f"({runs} runs after warm-up)  masks {masks.shape}  scores {np.round(scores.reshape(-1), 3).tolist()}")
        print(f"               best candidate {best} covers {coverage*100:.1f}% of the photo")
        if masks.ndim != 4 or masks.shape[1] < 1 or scores.size != masks.shape[1]:
            print("  FAILED: unexpected mask or score shape"); ok = False
        if not np.isfinite(scores).all() or not np.isfinite(masks).all():
            print("  FAILED: non-finite output"); ok = False
        if not 0.001 < coverage < 0.999:
            print("  FAILED: the mask covers nothing or everything"); ok = False
        if previous is not None:
            flipped = float(((masks[0, best] > 0) != (previous > 0)).mean())
            print(f"               vs the other compute unit: {flipped*100:.2f}% of pixels flipped")
        previous = masks[0, best]
        again = np.asarray(run()["low_res_masks"], dtype=np.float32)
        if np.abs(again - masks).max() > 1e-2:
            print(f"  FAILED: two runs differ by {np.abs(again - masks).max():.3f}"); ok = False
    return ok


def metadata_versions(package):
    """(coremltools, torch) versions Apple's conversion recorded in the
    package, for the manifest's converter fields; None when absent."""
    import coremltools as ct
    user = dict(ct.utils.load_spec(package).description.metadata.userDefined)
    source = user.get("com.github.apple.coremltools.source", "")
    torch_version = source.split("==", 1)[1] if source.startswith("torch==") else None
    return user.get("com.github.apple.coremltools.version"), torch_version


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--size", required=True, choices=sorted(SIZES) + ["baseplus"],
                        help="which of Apple's packages (baseplus is accepted for base-plus)")
    parser.add_argument("--from-local", metavar="DIR",
                        help="no download: describe the three packages already in DIR (copied to --out unless "
                             "DIR is --out)")
    parser.add_argument("--out", default=None, help="folder for the packages and manifest (default ./<id>/)")
    parser.add_argument("--test-image", default=None,
                        help="photo for the verify step (default: TestAssets/HSB_6548.jpg, else the portrait)")
    parser.add_argument("--skip-verify", action="store_true")
    parser.add_argument("--verify-only", action="store_true",
                        help="no download, no manifest: run the verify step on the packages already in --out "
                             "(or --from-local)")
    parser.add_argument("--runs", type=int, default=3, help="timed encode+decode runs per compute unit after one warm-up")
    args = parser.parse_args(argv)

    size = SIZES["base-plus" if args.size == "baseplus" else args.size]
    out_dir = os.path.abspath(args.out or size["id"])
    test_image_path = args.test_image
    if test_image_path is None:
        for candidate in ("TestAssets/HSB_6548.jpg", "TestAssets/portrait/zena_cardman_nasa_portrait.jpg"):
            if os.path.isfile(os.path.join(REPO_ROOT, candidate)):
                test_image_path = os.path.join(REPO_ROOT, candidate)
                break
    if test_image_path is None and not args.skip_verify:
        sys.exit("no test photo found under TestAssets; run scripts/fetch_test_assets.sh --portrait or pass --test-image")

    # ------------------------------------------------ 1. download or locate
    if args.verify_only:
        source_dir = os.path.abspath(args.from_local) if args.from_local else out_dir
        packages = find_packages(source_dir, size["prefix"])
    elif args.from_local:
        source_dir = os.path.abspath(args.from_local)
        packages = find_packages(source_dir, size["prefix"])
    else:
        unpinned = [k for k, v in size["package_sha256"].items() if v == PLACEHOLDER]
        if size["revision"] == PLACEHOLDER or unpinned:
            sys.exit(f"--size {args.size} is not pinned yet: vet https://huggingface.co/{size['repo']}, then record "
                     f"its git revision and the content hash of each package (latent_manifest.py --hash) in SIZES "
                     f"before downloading it. Nothing was downloaded.")
        print(f"Downloading {size['repo']} @ {size['revision'][:12]} …")
        from huggingface_hub import snapshot_download
        source_dir = snapshot_download(size["repo"], revision=size["revision"], allow_patterns=["*.mlpackage/*"])
        packages = find_packages(source_dir, size["prefix"])

    # ----------------------------------------------------- 2. copy and hash
    if not args.verify_only and os.path.normpath(source_dir) != os.path.normpath(out_dir):
        os.makedirs(out_dir, exist_ok=True)
        copied = {}
        for role, package in packages.items():
            target = os.path.join(out_dir, os.path.basename(package))
            if os.path.exists(target):
                shutil.rmtree(target)
            shutil.copytree(package, target, symlinks=False)     # resolve the HF cache's blob symlinks
            copied[role] = target
        packages = copied
    print("Hashing …")
    check_hashes(packages, size["package_sha256"])

    # ------------------------------------------------------------ 3. verify
    if not args.skip_verify:
        print(f"Verifying on {os.path.relpath(test_image_path, REPO_ROOT)} …")
        if not verify(packages, test_image_path, args.runs):
            sys.exit("Verification failed; no manifest written")
    if args.verify_only:
        print("Verified")
        return 0

    # ---------------------------------------------------------- 4. manifest
    import coremltools as ct
    rows = []
    for role in ROLES:
        row = latent_manifest.package_entry(packages[role], role)
        row["_bytes"] = latent_manifest.package_size(packages[role])
        rows.append(row)
    encoder_spec = ct.utils.load_spec(packages["imageEncoder"])
    input_size = int(encoder_spec.description.input[0].type.imageType.width)
    coremltools_version, torch_version = metadata_versions(packages["imageEncoder"])
    manifest = latent_manifest.build_manifest(
        id=size["id"], display_name=size["display_name"], purpose=size["purpose"], version=1,
        kind="promptedSegmentation", licence_name="Apache-2.0", licence_url=LICENCE_URL, commercial_use=True,
        source_url=f"https://huggingface.co/{size['repo']}", input_size=input_size, packages=rows,
        converter={"script": f"scripts/convert_sam2.py --size {'base-plus' if args.size == 'baseplus' else args.size}",
                   "sourceRevision": None if size["revision"] == PLACEHOLDER else size["revision"],
                   "coremltools": coremltools_version, "torch": torch_version,
                   "date": datetime.date.today().isoformat()})
    path = latent_manifest.write_manifest(manifest, out_dir)
    print(f"Wrote {path} ({manifest['sizeMB']} MB, 3 packages)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (latent_manifest.PackageError, ValueError) as e:
        sys.exit(f"error: {e}")
