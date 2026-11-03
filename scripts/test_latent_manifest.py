#!/usr/bin/env python3
"""
Checks scripts/latent_manifest.py on fake packages, with no Core ML.

    python scripts/test_latent_manifest.py

A fake `.mlpackage` here is just the three files the content hash reads,
which is all `--check --no-features` and the manifest writer look at. It
covers where an `--inside` manifest's labels file is looked for (the
package's root, where Add Model… reads it), that the writer never names a
labels file that is not there, and the git file limit that only the
bundled Models folder is held to. Prints a line per check and exits
non-zero if any fails.
"""
import contextlib
import io
import json
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import latent_manifest

failures = []


def check(label, got, want):
    ok = got == want
    print(("  ok    " if ok else "  FAIL  ") + label)
    if not ok:
        failures.append(label)
        print(f"          got  {got!r}\n          want {want!r}")


def run(argv):
    """main()'s exit code and its output, whichever way it returns."""
    buffer = io.StringIO()
    try:
        with contextlib.redirect_stdout(buffer), contextlib.redirect_stderr(buffer):
            code = latent_manifest.main(argv)
    except SystemExit as e:
        code = e.code
    return code, buffer.getvalue()


def fake_package(folder, name="Model.mlpackage"):
    package = os.path.join(folder, name)
    for relative in latent_manifest.HASHED_FILES:
        path = os.path.join(package, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(relative.encode())
    return package


def write_labels(path):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(["sky", "person"], f)


WRITE = ["--inside", "--id", "m", "--display-name", "M", "--purpose", "Classes", "--kind",
         "semanticSegmentation", "--licence-name", "MIT", "--licence-url", "https://example.com/l",
         "--source-url", "https://example.com/s", "--input-size", "512", "--labels-file"]


def main():
    work = tempfile.mkdtemp(prefix="latent_manifest-test-")
    # Writing a manifest reads feature names through coremltools; a fake
    # package has none to read, and nothing checked here depends on them.
    latent_manifest.feature_names = lambda package: (["image"], ["logits"])

    print("an --inside class model with its labels at the package's root")
    package = fake_package(os.path.join(work, "a"))
    write_labels(os.path.join(package, "labels.json"))
    code, text = run([package] + WRITE + ["labels.json"])
    check("the manifest is written", code, 0)
    manifest = os.path.join(package, "m.model.json")
    check("--check finds the labels where Add Model… reads them",
          latent_manifest.check_manifest(manifest, features=False), [])

    print("the same manifest with the labels beside the package instead")
    os.rename(os.path.join(package, "labels.json"), os.path.join(work, "a", "labels.json"))
    problems = latent_manifest.check_manifest(manifest, features=False)
    check("--check says they are missing, as Add Model… would",
          any("labels file labels.json is missing" in p for p in problems), True)

    print("--inside given a labels file from elsewhere copies it in")
    package = fake_package(os.path.join(work, "b"))
    outside = os.path.join(work, "b-labels.json")
    write_labels(outside)
    code, _ = run([package] + WRITE + [outside])
    check("the manifest is written", code, 0)
    check("the labels file is now at the package's root",
          os.path.isfile(os.path.join(package, "b-labels.json")), True)
    with open(os.path.join(package, "m.model.json"), encoding="utf-8") as f:
        check("and named by its bare name", json.load(f).get("labelsFile"), "b-labels.json")
    check("--check agrees", latent_manifest.check_manifest(os.path.join(package, "m.model.json"),
                                                           features=False), [])

    print("a labels file that is nowhere is refused")
    package = fake_package(os.path.join(work, "c"))
    code, text = run([package] + WRITE + ["nowhere.json"])
    check("no manifest written", os.path.exists(os.path.join(package, "m.model.json")), False)
    check("it says why", code != 0 and "nowhere.json is not in" in text, True)

    print("the git file limit applies to the bundled folder only")
    big = 446 * 1000 * 1000
    check("a 446 MB general/portrait package in its own folder passes",
          latent_manifest.over_bundled_limit(os.path.join(work, "birefnet-general"), big), False)
    check("a 101 MiB package in the bundled Models folder fails",
          latent_manifest.over_bundled_limit(latent_manifest.BUNDLED_MODELS, 101 * 1024 * 1024), True)
    check("a 96 MiB package in the bundled Models folder passes",
          latent_manifest.over_bundled_limit(latent_manifest.BUNDLED_MODELS, 96 * 1024 * 1024), False)

    shutil.rmtree(work)
    print()
    if failures:
        print(f"FAILED: {len(failures)} check{'s' if len(failures) != 1 else ''} — " + "; ".join(failures))
        return 1
    print("latent_manifest.py agrees with Add Model… on where things are")
    return 0


if __name__ == "__main__":
    sys.exit(main())
