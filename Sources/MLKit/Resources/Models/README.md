# Core ML models bundled with MLKit

| Package | What | Source | Size |
|---|---|---|---|
| `SAM2_1Small{ImageEncoder,PromptEncoder,MaskDecoder}FLOAT16.mlpackage` | Segment Anything 2.1 (small): click-to-select masks | https://huggingface.co/apple/coreml-sam2.1-small (Apple's conversion, Apache-2.0 model licence from Meta) | ~92 MB |
| `SegFormer_segformer_b2_finetuned_ade_512_512.mlpackage` + `.labels.json` | SegFormer-B2 semantic segmentation, ADE20K 150 classes (sky, person, tree, water, …) | https://huggingface.co/nvidia/segformer-b2-finetuned-ade-512-512, converted by `scripts/convert_segformer.py` | ~55 MB |
| `NAFNet_SIDD_width32.mlpackage` | NAFNet real-noise denoiser (Chen et al. 2022, MIT), 256×256 tiles | Official weights mirrored at https://huggingface.co/nyanko7/nafnet-models, converted by `scripts/convert_nafnet.py` | ~56 MB |

The packages are compiled to `.mlmodelc` on first use and cached in
`~/Library/Application Support/latent/mlmodels/`, so the first mask of a
session takes a couple of seconds longer than the rest.

Every mask records the model version string that produced it in the edit
stack (`modelVersion`), so a future model swap is visible per image.

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

## Optional models (downloaded, not bundled)

| Package | What | Where | Size |
|---|---|---|---|
| `NAFNet_SIDD_width64.mlpackage` | NAFNet width 64: ~0.3 dB better, ~2.5× slower | GitHub release `models-v1` of `Harmanjit/latent-raw`, built by `scripts/convert_nafnet.py --width 64` | 214 MB zip |

Optional models are fetched from the AI Noise Reduction panel into
`~/Library/Application Support/latent/models/`, verified against the
SHA-256 in `OptionalModels.swift`, and found by the same lookup as the
bundled packages. Publishing a new one: convert, zip with
`zip -r Name.mlpackage.zip Name.mlpackage`, upload as a release asset,
and record its checksum and size in the catalog.
