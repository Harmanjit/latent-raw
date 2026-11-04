# Coming from Lightroom

If you know Lightroom Classic, much of Latent will feel familiar: the same five views, many of the same keys, collections, virtual copies, masks. This page maps one onto the other, and is honest about what Latent does differently and what it doesn't have.

Latent is an independent open-source project. It is not made by, affiliated with or endorsed by Adobe; Lightroom is Adobe's trademark, named here only to compare.

## Moving your photos across

**Latent can't import a Lightroom catalog.** It doesn't read `.lrcat` files, Lightroom's collections or its develop settings, and it doesn't read the `.xmp` files Lightroom writes beside raws. Your raw files themselves open in Latent as they are, but ratings, flags, labels, keywords and edits made in Lightroom don't come across.

What you can do:

- **Keep both.** Latent never changes your raw files and keeps its catalog inside each folder, so it can sit alongside Lightroom on the same folders. Neither will see the other's edits.
- **Start fresh on new shoots.** Many people move one shoot at a time: open the folder in Latent, cull and edit there, and leave older shoots in Lightroom.
- **Use exported files.** A JPEG or TIFF exported from Lightroom opens in Latent with its look, and Latent carries the file's own keywords into its exports.

Going the other way, Latent's **Original + XMP sidecar** export copies a raw with an `.xmp` beside it that Lightroom reads for the rating, colour label and keywords (not the edit). See [Exporting originals](Export#exporting-originals).

## The ideas, side by side

| In Lightroom | In Latent |
|---|---|
| One catalog for everything, imported into | **One catalog per folder**, in a `_latent` folder inside it. There is no import: open the folder. Subfolders can join their parent's catalog or keep their own. See [The catalog](Library#the-catalog). |
| Import dialog | **None.** Copy files into a folder with Finder, and Latent notices them; or let **Auto Import** move them in from a watched folder. **Recently Added** plays the part of Previous Import. See [Watching folders](Library#watching-folders). |
| Folders panel | The **sidebar**: favourite folders and everything inside them. See [The sidebar](Library#the-sidebar). |
| Collections, smart collections, collection sets, Quick Collection, target collection | **The same**, with B and ⌘N, but each belongs to one folder's catalog. See [Collections and Keywords](Collections-and-Keywords). |
| Keywords and keyword hierarchies | **The same.** Hierarchies are written as `lr:hierarchicalSubject`, as Lightroom writes them. |
| Stars, flags, colour labels | **The same**, with the same keys. Latent writes labels by their English colour name, as Lightroom does. |
| Virtual copies | **The same**, with ⌘', Set Copy as Master and a badge in the grid. See [Virtual copies](Library#virtual-copies). |
| XMP sidecars beside the raw | Latent's sidecars are standard XMP but live in `_latent/xmp/`, not beside the raw. They are the source of truth: the database can always be rebuilt from them. |
| Develop presets | **Develop presets** (five built in, plus your own, saved as files you can share), with an **Amount** slider, and **Previous** (⌥⌘V). Lightroom presets can't be imported. See [Presets and clipboard](Develop#presets-and-clipboard). |
| Export presets | **Export presets**, multi-preset export and **Export with Previous**. See [Export](Export). |
| Profiles (Adobe Standard, Adobe Color and the rest) | **Profiles**: Latent Standard, Neutral and Flat, creative and black and white looks, and DNG camera profiles (`.dcp`) you import yourself. See [Develop](Develop#modules). |
| Masks: Subject, Sky, Objects, People, brush, gradients, ranges | **Local Adjustments**: Subject, Select by Class (sky, people, vegetation and more), Click to Select, Select Objects (Box), brush, gradients, colour and luminance ranges, combined with add, subtract and intersect. See [Masking](Masking). |
| Generative Remove, Content-Aware Remove | **Remove**, which fills from the photo itself, with **Detect Objects**. It is not generative. See [Remove and Detect Objects](Develop#remove-and-detect-objects). |
| Lens Blur | **Lens Blur**, from a depth model you add, or from the subject mask. See [Lens Blur](Develop#lens-blur). |
| Denoise | **AI Noise Reduction**, run once per photo and blended at any strength. |
| Photo Merge: HDR, Panorama, HDR Panorama | **The same three** (HDR Panorama is experimental). See [Photo Merge](Photo-Merge). |
| Soft proofing | **Soft Proof**, with paper and ink simulation and proof copies. See [Soft proofing](Develop#soft-proofing). |
| Print module | **File › Print…** with a photo layout, and **File › Contact Sheet…**. See [Print](Export#print). |
| Edit in Photoshop | **Edit in External Editor** (⌘E), into the application you choose. See [Edit in External Editor](Export#edit-in-external-editor). |
| Snapshots and history | **The same**; history keeps thirty steps per photo. See [History and snapshots](Develop#history-and-snapshots). |

## Keys that are the same

G, E, C, N and D for the views; 0–5 for stars; P, X and U for flags; 6–9 for colour labels; B for the target collection; ⌘N for a new collection; ⌘' for a virtual copy; ⌘[ and ⌘] to rotate; R for crop, with O and ⇧O for the crop guides; W for the White Balance Selector; J for clipping; V for black and white; `\` for before and after; ⌘U for Auto; ⇧⌘C and ⇧⌘V to copy and paste settings; ⌥⌘V for Previous; ⇧⌘E to export and ⌥⇧⌘E for Export with Previous; ⌘E for the external editor; ⌃H, ⌃⇧H, ⌃M and ⌃⇧M for Photo Merge.

**Different:** spot removal is **H**, red-eye is **Y**, and ⌘R refreshes the open folder. Masks have no key; use the **Add** menu in Local Adjustments or **Develop › Masks**. The full list is on [Keyboard Shortcuts](Keyboard-Shortcuts).

## What works differently

- **The folder is the catalog.** Move a folder to another disk or another Mac and its catalog goes with it. There is no "missing photo": a photo deleted from the folder leaves the catalog, and comes back with its edits if you put the file back.
- **No previews to build.** Every slider renders at full quality as you drag; there are no Smart Previews or 1:1 previews to wait for.
- **Model masks are made again when needed,** from the photo, rather than stored, so an export always matches the screen. The edit records which model made each mask.
- **Machine learning runs on your Mac.** Nothing is uploaded and nothing is downloaded. Models beyond the bundled ones are converted and added by you. See [Models](Models).
- **Edits are not pinned to a process version.** When Latent improves an algorithm, older edits render with the new one.

## What Latent doesn't have

Latent is younger and smaller than Lightroom. Among the things it doesn't do (the full, honest list is on [Limitations](Limitations)):

- Import of Lightroom catalogs, presets or edits.
- Cloud sync, mobile and web apps, sharing, publish services, and the Map, Book and Web modules.
- Import from memory cards with a dialog, tethered shooting, and video.
- Plug-ins.
- Generative AI fill, Adaptive profiles, and LUT-based creative profiles.
- Searching across folders: each folder is its own catalog, with its own collections.
- People view (face recognition); Latent finds faces only to retouch them.
- Tone curves, Point Colour and grain inside masks, and a depth range mask.
- Fujifilm X-Trans and Sigma Foveon raws; Latent renders Bayer sensors only.
- Intel Macs, Windows and macOS before 15.
