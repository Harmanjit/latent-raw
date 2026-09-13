# Core ML models bundled with MLKit

| Package | What | Source | Size |
|---|---|---|---|
| `SAM2_1Small{ImageEncoder,PromptEncoder,MaskDecoder}FLOAT16.mlpackage` | Segment Anything 2.1 (small): click-to-select masks | https://huggingface.co/apple/coreml-sam2.1-small (Apple's conversion, Apache-2.0 model licence from Meta) | ~92 MB |
| `SegFormer_segformer_b2_finetuned_ade_512_512.mlpackage` + `.labels.json` | SegFormer-B2 semantic segmentation, ADE20K 150 classes (sky, person, tree, water, …) | https://huggingface.co/nvidia/segformer-b2-finetuned-ade-512-512, converted by `scripts/convert_segformer.py` | ~55 MB |

The packages are compiled to `.mlmodelc` on first use and cached in
`~/Library/Application Support/rawhead/mlmodels/`, so the first mask of a
session takes a couple of seconds longer than the rest.

Every mask records the model version string that produced it in the edit
stack (`modelVersion`), so a future model swap is visible per image.
