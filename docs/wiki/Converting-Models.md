# Converting Models

Latent downloads nothing. The app has no network entitlement at all: the
models behind AI masks come with it, or are added from a folder on this
Mac (see [Models](Models)). This page is how you make that folder — fetch a
model from where it is published, convert it to Core ML, check it, and end
up with something Add Model… will take.

This is developer-side work. It needs the repository and a Python
environment, not just the app, and it is the same procedure whether you are
adding SAM 2.1 Large to your own copy or preparing a model for someone
else.

## What you need

- The repository, and a shell sitting in it:

```bash
git clone https://github.com/Harmanjit/latent-raw.git latent && cd latent
```

- Python 3.12 (`brew install python@3.12`) and the pinned tooling:

```bash
python3.12 -m venv ~/latent-ml && source ~/latent-ml/bin/activate && pip install -r scripts/requirements.txt
```

- One photo for the verify step. Any JPEG will do, passed as
  `--test-image`; or fetch the public-domain portrait the face tests use
  with `scripts/fetch_test_assets.sh --portrait` (3.7 MB).
- Disk: roughly twice the model's size while it runs, because the download
  is cached and then copied. SAM 2.1 Large needs about a gigabyte free.

`torch` and `coremltools` are large, so the first `pip install` takes a
while. The SAM models are the exception that does not need torch at all —
Apple publishes them already converted, so nothing is traced — but the
requirements file pins one set of versions for every script, and installing
all of it is the simpler path. The environment is only needed for
converting, never for running Latent.

## SAM 2.1 Large, start to finish

Two commands. The first shows you what the second would do and touches
nothing:

```bash
python scripts/pin_model.py sam2.1-large --out ~/Models/sam2.1-large
```

```
SAM 2.1 Large (sam2.1-large)
  For          Click to select, 1024 px square
  Licence      Apache-2.0 — commercial use allowed
               https://github.com/facebookresearch/sam2/blob/main/LICENSE
  Source       https://huggingface.co/apple/coreml-sam2.1-large
  Size         about 457 MB, 3 packages
  Converted by scripts/convert_sam2.py --size large
  Pin          not pinned (revision and package hashes)
  …
  Nothing has been downloaded and no file has been changed.
```

Read that, then run it again with `--yes`, which is the only flag in the
whole procedure that reaches the network:

```bash
python scripts/pin_model.py sam2.1-large --out ~/Models/sam2.1-large --yes
```

It prints the revision and the file list before fetching, downloads about
457 MB, hashes the three packages, records what it found in
`scripts/convert_sam2.py`, runs that script to verify the model on your
photo and write the manifest, and finally compares the result with the
catalogue row the app ships. It ends with:

```
/Users/you/Models/sam2.1-large is ready for Settings › AI › Models › Add Model….
```

Open Latent, go to **Settings › AI › Models**, press **Add Model…**, choose
that folder, and SAM 2.1 Large appears in the list as **Installed**. Press
**Use** to make it the default for Click to Select. The app copies the
model into its own Application Support folder, so `~/Models/sam2.1-large`
can be deleted afterwards.

SAM 2.1 Large is the model for the best hair and fine edges, and it wants
the memory to match: a large model takes a second or more to load and keeps
its share while loaded, so on an 8 GB Mac the bundled Small is the kinder
choice.

## What those two commands actually did

Worth understanding, because every model goes through the same six steps.

1. **Resolve.** Ask the source which revision is current, and print it with
   the files and their sizes. Nothing is downloaded yet. `--resolve` stops
   here; `--revision` names a particular one instead.
2. **Download** at exactly that revision.
3. **Hash.** The content hash of each `.mlpackage` for a model published as
   Core ML packages, or the file's SHA-256 for one published as weights.
4. **Pin.** Write the revision and those hashes into the conversion script.
   This is the step that makes the conversion repeatable: the script then
   refuses to convert anything that does not hash to the same values.
5. **Convert.** Run the conversion script, which checks what it has against
   the pin just written, runs the model on your photo, times it on the two
   compute units, and writes `<id>.model.json` — the manifest naming every
   package, its hash and its inputs and outputs.
6. **Compare** the manifest against the row in `ModelCatalog.json`. A
   difference means the model or the row has moved on, and the run says so.

### Why the pin exists

Every conversion script carries the upstream revision and checksum it was
built against, and refuses to run while a pin still reads `<pin me>`:

```
--size large is not pinned yet: vet https://huggingface.co/apple/coreml-sam2.1-large,
then record its git revision and the content hash of each package
(latent_manifest.py --hash) in SIZES before downloading it. Nothing was downloaded.
```

That is deliberate. An upstream repository can be updated, re-uploaded or
taken over, and a conversion that silently follows whatever is current
today is not a conversion anyone can check. The pin says *this* revision,
hashing to *these* bytes, was looked at by a person. `pin_model.py` does
the looking-up and the editing for you; the judgement — is this the right
repository, is the licence what you think, does the upload look sane — is
still yours.

Once a pin is recorded, `pin_model.py` fetches at that pin rather than at
whatever is current. `--repin` moves it, and the diff in
`scripts/convert_*.py` shows exactly what moved.

## Any other model

`--list` shows every model the app knows you could add, and whether its
script is pinned:

```bash
python scripts/pin_model.py --list
```

Most of them work exactly like the example above — name the id, look, then
`--yes`:

| Model | id | Notes |
|---|---|---|
| SAM 2.1 Tiny, Base+, Large | `sam2.1-tiny`, `sam2.1-base-plus`, `sam2.1-large` | Apple publishes these already converted; nothing is traced |
| BiRefNet General, Portrait | `birefnet-general`, `birefnet-portrait` | Traced from PyTorch; the slowest conversion here, and GPU-only afterwards |
| U²-Net, U²-Net Small | `u2net`, `u2net-small` | Weights linked from a README — see below |
| MODNet | `modnet` | Weights linked from a README |
| IS-Net | `isnet` | Weights linked from a README; research use only |

### Models whose weights are linked from a README

U²-Net, MODNet and IS-Net publish their weights through a download link
rather than a repository a script can address, so two things come from you:
the file, and the commit of the model's code that you read. The code
matters because the conversion imports and runs it.

```bash
python scripts/pin_model.py u2net --from-file ~/Downloads/u2net.pth \
    --code-revision <the commit you read> --out ~/Models/u2net --yes
```

Everything after the hash is the same. Take the commit from the repository
page — the full SHA is better than the short one.

## A model that is not in the catalogue at all

Latent can use four kinds of model, and a new one has to be one of them:

| Kind | What it does | Where it shows up |
|---|---|---|
| `subjectSegmentation` | One image in, one soft mask out | Subject masks |
| `promptedSegmentation` | Three packages: encode, prompt, decode | Click to Select |
| `semanticSegmentation` | Class labels per pixel, plus a labels file | Class masks |
| `denoise` | Tiles in, tiles out | AI noise reduction — see the note below |

A `denoise` model will import, but nothing offers a choice of one: AI noise
reduction uses the bundled NAFNet and has no picker, so a second one would
sit in the list unused.

Adding one means writing a conversion script of your own. The existing ones
are the templates, and they are more alike than not: download at a pin,
load the model, trace it, convert with coremltools, verify the Core ML
output against the PyTorch one, then write the manifest through
`scripts/latent_manifest.py`. `convert_modnet.py` is the shortest of them and the
best one to read first; `convert_birefnet.py`, at twice the length of any
other, is the one that had to rewrite operations Core ML would not take.

The manifest is the part that matters to the app, and
`scripts/latent_manifest.py` writes it without any conversion at all if you
already have an `.mlpackage`:

```bash
python scripts/latent_manifest.py MyModel.mlpackage \
    --id my-model --display-name "My Model" --kind subjectSegmentation \
    --purpose "Subject masks, my way" --input-size 1024 \
    --licence-name MIT --licence-url https://example.com/LICENSE \
    --source-url https://example.com/my-model --output-activation sigmoid
```

Every field is described in `Sources/MLKit/Resources/Models/README.md`,
which is the reference for the manifest. Two things catch people out:
`--output-activation sigmoid` when the graph outputs logits rather than a
0–1 mask, and `--inside`, which puts the manifest at the package's own root
so a single `.mlpackage` can be handed round and added on its own.

Check a manifest you wrote before trying to add it:

```bash
python scripts/latent_manifest.py --check ~/Models/my-model/my-model.model.json
```

## Licences

The manifest records the licence and whether commercial use is allowed, and
Settings shows "Research use only" on a model whose licence or training
data say so — IS-Net's DIS5K data, and the bundled SegFormer under NVIDIA's
licence. `pin_model.py` prints this before it fetches anything. Latent does
not stop you converting or using such a model; it makes sure you can see
what you agreed to.

## When it goes wrong

**"is not pinned yet … Nothing was downloaded."** The conversion script was
run directly, before the pin was recorded. Run `pin_model.py` instead, or
record the pin by hand.

**"content hash … != pinned …"** The upload changed since the pin was
recorded. Do not paper over it: look at the repository's history first, and
then `--repin` if the change is one you are happy with.

**"The folder holds a file the manifest does not name (.DS_Store)"**, or
the conversion stopping with **"unexpected file .DS_Store"**. Opening an
`.mlpackage` in Finder leaves one inside it, and the hash covers exactly
three files and refuses anything else. Delete it and run the conversion
again:

```bash
find ~/Models/sam2.1-large -name .DS_Store -delete
```

**"No .model.json manifest was found beside … or inside it."** A lone
`.mlpackage` was chosen with nothing beside it. Either choose the folder
instead, or write the manifest inside the package with `--inside`.

**The verify step cannot find a photo.** Pass `--test-image
~/Pictures/something.jpg`, or fetch the bundled one with
`scripts/fetch_test_assets.sh --portrait`.

**`huggingface_hub` is not installed.** The virtual environment is not
active: `source ~/latent-ml/bin/activate`.

**The conversion failed after the pin was written.** That is expected and
fine — the pin is what was downloaded and hashed, which has not changed.
The message names the exact command to run again.

**A model that imports but produces nothing useful.** Re-run the verify
step on the folder without converting again:

```bash
python scripts/convert_sam2.py --size large --verify-only --out ~/Models/sam2.1-large
```

## Checking the tooling itself

`pin_model.py` edits the conversion scripts in place, which is worth not
taking on trust. It locates each pin in the script's syntax tree rather
than by matching text, refuses any shape it does not recognise, and reads
the file back afterwards to confirm the pin says what it should. The test
exercises that on copies of the real scripts and needs no ML packages at
all:

```bash
python scripts/test_pin_model.py
```

See also: [Models](Models) for what the app does with a model once it is
added, and [Security and Privacy](Security-and-Privacy) for why the app has
no network access of its own.
