#!/usr/bin/env python3
"""
Writes and checks the `<id>.model.json` manifest that sits beside a model's
Core ML package(s) in Sources/MLKit/Resources/Models (bundled) or in
`~/Library/Application Support/latent/external/<id>/` (imported). The shape
is `ModelManifest` in Sources/MLKit/ModelManifest.swift; docs/Retouch.md
contract A is the reference, and the field names here must match it to the
letter because a Swift `Codable` decoder reads the file.

Write a manifest (one package, a subject model):

    python scripts/latent_manifest.py Sources/MLKit/Resources/Models/BiRefNet_lite.mlpackage \
        --id birefnet-lite --display-name "BiRefNet Lite" --kind subjectSegmentation \
        --purpose "Subject masks: one shot, no prompt" --input-size 1024 \
        --licence-name MIT --licence-url https://github.com/ZhengPeng7/BiRefNet/blob/main/LICENSE \
        --source-url https://huggingface.co/ZhengPeng7/BiRefNet_lite \
        --output-activation probabilities --compute-units cpuAndGPU \
        --converter-script scripts/convert_birefnet.py --source-revision aa62cd8… \
        --out Sources/MLKit/Resources/Models

Several packages with roles (a prompted model): give each package as
`path@role`, in the order the manifest should list them:

    python scripts/latent_manifest.py \
        SAM2_1SmallImageEncoderFLOAT16.mlpackage@imageEncoder \
        SAM2_1SmallPromptEncoderFLOAT16.mlpackage@promptEncoder \
        SAM2_1SmallMaskDecoderFLOAT16.mlpackage@maskDecoder \
        --id sam2.1-small --kind promptedSegmentation … --out Sources/MLKit/Resources/Models

Check existing manifests (the packages are looked up beside each file):

    python scripts/latent_manifest.py --check Sources/MLKit/Resources/Models/*.model.json

Print one package's content hash:

    python scripts/latent_manifest.py --hash Some.mlpackage

The package hash is SHA-256 over the three files a Core ML package holds,
`Manifest.json`, `Data/com.apple.CoreML/model.mlmodel` and
`Data/com.apple.CoreML/weights/weight.bin`, in that order, each fed to one
hasher as the relative-path bytes, a 0x00 byte, then the file bytes. A
package holding any other regular file is refused, so a stray file can
never be smuggled past the hash. `PackageHash.sha256(ofPackageAt:)` in
MLKit computes the same value; it keys the compile cache and catches
corruption, which is why a re-conversion (never byte-identical) means a new
manifest.

Feature names are read from the package spec through coremltools, so the
manifest states what the package really accepts and the importer can
compare them. coremltools is imported only when it is needed; `--hash` and
a hash-only `--check` (`--no-features`) run without it.
"""
import argparse
import hashlib
import json
import os
import re
import sys

HASHED_FILES = ["Manifest.json",
                "Data/com.apple.CoreML/model.mlmodel",
                "Data/com.apple.CoreML/weights/weight.bin"]
ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9.-]{0,63}$")
KINDS = ["promptedSegmentation", "subjectSegmentation", "semanticSegmentation", "denoise"]
COMPUTE_UNITS = ["cpuOnly", "cpuAndGPU", "cpuAndNeuralEngine", "all"]
ACTIVATIONS = ["sigmoid", "probabilities"]
REFINES = ["none", "guided"]
ROLES = ["imageEncoder", "promptEncoder", "maskDecoder"]
# What a conversion script writes for a revision or weight hash it has not
# vetted yet. A script must refuse to run while any pin it needs still
# reads this, so an unvetted upload never becomes a package.
PLACEHOLDER = "<pin me>"


class PackageError(Exception):
    """A package that cannot be hashed: a hashed file missing, or a file present that is not one of the three."""


def package_hash(package):
    """SHA-256 of a package's contents, as `PackageHash.sha256(ofPackageAt:)` computes it."""
    package = os.path.normpath(package)
    expected = set(HASHED_FILES)
    for root, _, files in os.walk(package):
        for name in files:
            rel = os.path.relpath(os.path.join(root, name), package).replace(os.sep, "/")
            if rel not in expected:
                raise PackageError(f"{package}: unexpected file {rel}")
    h = hashlib.sha256()
    for rel in HASHED_FILES:
        path = os.path.join(package, *rel.split("/"))
        if not os.path.isfile(path):
            raise PackageError(f"{package}: missing {rel}")
        h.update(rel.encode("utf-8"))
        h.update(b"\x00")
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
    return h.hexdigest()


def file_sha256(path):
    """SHA-256 of one file, streamed; what the conversion scripts pin their
    downloaded weights against."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def package_size(package):
    """Bytes of every file in the package (the three hashed ones, once the hash has passed)."""
    return sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(package) for f in fs)


def feature_names(package):
    """(input names, output names) from the package spec, in the model's own order."""
    import coremltools as ct   # slow import; only for callers that need the spec
    spec = ct.utils.load_spec(package)
    return ([f.name for f in spec.description.input],
            [f.name for f in spec.description.output])


def package_entry(package, role=None, features=True):
    """One `packages[]` row for `package`: name, role, hash and feature names."""
    entry = {"name": os.path.basename(os.path.normpath(package))}
    if role is not None:
        entry["role"] = role
    entry["sha256"] = package_hash(package)
    inputs, outputs = feature_names(package) if features else ([], [])
    entry["inputNames"] = inputs
    entry["outputNames"] = outputs
    return entry


def build_manifest(*, id, display_name, purpose, version, kind, licence_name, licence_url,
                   commercial_use, source_url, input_size, packages,
                   output_activation=None, refine=None, labels_file=None,
                   compute_units=None, converter=None):
    """The manifest dictionary, keys in the contract's order. `packages` are
    rows from `package_entry`; the size is summed from their packages, so
    every package row must carry `_bytes` or the caller passes it."""
    if not ID_PATTERN.match(id):
        raise ValueError(f"id {id!r} does not match {ID_PATTERN.pattern}")
    if kind not in KINDS:
        raise ValueError(f"kind {kind!r} is not one of {KINDS}")
    for url in (licence_url, source_url):
        if not re.match(r"^https?://", url):
            raise ValueError(f"{url!r} is not an http(s) URL")
    size_bytes = sum(p.pop("_bytes", 0) for p in packages)
    manifest = {
        "id": id,
        "displayName": display_name,
        "purpose": purpose,
        "version": version,
        "kind": kind,
        "licence": {"name": licence_name, "url": licence_url, "commercialUse": commercial_use},
        "sourceURL": source_url,
        "sizeMB": round(size_bytes / 1e6),
        "inputSize": input_size,
        "packages": packages,
    }
    if output_activation is not None:
        manifest["outputActivation"] = output_activation
    if refine is not None:
        manifest["refine"] = refine
    if labels_file is not None:
        manifest["labelsFile"] = labels_file
    if compute_units is not None:
        manifest["computeUnits"] = compute_units
    if converter is not None:
        manifest["converter"] = {k: v for k, v in converter.items() if v is not None}
    return manifest


def write_manifest(manifest, out_dir):
    """Writes `<id>.model.json` into `out_dir` and returns its path."""
    path = os.path.join(out_dir, manifest["id"] + ".model.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
        f.write("\n")
    return path


def check_manifest(path, features=True):
    """Verifies every package named by the manifest at `path`, beside it:
    present, content hash equal, and (with coremltools) the feature names
    equal. Returns a list of problems; empty means the manifest is good."""
    problems = []
    with open(path, encoding="utf-8") as f:
        manifest = json.load(f)
    folder = os.path.dirname(os.path.abspath(path))
    if not ID_PATTERN.match(manifest.get("id", "")):
        problems.append(f"id {manifest.get('id')!r} does not match {ID_PATTERN.pattern}")
    if os.path.basename(path) != manifest.get("id", "") + ".model.json":
        problems.append(f"file name does not match id {manifest.get('id')!r}")
    if manifest.get("kind") not in KINDS:
        problems.append(f"kind {manifest.get('kind')!r} is not one of {KINDS}")
    for key in ("sourceURL",):
        if not re.match(r"^https?://", str(manifest.get(key, ""))):
            problems.append(f"{key} is not an http(s) URL")
    if not re.match(r"^https?://", str(manifest.get("licence", {}).get("url", ""))):
        problems.append("licence.url is not an http(s) URL")
    if manifest.get("labelsFile") and not os.path.isfile(os.path.join(folder, manifest["labelsFile"])):
        problems.append(f"labels file {manifest['labelsFile']} is missing")
    for row in manifest.get("packages", []):
        package = os.path.join(folder, row["name"])
        if not os.path.isdir(package):
            problems.append(f"{row['name']}: package missing")
            continue
        try:
            digest = package_hash(package)
        except PackageError as e:
            problems.append(str(e))
            continue
        if row.get("sha256") is None:
            problems.append(f"{row['name']}: sha256 is null (a catalogue row, not an installable manifest)")
        elif digest != row["sha256"]:
            problems.append(f"{row['name']}: hash {digest} != manifest {row['sha256']}")
        if features:
            inputs, outputs = feature_names(package)
            if inputs != row.get("inputNames"):
                problems.append(f"{row['name']}: inputs {inputs} != manifest {row.get('inputNames')}")
            if outputs != row.get("outputNames"):
                problems.append(f"{row['name']}: outputs {outputs} != manifest {row.get('outputNames')}")
    return problems


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("paths", nargs="*", help="package paths, each optionally `path@role`; manifests with --check")
    p.add_argument("--check", action="store_true", help="verify the manifests given as paths and exit")
    p.add_argument("--hash", metavar="PACKAGE", help="print one package's content hash and exit")
    p.add_argument("--no-features", action="store_true",
                   help="skip the feature-name comparison in --check (no coremltools needed)")
    w = p.add_argument_group("writing a manifest")
    w.add_argument("--id")
    w.add_argument("--display-name")
    w.add_argument("--purpose", help="one line for the settings row, e.g. 'Subject masks: one shot, no prompt'")
    w.add_argument("--version", type=int, default=1, help="the model's version in Latent; bumps when the package changes")
    w.add_argument("--kind", choices=KINDS)
    w.add_argument("--licence-name")
    w.add_argument("--licence-url")
    w.add_argument("--no-commercial-use", action="store_true",
                   help="the licence or the training data forbid commercial use (shown as 'Research use only')")
    w.add_argument("--source-url")
    w.add_argument("--input-size", type=int, help="square input, pixels")
    w.add_argument("--output-activation", choices=ACTIVATIONS,
                   help="subject kinds: 'sigmoid' when the graph outputs logits, 'probabilities' when it applies sigmoid itself")
    w.add_argument("--refine", choices=REFINES, help="subject kinds: guided-filter refinement of the mask")
    w.add_argument("--labels-file", help="semantic kinds: the class-names JSON beside the package")
    w.add_argument("--compute-units", choices=COMPUTE_UNITS,
                   help="a ceiling the registry applies; leave unset unless the model fails on some unit")
    w.add_argument("--converter-script")
    w.add_argument("--source-revision")
    w.add_argument("--coremltools")
    w.add_argument("--torch")
    w.add_argument("--date", help="conversion date, YYYY-MM-DD")
    w.add_argument("--out", help="directory for <id>.model.json (default: the first package's folder)")
    args = p.parse_args(argv)

    if args.hash:
        print(package_hash(args.hash))
        return 0

    if args.check:
        if not args.paths:
            p.error("--check needs at least one manifest")
        failed = False
        for path in args.paths:
            problems = check_manifest(path, features=not args.no_features)
            if problems:
                failed = True
                print(f"{path}: FAILED")
                for problem in problems:
                    print(f"  {problem}")
            else:
                print(f"{path}: ok")
        return 1 if failed else 0

    required = ["paths", "id", "display_name", "purpose", "kind", "licence_name", "licence_url",
                "source_url", "input_size"]
    missing = [name for name in required if not getattr(args, name)]
    if missing:
        p.error("writing a manifest needs " + ", ".join("package paths" if m == "paths" else "--" + m.replace("_", "-") for m in missing))

    rows = []
    for spec in args.paths:
        path, _, role = spec.partition("@")
        if role and role not in ROLES:
            p.error(f"role {role!r} is not one of {ROLES}")
        row = package_entry(path, role or None)
        row["_bytes"] = package_size(path)
        rows.append(row)
    converter = None
    if args.converter_script:
        converter = {"script": args.converter_script, "sourceRevision": args.source_revision,
                     "coremltools": args.coremltools, "torch": args.torch, "date": args.date}
    manifest = build_manifest(
        id=args.id, display_name=args.display_name, purpose=args.purpose, version=args.version,
        kind=args.kind, licence_name=args.licence_name, licence_url=args.licence_url,
        commercial_use=not args.no_commercial_use, source_url=args.source_url,
        input_size=args.input_size, packages=rows, output_activation=args.output_activation,
        refine=args.refine, labels_file=args.labels_file, compute_units=args.compute_units,
        converter=converter)
    out_dir = args.out or os.path.dirname(os.path.abspath(args.paths[0].partition("@")[0]))
    path = write_manifest(manifest, out_dir)
    print(f"Wrote {path} ({manifest['sizeMB']} MB, {len(rows)} package{'s' if len(rows) != 1 else ''})")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (PackageError, ValueError) as e:
        sys.exit(f"error: {e}")
