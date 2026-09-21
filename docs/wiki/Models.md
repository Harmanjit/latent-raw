# Models

Latent's AI masks, AI noise reduction, red-eye Auto and Touch-up run machine-learning models on this Mac. Nothing is sent anywhere and nothing is downloaded: the models come with the app or are added from disk. This page is about the models behind the masks, which you can choose between and add to. AI noise reduction uses one bundled model with no choice to make; see [Develop](Develop#modules).

## What comes with the app

| Model | For | Licence | Size | Where it runs |
|---|---|---|---|---|
| Apple Vision | Subject | Part of macOS | — | Built in |
| BiRefNet Lite | Subject | MIT | 103 MB | GPU only |
| SAM 2.1 Small | Click to select | Apache-2.0 | 94 MB | GPU by default |
| SegFormer B2 | Classes (sky, people, vegetation, water, buildings, ground, mountains, animals, vehicles) | NVIDIA Source Code License, research use only | 55 MB | GPU by default |

BiRefNet Lite is the default for new subject masks; it takes about half a second per mask on an M4 and finds hair and fine edges that Apple Vision's request rounds off. It runs on the GPU whatever the compute setting says, because the Neural Engine's compiler cannot build it. SAM 2.1 Small is the default for Click to Select.

## Settings › AI › Models

The list shows every model Latent knows about: the built-in one, the bundled ones, any you have added, and a catalogue of models you can add. Each row gives the model's name, what it makes (For: Subject, Click to select or Classes), its licence, its size, and its status: **Built in**, **Bundled**, **Installed** or **Not installed**. A row whose licence allows research use only says so. **Source** opens the model's page in your browser. The default of each kind, the one a new mask is made with, is marked **Default**.

- **Use** makes an installed subject or click-to-select model the default for new masks. Existing masks keep the model they were made with.
- **Get…** appears on a model that is not installed. It opens the model's page in your browser; Latent downloads nothing. Convert the model with the script named in the catalogue (see [Adding a model](Models#adding-a-model)), then choose Add Model….
- **Remove** appears on a model you added. It asks first, then deletes the model's folder. Masks made with it are shown with a built-in or bundled model until it is added again, and if it was the default, new masks fall back to the bundled one; the note under the list says which.
- **Add Model…** imports a model from a folder, an `.mlpackage` or a `.zip` on this Mac. A sheet shows the checks as they run ("Checking BiRefNet General…"); it can't be cancelled, but a failed import leaves nothing behind. The result appears under the list: "Added BiRefNet General (446 MB)", or one plain sentence saying why the model was refused.
- **Reveal in Finder** shows the folder added models live in.

## Choosing a model for a mask

In Develop, the Local Adjustments **Add** menu has a **Subject** submenu and a **Click to Select** submenu, each listing the installed models of that kind with the default first and ticked, and **More models…**, which opens Settings. Develop › Masks › New Subject Mask and New Click to Select use the defaults.

A mask's row in the panel names its model ("Subject · BiRefNet Lite"). Its **Model** menu lists the other installed models of that kind; choosing one makes the mask again with it, which is an ordinary edit that ⌘Z takes back. The status bar reports each generation: "Generating subject mask with BiRefNet Lite…", then the time it took and how much of the frame it covers.

Every mask records the model it was made with (its id and version) in the edit, so a photo edited on one Mac says what it needs on another.

## When a model is missing

A photo whose mask names a model this Mac doesn't have still renders: a subject mask is made with Apple Vision, a click-to-select mask with the bundled SAM 2.1 Small, and a class mask with the bundled SegFormer. The mask's row says so in orange, for example "BiRefNet General is not installed — shown with Apple Vision instead.", with **Get…** and **Add Model…** beside it. If no click-to-select model is installed at all, that mask is empty and the row says so.

Exports say the same: the export queue's notes count the photos "with substituted masks", and Print and Contact Sheet add a sentence such as "2 photos used Apple Vision because BiRefNet General is not installed".

## Adding a model

The models in the catalogue are converted to Core ML by the scripts in the repository's `scripts/` folder, each pinned to one upstream revision and checksum:

| Model | For | Licence | Size | Script |
|---|---|---|---|---|
| SAM 2.1 Tiny, Base+, Large | Click to select | Apache-2.0 | 80, 166, 457 MB | `convert_sam2.py --size tiny`, `base-plus` or `large` |
| BiRefNet General, BiRefNet Portrait | Subject; the finest hair and structure, Portrait tuned for people. GPU only | MIT | 446 MB each | `convert_birefnet.py --variant general` or `portrait` |
| U²-Net, U²-Net Small | Subject | Apache-2.0 | 88 MB, 3 MB | `convert_u2net.py`, `--small` |
| MODNet | Subject; portraits only | Apache-2.0 | 13 MB | `convert_modnet.py` |
| IS-Net | Subject; fine wiry detail | Research use only | 88 MB | `convert_isnet.py` |

Each script writes a folder holding the Core ML package (three of them for a SAM model) and a `<id>.model.json` manifest that names the packages and their checksums. That folder, or a zip of it, is what Add Model… takes. `Sources/MLKit/Resources/Models/README.md` in the repository describes the manifest and the scripts' requirements.

Add Model… checks the folder before it keeps anything: exactly one manifest, a well-formed id, a kind this build knows, every package the manifest names and no other files, the packages' checksums, and, for a class model, its labels file. It then compiles each package once with Core ML and checks the inputs and outputs are the ones the manifest names. A model that fails any check is not added, and the sentence under the list says which check. Added models live in `models/<id>/` under the app's Application Support folder (inside the container for the sandboxed app); Reveal in Finder opens it. A model you added runs on the GPU even when the compute setting says Neural Engine, because an untried model can hang the Neural Engine's compiler.

## Memory

Models load when a mask first needs them and are let go when macOS reports memory pressure, then loaded again from their compiled copies when next needed. A large model such as BiRefNet General or SAM 2.1 Large takes a second or more to load and its share of memory while loaded, so on an 8 GB Mac the bundled models are the safer choice.

## Touch-up and sensor dust

Touch-up finds faces with Apple's Vision framework, built into macOS, and Sensor Dust uses no model at all: it is a classical detector. Neither appears in the list. See [Develop](Develop#modules).
