#!/usr/bin/env python3
"""
Checks scripts/pin_model.py against copies of the real conversion scripts.

    python scripts/test_pin_model.py

pin_model.py rewrites the conversion scripts in place to record a pin, so
this exercises that editor on every pin shape in the folder before anyone
trusts it with the real files: a revision and three package hashes inside
SIZES (convert_sam2.py), a table row beside one that is already pinned
(convert_birefnet.py), a module constant and a table row in a file full of
non-ASCII (convert_u2net.py), and two module constants (convert_modnet.py).
It also walks the paths through main() that need no network.

Nothing here downloads anything, nothing needs coremltools or torch, and
the scripts in this folder are copied to a temporary directory first, so a
failure cannot leave a half-edited file behind. It prints a line per check
and exits non-zero if any fails.
"""
import contextlib
import hashlib
import io
import os
import py_compile
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import latent_manifest
import pin_model

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
REVISION = "0123456789abcdef0123456789abcdef01234567"
HASHES = {role: f"{i:064x}" for i, role in enumerate(["imageEncoder", "promptEncoder", "maskDecoder"])}
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
            code = pin_model.main(argv)
    except SystemExit as e:
        code = e.code
    return code, buffer.getvalue()


def refuses(label, argv, phrase):
    """A run that must stop with a sentence saying why."""
    code, text = run(argv)
    check(label, isinstance(code, str) and phrase in code, True)
    if isinstance(code, str) and phrase not in code:
        print(f"          said {code!r}")


def fresh(work, name):
    """A copy of scripts/ that nothing has pinned yet, for pin_model to edit."""
    folder = os.path.join(work, name)
    shutil.copytree(SCRIPTS, folder)
    pin_model.SCRIPTS = folder
    return folder


def main():
    work = tempfile.mkdtemp(prefix="pin_model-test-")
    fresh(work, "editor")
    placeholder = latent_manifest.PLACEHOLDER

    print("convert_sam2.py: a revision and three package hashes in SIZES['large']")
    before = open(os.path.join(pin_model.SCRIPTS, "convert_sam2.py"), "rb").read()
    pin_model.write_pins("convert_sam2.py",
                         [(("SIZES", "large", "revision"), None, REVISION)] +
                         [(("SIZES", "large", "package_sha256"), role, digest)
                          for role, digest in HASHES.items()])
    check("the revision reads back",
          pin_model.read_pin("convert_sam2.py", ("SIZES", "large", "revision")), REVISION)
    for role, digest in HASHES.items():
        check(f"the {role} hash reads back",
              pin_model.read_pin("convert_sam2.py", ("SIZES", "large", "package_sha256"), role), digest)
    check("the other sizes are untouched",
          pin_model.read_pin("convert_sam2.py", ("SIZES", "tiny", "revision")), placeholder)
    after = open(os.path.join(pin_model.SCRIPTS, "convert_sam2.py"), "rb").read()
    changed = sum(1 for a, b in zip(before.decode().splitlines(), after.decode().splitlines()) if a != b)
    check("only the two lines of that row changed", changed, 2)   # the three hashes share one line

    print("convert_birefnet.py: an unpinned row beside one that is pinned")
    lite = pin_model.read_pin("convert_birefnet.py", ("VARIANTS", "lite", "revision"))
    pin_model.write_pins("convert_birefnet.py",
                         [(("VARIANTS", "general", "revision"), None, REVISION),
                          (("VARIANTS", "general", "weights_sha256"), None, HASHES["imageEncoder"])])
    check("general is pinned",
          pin_model.read_pin("convert_birefnet.py", ("VARIANTS", "general", "revision")), REVISION)
    check("lite keeps the pin it had",
          pin_model.read_pin("convert_birefnet.py", ("VARIANTS", "lite", "revision")), lite)

    print("convert_u2net.py: a constant and a table row, in a file holding non-ASCII")
    pin_model.write_pins("convert_u2net.py",
                         [("CODE_REVISION", None, REVISION),
                          (("VARIANTS", "small", "weights_sha256"), None, HASHES["maskDecoder"])])
    check("the constant reads back", pin_model.read_pin("convert_u2net.py", "CODE_REVISION"), REVISION)
    check("the row reads back",
          pin_model.read_pin("convert_u2net.py", ("VARIANTS", "small", "weights_sha256")), HASHES["maskDecoder"])
    check("the other row is untouched",
          pin_model.read_pin("convert_u2net.py", ("VARIANTS", "full", "weights_sha256")), placeholder)
    source = open(os.path.join(pin_model.SCRIPTS, "convert_u2net.py"), encoding="utf-8").read()
    check("the text around it survived", 'display_name="U²-Net Small"' in source, True)

    print("convert_modnet.py: two module constants")
    pin_model.write_pins("convert_modnet.py",
                         [("CODE_REVISION", None, REVISION), ("WEIGHTS_SHA256", None, HASHES["promptEncoder"])])
    check("CODE_REVISION", pin_model.read_pin("convert_modnet.py", "CODE_REVISION"), REVISION)
    check("WEIGHTS_SHA256", pin_model.read_pin("convert_modnet.py", "WEIGHTS_SHA256"), HASHES["promptEncoder"])

    print("every edited script still compiles")
    for name in ("convert_sam2.py", "convert_birefnet.py", "convert_u2net.py", "convert_modnet.py"):
        py_compile.compile(os.path.join(pin_model.SCRIPTS, name), doraise=True)
    check("all four compile", True, True)

    print("a pin that is not the shape it expects is refused, not guessed at")
    for where in ("NO_SUCH_CONSTANT", ("SIZES", "enormous", "revision"), ("SIZES", "large", "no_such_field")):
        try:
            pin_model.read_pin("convert_sam2.py", where)
            check(f"{where} refused", "read it anyway", "PinShapeError")
        except pin_model.PinShapeError:
            check(f"{where} refused", True, True)

    print("the refusals in main()")
    fresh(work, "cli")
    weights = os.path.join(work, "u2net.pth")
    with open(weights, "wb") as f:
        f.write(b"not a checkpoint, but it hashes like one")
    out = os.path.join(work, "out")
    refuses("an id the catalogue does not hold", ["not-a-model"], "not in ModelCatalog.json")
    refuses("weights that are not on Hugging Face need --from-file",
            ["u2net", "--yes", "--no-convert", "--out", out], "--from-file")
    refuses("--from-file pointing at nothing",
            ["u2net", "--yes", "--no-convert", "--out", out, "--from-file", "/nowhere.pth"],
            "there is no file at")
    refuses("no --code-revision and no pin to fall back on",
            ["u2net", "--yes", "--no-convert", "--out", out, "--from-file", weights], "--code-revision")

    print("the weights-from-disk path, stopping before the conversion")
    code, text = run(["u2net", "--yes", "--no-convert", "--out", out,
                      "--from-file", weights, "--code-revision", "53dc9da"])
    check("it finishes", code, 0)
    check("it says what it pinned", "Pinned scripts/convert_u2net.py" in text, True)
    check("the commit is recorded", pin_model.read_pin("convert_u2net.py", "CODE_REVISION"), "53dc9da")
    check("the weights hash is the file's",
          pin_model.read_pin("convert_u2net.py", ("VARIANTS", "full", "weights_sha256")),
          hashlib.sha256(open(weights, "rb").read()).hexdigest())

    print("moving a pin that is already recorded")
    refuses("refused on its own", ["u2net", "--yes", "--no-convert", "--out", out,
                                   "--from-file", weights, "--code-revision", "aaaaaaa"], "--repin")
    code, _ = run(["u2net", "--yes", "--no-convert", "--repin", "--out", out,
                   "--from-file", weights, "--code-revision", "aaaaaaa"])
    check("allowed with --repin", code, 0)

    print("--resolve writes nothing, even for a model with no revision to resolve")
    before = open(os.path.join(pin_model.SCRIPTS, "convert_u2net.py"), "rb").read()
    code, text = run(["u2net", "--resolve", "--from-file", weights, "--code-revision", "bbbbbbb", "--out", out])
    check("it finishes", code, 0)
    check("it says there is nothing to resolve", "no revision to resolve" in text, True)
    check("the script was not written to",
          open(os.path.join(pin_model.SCRIPTS, "convert_u2net.py"), "rb").read(), before)

    print("the plan, which reaches nothing")
    for model in sorted(pin_model.PINS):
        code, text = run([model, "--out", out])
        check(f"{model} has a plan", code == 0 and "Nothing has been downloaded" in text, True)
    code, text = run(["--list"])
    check("--list names every catalogue row", code == 0 and text.count("\n") >= len(pin_model.catalogue()), True)

    shutil.rmtree(work)
    print()
    if failures:
        print(f"FAILED: {len(failures)} check{'s' if len(failures) != 1 else ''} — " + "; ".join(failures))
        return 1
    print("pin_model.py behaves on every pin shape in this folder")
    return 0


if __name__ == "__main__":
    sys.exit(main())
