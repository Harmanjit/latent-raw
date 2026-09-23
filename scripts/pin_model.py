#!/usr/bin/env python3
"""
Vet an upstream model, record its pin, and run the conversion script that
writes the folder Settings › AI › Models › Add Model… takes.

    python3.12 -m venv ~/latent-ml && source ~/latent-ml/bin/activate
    pip install -r scripts/requirements-coreml.txt          # all the SAM sizes need
    python scripts/pin_model.py --list                      # the catalogue, and what is pinned
    python scripts/pin_model.py sam2.1-large --out ~/Models/sam2.1-large         # the plan; no network
    python scripts/pin_model.py sam2.1-large --out ~/Models/sam2.1-large --yes   # do it
    python scripts/pin_model.py u2net --from-file ~/Downloads/u2net.pth \
        --code-revision <commit> --out ~/Models/u2net --yes                      # weights fetched by hand

Latent itself never downloads a model: the app has no network entitlement,
and Settings › AI › Models only links to a model's page. This is the other
half of that arrangement — the developer-side step that fetches a model
once, checks it, and leaves a folder to hand to Add Model….

Why a pin exists. Every conversion script pins the upstream revision it
converts and the SHA-256 of what it downloaded, and refuses to run while a
pin still reads `<pin me>` (`latent_manifest.PLACEHOLDER`). That is what
makes a conversion repeatable, and what stops a changed upload being
converted because nobody looked. Recording a pin by hand means finding the
revision, downloading, hashing each package and editing the script by hand.
This does those four in order and writes the pin only when they agree.

What `--yes` does, in order:

1. Asks Hugging Face for the current revision of the model's repository and
   prints it with the files and their sizes, so there is something to look
   at before the bytes arrive. `--revision` takes a particular one instead;
   `--resolve` stops after this step.
2. Downloads at exactly that revision. This is the only step that fetches
   weights, and it happens under `--yes` and nowhere else.
3. Hashes what arrived: the content hash of each `.mlpackage` for a model
   that ships as Core ML packages, the file's SHA-256 for one that ships
   weights. Both are the values `latent_manifest.py` computes.
4. Writes those values into the conversion script, in place, by locating
   the pin in its syntax tree rather than by matching text, then re-reads
   the file to confirm the pin now says what it should. A pin already
   recorded is left alone unless `--repin` says otherwise.
5. Runs the conversion script, which downloads nothing new (the cache is
   warm), checks what it has against the pin just written, verifies the
   package on a test photo and writes `<id>.model.json`.
6. Compares the manifest with the catalogue row the app ships, so a model
   whose upstream has moved on — different packages, different inputs — is
   noticed here rather than by Add Model….

Models whose weights are not on Hugging Face (U²-Net, MODNet, IS-Net link
theirs from a README) cannot be fetched here: download the file yourself,
pass it as `--from-file`, and give the code revision you vetted as
`--code-revision`. Steps 3 to 6 are the same.
"""
import argparse
import ast
import fnmatch
import json
import os
import shlex
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import latent_manifest

REPO_ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SCRIPTS = os.path.join(REPO_ROOT, "scripts")
CATALOGUE = os.path.join(REPO_ROOT, "Sources", "MLKit", "Resources", "Models", "ModelCatalog.json")
PLACEHOLDER = latent_manifest.PLACEHOLDER
# What Settings > AI > Models calls each kind in its "For" column.
KIND_WORDS = {"promptedSegmentation": "Click to select", "subjectSegmentation": "Subject",
              "semanticSegmentation": "Classes", "denoise": "Noise reduction"}
# Every convert_*.py verifies on one of these two unless --test-image names
# another, and stops when neither is there. Looked for here as well, so a
# fresh clone finds out before the download rather than after it.
TEST_PHOTOS = ("TestAssets/HSB_6548.jpg", "TestAssets/portrait/zena_cardman_nasa_portrait.jpg")

# A pin site per catalogue id: which script converts the model, how it is
# invoked, where its weights come from, and where in the script's source the
# pinned values live. `revision` and `weights` are (dict, key, field) inside
# a `NAME = {...}` table, or a plain string for a module-level constant.
#
#   packages   Apple's prebuilt Core ML packages: pin the repository
#              revision and the content hash of each package.
#   weights    one weights file at a Hugging Face revision: pin the
#              revision and the file's SHA-256.
#   file       weights linked from a README: nothing to resolve, so the
#              file comes in as --from-file and the code revision as
#              --code-revision.
PINS = {
    "sam2.1-tiny": dict(script="convert_sam2.py", args=["--size", "tiny"], source="packages",
                        patterns=["*.mlpackage/*"], size_key="tiny",
                        revision=("SIZES", "tiny", "revision"),
                        packages=("SIZES", "tiny", "package_sha256")),
    "sam2.1-base-plus": dict(script="convert_sam2.py", args=["--size", "base-plus"], source="packages",
                             patterns=["*.mlpackage/*"], size_key="base-plus",
                             revision=("SIZES", "base-plus", "revision"),
                             packages=("SIZES", "base-plus", "package_sha256")),
    "sam2.1-large": dict(script="convert_sam2.py", args=["--size", "large"], source="packages",
                         patterns=["*.mlpackage/*"], size_key="large",
                         revision=("SIZES", "large", "revision"),
                         packages=("SIZES", "large", "package_sha256")),
    "birefnet-general": dict(script="convert_birefnet.py", args=["--variant", "general"], source="weights",
                             weights_file="model.safetensors", patterns=["*.py", "*.json", "*.safetensors"],
                             revision=("VARIANTS", "general", "revision"),
                             weights=("VARIANTS", "general", "weights_sha256")),
    "birefnet-portrait": dict(script="convert_birefnet.py", args=["--variant", "portrait"], source="weights",
                              weights_file="model.safetensors", patterns=["*.py", "*.json", "*.safetensors"],
                              revision=("VARIANTS", "portrait", "revision"),
                              weights=("VARIANTS", "portrait", "weights_sha256")),
    "u2net": dict(script="convert_u2net.py", args=[], source="file", weights_arg="--weights",
                  code_url="https://github.com/xuebinqin/U-2-Net",
                  revision="CODE_REVISION", weights=("VARIANTS", "full", "weights_sha256")),
    "u2net-small": dict(script="convert_u2net.py", args=["--small"], source="file", weights_arg="--weights",
                        code_url="https://github.com/xuebinqin/U-2-Net",
                        revision="CODE_REVISION", weights=("VARIANTS", "small", "weights_sha256")),
    "modnet": dict(script="convert_modnet.py", args=[], source="file", weights_arg="--weights",
                   code_url="https://github.com/ZHKKKe/MODNet",
                   revision="CODE_REVISION", weights="WEIGHTS_SHA256"),
    "isnet": dict(script="convert_isnet.py", args=[], source="file", weights_arg="--weights",
                  code_url="https://github.com/xuebinqin/DIS",
                  revision="CODE_REVISION", weights="WEIGHTS_SHA256"),
}


# --------------------------------------------------------------- catalogue

def catalogue():
    """ModelCatalog.json, the rows Settings shows as models you can add.
    It is the app's own idea of what each model is, so it decides here
    what a conversion is checked against."""
    with open(CATALOGUE, encoding="utf-8") as f:
        return json.load(f)


def row_for(model_id):
    for row in catalogue():
        if row["id"] == model_id:
            return row
    known = ", ".join(r["id"] for r in catalogue())
    sys.exit(f"{model_id!r} is not in ModelCatalog.json. It holds: {known}")


def hf_repo(pin, row):
    """The Hugging Face repository a model comes from: the pin's own, else
    the catalogue's sourceURL when that points at one."""
    url = row.get("sourceURL", "")
    prefix = "https://huggingface.co/"
    from_catalogue = url[len(prefix):].strip("/") if url.startswith(prefix) else None
    if pin.get("repo") and from_catalogue and pin["repo"] != from_catalogue:
        sys.exit(f"{row['id']}: pin_model.py says the repository is {pin['repo']} and the catalogue row "
                 f"says {from_catalogue}; one of the two is out of date")
    return pin.get("repo") or from_catalogue


# ------------------------------------------------------- reading a pin site
#
# The pins are read and written through the script's syntax tree, so a
# comment, a reflowed line or a moved table cannot make an edit land in the
# wrong place, and a shape this does not recognise is refused rather than
# guessed at. Offsets are computed over the UTF-8 bytes because that is
# what `ast` counts columns in, and these scripts hold non-ASCII text.

class PinShapeError(Exception):
    """A pin this script cannot read or write: the name is gone, the table
    has been reshaped, or the value is an expression rather than a literal."""


def _source(path):
    with open(path, "rb") as f:
        data = f.read()
    return data, ast.parse(data.decode("utf-8"), filename=path)


def _line_starts(data):
    starts, pos = [0], 0
    for line in data.splitlines(keepends=True):
        pos += len(line)
        starts.append(pos)
    return starts


def _span(node, starts):
    return (starts[node.lineno - 1] + node.col_offset,
            starts[node.end_lineno - 1] + node.end_col_offset)


def _assigned(tree, name):
    """The value of a top-level `name = <value>`; None when there is none.
    A tuple target (`A, B = …`) is not one of these and is passed over."""
    for node in tree.body:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id == name:
                    return node.value
    return None


def _member(node, key):
    """`key` inside a `dict(...)` call or a `{...}` literal."""
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "dict":
        for keyword in node.keywords:
            if keyword.arg == key:
                return keyword.value
    elif isinstance(node, ast.Dict):
        for k, v in zip(node.keys, node.values):
            if isinstance(k, ast.Constant) and k.value == key:
                return v
    return None


def _pin_node(tree, where, script):
    """The node holding one pinned value. `where` is a field name for a
    module-level constant, or (table, key, field) for a row of a table."""
    if isinstance(where, str):
        node = _assigned(tree, where)
        if node is None:
            raise PinShapeError(f"{script} has no top-level {where}")
        return node
    table, key, field = where
    root = _assigned(tree, table)
    if not isinstance(root, ast.Dict):
        raise PinShapeError(f"{script}: {table} is not a dictionary")
    entry = _member(root, key)
    if entry is None:
        raise PinShapeError(f"{script}: {table} has no {key!r} row")
    node = _member(entry, field)
    if node is None:
        raise PinShapeError(f"{script}: {table}[{key!r}] has no {field}")
    return node


def _value(node):
    """What a pin node means: its literal, or the placeholder when it names
    PLACEHOLDER. Anything else is a shape this cannot touch."""
    if isinstance(node, ast.Constant):
        return node.value
    if isinstance(node, ast.Name) and node.id == "PLACEHOLDER":
        return PLACEHOLDER
    raise PinShapeError(f"pin is {ast.dump(node)[:60]}…, not a literal")


def read_pin(script, where, subkey=None):
    """The value a pin currently holds. `subkey` reads one entry of a pin
    that is itself a dictionary (SAM's package_sha256, keyed by role)."""
    data, tree = _source(os.path.join(SCRIPTS, script))
    node = _pin_node(tree, where, script)
    if subkey is not None:
        inner = _member(node, subkey)
        if inner is None:
            raise PinShapeError(f"{script}: the pin has no {subkey!r} entry")
        node = inner
    return _value(node)


def unpinned(value):
    """Whether a pin is still waiting to be recorded. The scripts write the
    placeholder for this; convert_birefnet.py writes None."""
    return value is None or value == PLACEHOLDER


def write_pins(script, edits):
    """Replaces each (where, subkey, value) in `script` and re-reads the
    file to confirm every one took. Edits are applied from the end of the
    file backwards so the earlier spans stay where they were."""
    path = os.path.join(SCRIPTS, script)
    data, tree = _source(path)
    starts = _line_starts(data)
    spans = []
    for where, subkey, value in edits:
        node = _pin_node(tree, where, script)
        if subkey is not None:
            inner = _member(node, subkey)
            if inner is None:
                raise PinShapeError(f"{script}: the pin has no {subkey!r} entry")
            node = inner
        _value(node)                                  # refuse a shape we cannot read back
        spans.append((_span(node, starts), json.dumps(value)))
    for (start, end), text in sorted(spans, key=lambda s: s[0][0], reverse=True):
        data = data[:start] + text.encode("utf-8") + data[end:]
    ast.parse(data.decode("utf-8"), filename=path)    # never leave a file that will not parse
    with open(path, "wb") as f:
        f.write(data)
    for where, subkey, value in edits:                # from disk, not from memory
        if read_pin(script, where, subkey) != value:
            sys.exit(f"{script}: the pin did not take; the file has been left as it is now, check it by hand")


# ------------------------------------------------------------------ the plan

def test_photo(args):
    """The photo the conversion's verify step would use, or None when it
    would find nothing."""
    if args.test_image:
        return args.test_image if os.path.isfile(args.test_image) else None
    for candidate in TEST_PHOTOS:
        path = os.path.join(REPO_ROOT, candidate)
        if os.path.isfile(path):
            return path
    return None


def licence_line(row):
    licence = row["licence"]
    allowed = "commercial use allowed" if licence["commercialUse"] else "RESEARCH USE ONLY"
    return f"{licence['name']} — {allowed}"


def pin_state(pin):
    """(sentence, everything_pinned) for one model's pins."""
    try:
        revision = read_pin(pin["script"], pin["revision"])
        if pin["source"] == "packages":
            roles = ["imageEncoder", "promptEncoder", "maskDecoder"]
            hashes = [read_pin(pin["script"], pin["packages"], role) for role in roles]
        else:
            hashes = [read_pin(pin["script"], pin["weights"])]
    except PinShapeError as e:
        return f"cannot be read ({e})", False
    missing = unpinned(revision) or any(unpinned(h) for h in hashes)
    if missing:
        which = []
        if unpinned(revision):
            which.append("revision")
        if any(unpinned(h) for h in hashes):
            which.append("package hashes" if len(hashes) > 1 else "weights hash")
        return "not pinned (" + " and ".join(which) + ")", False
    return f"pinned at {revision[:12]}", True


def show_plan(row, pin, out_dir, args):
    """What this model is and what --yes would do to get it. Nothing here
    reaches the network."""
    packages = row.get("packages", [])
    state, ready = pin_state(pin)
    repo = hf_repo(pin, row)
    print(f"{row['displayName']} ({row['id']})")
    print(f"  For          {KIND_WORDS.get(row['kind'], row['kind'])}, {row['inputSize']} px square")
    print(f"  Licence      {licence_line(row)}")
    print(f"               {row['licence']['url']}")
    print(f"  Source       {row['sourceURL']}")
    print(f"  Size         about {row['sizeMB']} MB, {len(packages)} package{'s' if len(packages) != 1 else ''}")
    print(f"  Converted by scripts/{pin['script']} {' '.join(pin['args'])}".rstrip())
    print(f"  Pin          {state}")
    photo = test_photo(args)
    if args.skip_verify:
        print("  Verify       skipped (--skip-verify), so the model is converted unchecked")
    elif photo:
        print(f"  Verify       on {os.path.relpath(photo, REPO_ROOT)}")
    else:
        print("  Verify       no photo to verify on — pass --test-image, or run"
              "\n               scripts/fetch_test_assets.sh --portrait (3.7 MB)")
    if not row["licence"]["commercialUse"]:
        print("\n  This model's licence or training data allow research and evaluation only.")
        print("  Latent records that in the manifest and the row reads 'Research use only'.")
    print()
    step = 1

    def say(text):
        nonlocal step
        print(f"    {step}. {text}")
        step += 1

    print("  With --yes this would:")
    if pin["source"] == "file":
        say("take the weights you passed as --from-file and hash them (nothing is downloaded:"
            f"\n       {pin['code_url']} links them from its README)")
        say(f"record that hash and the --code-revision you vetted in scripts/{pin['script']}")
    else:
        say(f"ask huggingface.co for the current revision of {repo} and print the files"
            "\n       and their sizes, before anything is downloaded")
        say(f"download about {row['sizeMB']} MB at that revision into the Hugging Face cache")
        if pin["source"] == "packages":
            say(f"copy the {len(packages)} packages into the output folder, hash each one, and record"
                f"\n       the revision and the hashes in scripts/{pin['script']}")
        else:
            say(f"hash {pin['weights_file']} and record it with the revision in scripts/{pin['script']}")
    say(f"run scripts/{pin['script']} {' '.join(pin['args'])}".rstrip()
        + f" --out {out_dir},"
        + " which checks what it has against\n       that pin, verifies the model on a test photo, and writes "
        + f"{row['id']}.model.json")
    say("compare the manifest with this catalogue row and report any difference")
    print()
    if ready and pin["source"] != "file":
        print("  This model is pinned already, so --yes would download at the pinned revision")
        print("  and convert. Add --repin to move the pin to the current one instead.")
    print("  Nothing has been downloaded and no file has been changed.")


# ---------------------------------------------------------------- fetching

def resolve(repo, revision=None):
    """The repository at `revision`, or at its current head. Returns the
    info object; the caller prints it before deciding to download."""
    try:
        from huggingface_hub import HfApi
    except ImportError:
        sys.exit("huggingface_hub is not installed. In a Python 3.12 virtual environment:\n"
                 "  pip install -r scripts/requirements-coreml.txt   (enough for the SAM sizes)\n"
                 "  pip install -r scripts/requirements.txt          (everything, including torch)")
    try:
        return HfApi().repo_info(repo_id=repo, repo_type="model", revision=revision, files_metadata=True)
    except Exception as e:                                   # network, auth, a repo that moved
        sys.exit(f"could not read https://huggingface.co/{repo}: {e}")


def show_revision(repo, info, patterns):
    """The revision and the files a download would bring, largest first."""
    print(f"  Repository   https://huggingface.co/{repo}")
    print(f"  Revision     {info.sha}")
    if getattr(info, "lastModified", None):
        print(f"  Last change  {info.lastModified}")
    files = []
    for sibling in getattr(info, "siblings", None) or []:
        name = sibling.rfilename
        if patterns and not any(fnmatch.fnmatch(name, p) for p in patterns):
            continue
        files.append((getattr(sibling, "size", None) or 0, name))
    files.sort(reverse=True)
    total = sum(size for size, _ in files)
    print(f"  Files        {len(files)}, {total/1e6:.0f} MB in all" if total else f"  Files        {len(files)}")
    for size, name in files[:12]:
        print(f"    {size/1e6:9.1f} MB  {name}" if size else f"    {'':12}  {name}")
    if len(files) > 12:
        print(f"    … and {len(files) - 12} more")
    return total


def download(repo, revision, patterns):
    try:
        from huggingface_hub import snapshot_download
    except ImportError:
        sys.exit("huggingface_hub is not installed. In a Python 3.12 virtual environment:\n"
                 "  pip install -r scripts/requirements-coreml.txt   (enough for the SAM sizes)\n"
                 "  pip install -r scripts/requirements.txt          (everything, including torch)")
    print(f"Downloading {repo} @ {revision[:12]} …")
    return snapshot_download(repo, revision=revision, allow_patterns=patterns)


# ------------------------------------------------------------------ checking

def compare_with_catalogue(manifest_path, row):
    """The manifest a conversion wrote against the catalogue row the app
    ships. A difference is not fatal — upstream is allowed to move — but it
    means the row, or the model, is not what this build expects."""
    with open(manifest_path, encoding="utf-8") as f:
        manifest = json.load(f)
    problems = []
    for field in ("id", "kind", "inputSize"):
        if manifest.get(field) != row.get(field):
            problems.append(f"{field}: {manifest.get(field)!r}, the catalogue says {row.get(field)!r}")
    if manifest.get("licence", {}).get("commercialUse") != row.get("licence", {}).get("commercialUse"):
        problems.append("licence.commercialUse differs from the catalogue")
    made = {p["name"]: p for p in manifest.get("packages", [])}
    want = {p["name"]: p for p in row.get("packages", [])}
    for name in sorted(set(want) - set(made)):
        problems.append(f"the catalogue expects a package {name} and the conversion did not write one")
    for name in sorted(set(made) - set(want)):
        problems.append(f"the conversion wrote {name}, which the catalogue does not name")
    for name in sorted(set(made) & set(want)):
        for field in ("role", "inputNames", "outputNames"):
            if made[name].get(field) != want[name].get(field):
                problems.append(f"{name}: {field} is {made[name].get(field)!r}, "
                                f"the catalogue says {want[name].get(field)!r}")
    size, expected = manifest.get("sizeMB", 0), row.get("sizeMB", 0)
    if expected and abs(size - expected) > max(5, expected * 0.1):
        problems.append(f"sizeMB is {size}, the catalogue says {expected}")
    return problems


def run_converter(pin, out_dir, extra):
    """Runs the conversion script and lets its output through as it goes;
    it prints timings and a verify step worth watching."""
    command = [sys.executable, os.path.join(SCRIPTS, pin["script"])] + pin["args"] + ["--out", out_dir] + extra
    print("\n$ " + shlex.join(command) + "\n")
    result = subprocess.run(command, cwd=REPO_ROOT)
    if result.returncode != 0:
        sys.exit(f"\n{pin['script']} failed ({result.returncode}). The pin has been written; "
                 f"run the command above again once the cause is fixed.")


# ---------------------------------------------------------------------- main

def do_list():
    print(f"{'id':26} {'kind':22} {'MB':>5}  pin")
    for row in catalogue():
        pin = PINS.get(row["id"])
        state = pin_state(pin)[0] if pin else "no conversion script"
        print(f"{row['id']:26} {row['kind']:22} {row['sizeMB']:5}  {state}")
    print("\nAdd a model's id to see what converting it would take, and --yes to do it.")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("model", nargs="?", help="a catalogue id, e.g. sam2.1-large (see --list)")
    parser.add_argument("--list", action="store_true", help="every catalogue model and whether it is pinned")
    parser.add_argument("--out", help="folder for the packages and manifest (default ./<id>/)")
    parser.add_argument("--resolve", action="store_true",
                        help="ask which revision is current and stop; downloads nothing")
    parser.add_argument("--yes", action="store_true",
                        help="download, write the pin and convert. The only flag that fetches anything")
    parser.add_argument("--revision", help="use this upstream revision rather than the current head")
    parser.add_argument("--repin", action="store_true", help="replace a pin that is already recorded")
    parser.add_argument("--from-file", metavar="PATH",
                        help="weights you downloaded yourself, for a model whose weights are not on Hugging Face")
    parser.add_argument("--code-revision", help="the git commit of the model's code that you vetted")
    parser.add_argument("--no-convert", action="store_true", help="write the pin and stop")
    parser.add_argument("--skip-verify", action="store_true",
                        help="pass --skip-verify to the conversion script (leaves the model unchecked)")
    parser.add_argument("--test-image", help="photo for the conversion script's verify step")
    args = parser.parse_args(argv)

    if args.list:
        return do_list()
    if not args.model:
        parser.error("name a model (see --list)")

    row = row_for(args.model)
    pin = PINS.get(args.model)
    if pin is None:
        sys.exit(f"{args.model} is in the catalogue but no script here converts it")
    out_dir = os.path.abspath(args.out or row["id"])
    repo = hf_repo(pin, row)
    if pin["source"] != "file" and not repo:
        sys.exit(f"{args.model}: {row['sourceURL']} is not a Hugging Face repository, so its "
                 f"revision cannot be resolved here; pass --revision")

    if not args.yes and not args.resolve:
        show_plan(row, pin, out_dir, args)
        return 0

    # The conversion's verify step stops without a photo, and finding that
    # out after several hundred megabytes have been fetched helps nobody.
    if args.yes and not args.no_convert and not args.skip_verify and test_photo(args) is None:
        if args.test_image:
            sys.exit(f"there is no photo at {args.test_image}. Nothing has been downloaded.")
        sys.exit("the conversion verifies the model on one photo and there is none to use: pass "
                 "--test-image with any .jpg, or run scripts/fetch_test_assets.sh --portrait "
                 "(3.7 MB, public domain). Nothing has been downloaded.")

    # -------------------------------------- 1. the revision, and the pin guard
    revision = args.revision
    if pin["source"] == "file":
        if args.resolve:
            print(f"{row['displayName']} ({row['id']}): there is no revision to resolve — the weights are "
                  f"linked from\n{pin['code_url']} rather than hosted where this can address one. Pass "
                  f"--from-file and --code-revision\nwith --yes. Nothing has been downloaded.")
            return 0
        if not args.from_file:
            sys.exit(f"{args.model}'s weights are linked from {pin['code_url']}, not hosted where this can "
                     f"fetch them: download the file and pass it as --from-file")
        if not os.path.isfile(args.from_file):
            sys.exit(f"there is no file at {args.from_file}")
        recorded = read_pin(pin["script"], pin["revision"])
        if not unpinned(recorded) and args.code_revision not in (None, recorded) and not args.repin:
            sys.exit(f"scripts/{pin['script']} is pinned at {recorded[:12]} and --code-revision asks for "
                     f"{args.code_revision[:12]}. Leave it off to convert at the pin, or pass --repin "
                     f"to move it.")
        revision = args.code_revision or recorded
        if unpinned(revision):
            sys.exit(f"pass --code-revision: the commit of {pin['code_url']} whose model code you read. "
                     f"The conversion runs that code, so it is pinned along with the weights.")
    else:
        # A model already pinned is fetched at its pin: that is the revision
        # someone looked at. --revision names another and --repin moves the
        # pin to whatever is current.
        recorded = read_pin(pin["script"], pin["revision"])
        held = None if (unpinned(recorded) or args.repin) else recorded
        if args.revision and held and args.revision != held:
            sys.exit(f"scripts/{pin['script']} is pinned at {held[:12]} and --revision asks for "
                     f"{args.revision[:12]}. Leave --revision off to convert at the pin, or pass --repin "
                     f"to move it.")
        info = resolve(repo, args.revision or held)
        print(f"{row['displayName']} ({row['id']})")
        total = show_revision(repo, info, pin.get("patterns"))
        revision = args.revision or held or info.sha
        if held:
            print("  Pinned       yes, and this is that revision")
        elif not args.revision:
            print("  Pinned       no, so this would become the pin")
        if args.resolve:
            print(f"\nNothing downloaded. Run again with --yes to fetch {total/1e6:.0f} MB at {revision[:12]}.")
            return 0

    # ----------------------------------------------- 2. download and hash
    edits = [(pin["revision"], None, revision)]
    if pin["source"] == "packages":
        snapshot = download(repo, revision, pin.get("patterns"))
        import convert_sam2                                   # its rules for which package is which
        prefix = convert_sam2.SIZES[pin["size_key"]]["prefix"]
        found = convert_sam2.find_packages(snapshot, prefix)
        os.makedirs(out_dir, exist_ok=True)
        print("Copying and hashing …")
        for role, package in found.items():
            target = os.path.join(out_dir, os.path.basename(package))
            if os.path.exists(target):
                shutil.rmtree(target)
            shutil.copytree(package, target, symlinks=False)  # the cache holds links into its blob store
            digest = latent_manifest.package_hash(target)
            print(f"  {os.path.basename(target):48} {digest}")
            edits.append((pin["packages"], role, digest))
    elif pin["source"] == "weights":
        snapshot = download(repo, revision, pin.get("patterns"))
        weights = os.path.join(snapshot, pin["weights_file"])
        if not os.path.isfile(weights):
            sys.exit(f"{pin['weights_file']} is not in {repo} at {revision[:12]}; the upload has changed shape")
        digest = latent_manifest.file_sha256(weights)
        print(f"  {pin['weights_file']:48} {digest} ({os.path.getsize(weights)/1e6:.1f} MB)")
        edits.append((pin["weights"], None, digest))
    else:
        digest = latent_manifest.file_sha256(args.from_file)
        print(f"  {os.path.basename(args.from_file):48} {digest} "
              f"({os.path.getsize(args.from_file)/1e6:.1f} MB)")
        edits.append((pin["weights"], None, digest))

    # ------------------------------------------------------- 3. write the pin
    try:
        write_pins(pin["script"], edits)
    except PinShapeError as e:
        sys.exit(f"the pin in scripts/{pin['script']} is not the shape this expects ({e}); "
                 f"record it by hand. Nothing has been changed.")
    print(f"Pinned scripts/{pin['script']} at {revision[:12]}")
    if args.no_convert:
        print(f"Stopping before the conversion (--no-convert). Run it with:\n"
              f"  python scripts/{pin['script']} {' '.join(pin['args'] + ['--out', out_dir])}")
        return 0

    # ---------------------------------------------------------- 4. convert
    extra = []
    if pin["source"] == "packages":
        extra += ["--from-local", out_dir]                    # the copy above, hashed against the new pin
    if pin["source"] == "file":
        extra += [pin["weights_arg"], os.path.abspath(args.from_file)]
    if args.skip_verify:
        extra.append("--skip-verify")
    if args.test_image:
        extra += ["--test-image", args.test_image]
    run_converter(pin, out_dir, extra)

    # ------------------------------------------------- 5. check what we got
    manifest_path = os.path.join(out_dir, row["id"] + ".model.json")
    if not os.path.isfile(manifest_path):
        sys.exit(f"{pin['script']} wrote no {row['id']}.model.json in {out_dir}")
    problems = compare_with_catalogue(manifest_path, row)
    if problems:
        print("\nThe model differs from the catalogue row this build ships:")
        for problem in problems:
            print(f"  {problem}")
        print("  Add Model… may still take it. If upstream has genuinely moved, the row in\n"
              "  Sources/MLKit/Resources/Models/ModelCatalog.json wants updating to match.")
    else:
        print("\nMatches the catalogue row.")
    packages = len(row.get("packages", []))
    print(f"\n{out_dir} is ready for Settings › AI › Models › Add Model….")
    if packages > 1:
        # The open panel shows an .mlpackage as one item, so picking one is
        # the easy mistake; a model of several packages can only go in as
        # the folder, and the sandbox leaves the app unable to read the
        # folder around a package it was not given.
        print(f"  Choose the folder itself — {os.path.basename(out_dir)} — not one of the "
              f"{packages} packages\n  inside it. This model is all {packages} together.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (latent_manifest.PackageError, PinShapeError, ValueError) as e:
        sys.exit(f"error: {e}")
