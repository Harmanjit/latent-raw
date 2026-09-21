# Core ML models bundled with MLKit

| Model id | Package(s) | What | Source | Size |
|---|---|---|---|---|
| `sam2.1-small` | `SAM2_1Small{ImageEncoder,PromptEncoder,MaskDecoder}FLOAT16.mlpackage` | Segment Anything 2.1 (small): click-to-select masks | https://huggingface.co/apple/coreml-sam2.1-small (Apple's conversion, Apache-2.0 model licence from Meta) | 94 MB |
| `birefnet-lite` | `BiRefNet_lite.mlpackage` | BiRefNet general-lite (Swin-T, MIT): one-shot subject masks, 1024², sigmoid inside the graph. Runs on the GPU only: the ANE compiler spends ~100 s on this graph and then every prediction fails, so its manifest pins `cpuAndGPU` (468 ms per mask on an M4; IoU 0.997 against PyTorch) | https://huggingface.co/ZhengPeng7/BiRefNet_lite at revision `aa62cd8…`, converted by `scripts/convert_birefnet.py --variant lite` (the deformable convolutions are rewritten as `grid_sample` taps) | 103 MB (`weight.bin` 96.0 MiB, under GitHub's 100 MiB file limit) |
| `segformer-b2-ade20k-512` | `SegFormer_segformer_b2_finetuned_ade_512_512.mlpackage` + `.labels.json` | SegFormer-B2 semantic segmentation, ADE20K 150 classes (sky, person, tree, water, …). The NVIDIA Source Code License allows research and evaluation use only, which the manifest records as `commercialUse: false` | https://huggingface.co/nvidia/segformer-b2-finetuned-ade-512-512, converted by `scripts/convert_segformer.py` | 55 MB |
| `nafnet-sidd-w32` | `NAFNet_SIDD_width32.mlpackage` | NAFNet real-noise denoiser (Chen et al. 2022, MIT), 256×256 tiles | Official weights mirrored at https://huggingface.co/nyanko7/nafnet-models, converted by `scripts/convert_nafnet.py` | 59 MB |

The packages are compiled to `.mlmodelc` on first use and cached in
`~/Library/Application Support/latent/mlmodels/`, keyed by the model id,
package name and the first 16 hex digits of the package hash below, so a
replaced package recompiles and the first mask of a session takes a couple
of seconds longer than the rest.

Every mask records the model version string that produced it in the edit
stack (`modelVersion`, the manifest's `<id>@<version>`), so a future model
swap is visible per image.

## Manifests

Each model has one `<id>.model.json` beside its package(s); the shape is
`ModelManifest` in `Sources/MLKit/ModelManifest.swift` and every field name
is read by a Swift `Codable` decoder, so they must match to the letter.
`scripts/latent_manifest.py` writes and checks them; the conversion scripts
call it last, once the package has passed its verify step.

```json
{
  "id": "birefnet-lite",                       // ^[a-z0-9][a-z0-9.-]{0,63}$
  "displayName": "BiRefNet Lite",
  "purpose": "Subject masks in one shot, no clicks needed",
  "version": 1,                                // bumps when the package changes
  "kind": "subjectSegmentation",               // promptedSegmentation | subjectSegmentation | semanticSegmentation | denoise
  "licence": { "name": "MIT", "url": "https://…/LICENSE", "commercialUse": true },
  "sourceURL": "https://huggingface.co/ZhengPeng7/BiRefNet_lite",   // http(s) only; opened by Get…
  "sizeMB": 103,
  "inputSize": 1024,                           // square
  "packages": [ { "name": "BiRefNet_lite.mlpackage", "sha256": "78d5cb0a…",       // + "role" for prompted kinds
                  "inputNames": ["image"], "outputNames": ["mask"] } ],
  "outputActivation": "probabilities",         // subject kinds: sigmoid | probabilities
  "refine": "none",                            // subject kinds: none | guided
  "labelsFile": "…labels.json",                // semantic kinds only: the class-names JSON beside the package
  "computeUnits": "cpuAndGPU",                 // a ceiling; absent = no override
  "converter": { "script": "scripts/convert_birefnet.py", "sourceRevision": "aa62cd8…",
                 "coremltools": "9.0", "torch": "2.14.0", "date": "2026-09-21" }
}
```

(The comments are not in the files; optional keys are left out rather than
set to null. A prompted model lists three packages with the roles
`imageEncoder`, `promptEncoder` and `maskDecoder`.)

`packages[].sha256` hashes the package *contents*: SHA-256 over
`Manifest.json`, `Data/com.apple.CoreML/model.mlmodel` and
`Data/com.apple.CoreML/weights/weight.bin`, in that order, each fed as the
relative-path bytes, a `0x00` byte, then the file bytes. A package holding
any other regular file is refused. `latent_manifest.py` and
`PackageHash.sha256(ofPackageAt:)` compute it identically; a CI test hashes
every bundled package against its manifest. The hash catches corruption
and keys the compile cache; the sandbox, not the hash, is the security
boundary, because an imported manifest arrives from the same untrusted
folder as its package. A re-conversion is never byte-identical, so a
bundled package is converted once and kept.

```
python scripts/latent_manifest.py --check Sources/MLKit/Resources/Models/*.model.json
```

## Catalogue: models the user can add

`ModelCatalog.json` is an array of the same rows with `sha256: null`. The app
never downloads anything: Settings › AI › Models lists these with a Get…
link to the source page and an Add Model… button that imports a folder, a
`.mlpackage` or a `.zip` holding the package(s) and their manifest. Convert
each one with the script named, which writes the folder to add.

| Model id | What | Licence | Script | Size |
|---|---|---|---|---|
| `sam2.1-tiny`, `sam2.1-base-plus`, `sam2.1-large` | Segment Anything 2.1, Apple's fp16 packages | Apache-2.0 | `scripts/convert_sam2.py --size tiny\|baseplus\|large` | 80, 166, 457 MB |
| `birefnet-general`, `birefnet-portrait` | BiRefNet Swin-L: the finest hair and structure; the portrait variant is tuned for people. GPU only, like lite | MIT | `scripts/convert_birefnet.py --variant general\|portrait` (once their revisions are pinned in the script) | 446 MB each |
| `u2net`, `u2net-small` | U²-Net salient-object masks, 320²; guided-filter refinement | Apache-2.0 | `scripts/convert_u2net.py [--small]` | 88 MB, 3 MB |
| `modnet` | MODNet portrait matting, 512²; people only | Apache-2.0 | `scripts/convert_modnet.py` | 13 MB |
| `isnet` | IS-Net (DIS) fine wiry detail, 1024². The code is Apache-2.0 but the DIS5K training data is research-only, so `commercialUse: false` and the row reads "Research use only" | Apache-2.0 code, DIS5K research-only | `scripts/convert_isnet.py` | 88 MB |

Left out on purpose: RMBG-1.4/2.0 (commercial use needs an agreement with
BRIA), BEN2 (no Core ML path yet) and ViTMatte (needs a trimap; a refiner,
not a selector).

The scripts for the catalogue rows other than BiRefNet are written in Wave
3 of docs/Retouch.md; a row whose script does not exist yet still shows in
Settings with its source link.

## AI noise reduction

NAFNet runs once per image on the demosaiced camera RGB at as-shot white
balance (gamma-encoded for the network, decoded after), in 256 px tiles
with a 32 px blended overlap, three tiles in flight on the GPU. The result
is kept with the image session and blended in by the pipeline at the
chosen strength, re-binned and re-white-balanced per render, so zooming
or changing white balance never re-runs the model. Exports run it again;
thumbnails don't (too slow for a background pass).

Why an external model: Apple ships no public denoising network. Core
Image's noise reduction is a classic filter, and the Photos app's
denoise isn't exposed to third parties. NAFNet-SIDD is among the best
published real-noise denoisers and, being all convolutions, converts to
Core ML cleanly. The width-64 variant (~464 MB of weights) scores about
0.3 dB higher on SIDD at roughly four times the cost; width 32 is the
sensible default for a 24 MP frame.

## Optional models (dormant, not offered)

| Package | What | Where | Size |
|---|---|---|---|
| `NAFNet_SIDD_width64.mlpackage` | NAFNet width 64: ~0.3 dB better, about four times the compute | Not published; built by `scripts/convert_nafnet.py --width 64` | 214 MB zip |

`OptionalModels.swift` can download this package into
`~/Library/Application Support/latent/models/`, verify it against the
SHA-256 recorded there, and leave it where the same lookup as the bundled
packages finds it. Nothing uses that path: no view offers the download,
the app has no network entitlement (`scripts/Latent.entitlements`), and
the `models-v1` release its URL points at has not been published.
