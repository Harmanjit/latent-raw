# Licences

Latent is free software under the GNU General Public License, version 3. Its source, and the full text of that licence (`LICENSE`), are at [github.com/Harmanjit/latent-raw](https://github.com/Harmanjit/latent-raw); `LICENSE` is also inside the app, in `Latent.app/Contents/Resources`.

The app carries code, data and models made by other people. Each is listed here with its licence. The full licence texts are in the repository's `licences/` folder, and `scripts/make_app.sh` copies them into `Latent.app/Contents/Resources/Licences`, so every copy of the app has them.

## Code

| Component | What Latent uses it for | Licence | Text in `Licences/` |
|---|---|---|---|
| [LibRaw](https://www.libraw.org) 0.22.2, © 2008-2025 LibRaw LLC | Reading raw files, in the sandboxed decoder service. Built from source at a pinned commit and linked statically | GNU LGPL 2.1, or CDDL 1.0, at the user's choice | `LibRaw-COPYRIGHT.txt`, `LibRaw-LGPL-2.1.txt`, `LibRaw-CDDL-1.0.txt` |
| [GRDB.swift](https://github.com/groue/GRDB.swift) 6.29, © 2015-2024 Gwendal Roué | The catalog database | MIT | `GRDB-MIT.txt` |

LibRaw contains code from dcraw (Dave Coffin), the DCB and FBDD demosaic and denoise (Jacek Gozdz, BSD-style), the X3F library (Roland Karlsson, BSD-style) and the Adobe DNG SDK (MIT); `LibRaw-COPYRIGHT.txt` names each. Because LibRaw is linked statically, the LGPL lets you relink Latent against a LibRaw you have changed: the whole of Latent's source is available, and `scripts/build_libraw.sh` builds the library it links, so building from source with your own LibRaw does exactly that.

## Data

| Component | What Latent uses it for | Licence |
|---|---|---|
| [Lensfun](https://lensfun.github.io) lens database, copied unchanged from the Lensfun project's `data/db` | Lens profiles for distortion, vignetting and chromatic aberration correction | [Creative Commons Attribution-ShareAlike 3.0](https://creativecommons.org/licenses/by-sa/3.0/) |

The database is by the Lensfun contributors. Latent reads it with its own parser; the Lensfun library itself is not part of the app.

## Bundled models

| Model | Source | Licence | Text in `Licences/` |
|---|---|---|---|
| BiRefNet Lite | [ZhengPeng7/BiRefNet_lite](https://huggingface.co/ZhengPeng7/BiRefNet_lite), converted to Core ML by `scripts/convert_birefnet.py` | MIT | `BiRefNet-MIT.txt` |
| SAM 2.1 Small | Meta's [Segment Anything 2.1](https://github.com/facebookresearch/sam2), as converted to Core ML by Apple ([apple/coreml-sam2.1-small](https://huggingface.co/apple/coreml-sam2.1-small)) | Apache 2.0 | `Apache-2.0.txt` |
| NAFNet SIDD width 32 | [megvii-research/NAFNet](https://github.com/megvii-research/NAFNet), converted by `scripts/convert_nafnet.py` | MIT | `NAFNet-MIT.txt` |
| SegFormer B2 (ADE20K) | [nvidia/segformer-b2-finetuned-ade-512-512](https://huggingface.co/nvidia/segformer-b2-finetuned-ade-512-512), converted by `scripts/convert_segformer.py` | [NVIDIA Source Code License](https://github.com/NVlabs/SegFormer/blob/master/LICENSE): research and evaluation use only | the licence's own page |

SegFormer's licence does not allow commercial use, which is why Settings › AI › Models marks it **Research use only**. Models you add yourself carry their own licence in their manifest; see [Models](Models) and [Converting Models](Converting-Models).
