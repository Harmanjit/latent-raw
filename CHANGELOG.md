# Changelog

What changed in each released version of Latent. The user guide's
[What's New](docs/wiki/Whats-New.md) page describes the 1.0.0 features in
more detail, with links to where each is explained.

## 1.0.0 (2026)

The first public release, after the 0.9.0 beta of September 2026. Latent
is still signed ad hoc and not notarised, so the first launch needs
**Open Anyway** in System Settings › Privacy & Security; see
[Installation](docs/wiki/Installation.md#the-gatekeeper-dialog).

### Upgrading from 0.9

- **Catalogs are updated once, one way.** The first time 1.0.0 opens a
  folder catalogued by 0.9, it updates the catalog database in `_latent/`
  to the new format. Just before, it saves a copy of the old catalog in
  `_latent/backups/`, which Settings › Folders › Restore Catalog Backup…
  can bring back. Going back to 0.9 with an updated folder is not
  supported.
- **Thumbnails are rebuilt once.** The thumbnail cache has a new format
  (cache version 2), so each folder's thumbnails are made again in the
  background the first time 1.0.0 opens it.
- **Settings, presets and folder access carry over.** They live in the
  app's container, which keeps the same name, so replacing `Latent.app`
  in Applications keeps them. Edits, ratings, keywords and sidecars are
  never touched by the update.
- A new download is quarantined again, so macOS asks for **Open Anyway**
  once more for the 1.0.0 app.

### New features

- **Retouching.** Sensor dust removal (Find Spots, saved dust maps per
  camera, and Photo › Remove Dust… for a whole selection), portrait
  Touch-up (skin smoothing, teeth whitening, brighter eyes and blemishes,
  per face), and a choice of subject-selection models in Settings › AI ›
  Models, with BiRefNet Lite bundled and Add Model… for models you
  convert yourself, checked against their manifest before they are kept.
- **Organising.** Collections, smart collections (with many more rules,
  per-rule joins, between and empty operators) and collection sets;
  hierarchical keywords written to XMP, a Keyword List, keyword
  suggestions and Add Keywords (⌘K); colour labels; title, caption,
  creator, copyright and the IPTC More fields; virtual copies and
  versions; stacks; Find Duplicates and Verify Files; Edit Capture Time
  and Geotag from GPX Track; ratings and keywords read from other apps'
  sidecars.
- **Folders and files.** Folder watching and Refresh Folder, Auto Import
  from a watched folder, Duplicate, Rename with Template and 23 new naming
  tokens, a daily catalog backup with Restore Catalog Backup, JPEG, HEIC,
  TIFF, PNG, WebP, AVIF and JPEG XL pictures, RAW+JPEG pairs, and more raw
  extensions.
- **Culling and the grid.** A richer filter bar (all-field search, rating
  ranges, dates, kinds, clickable range histograms, Similar to This Photo,
  filter presets and Remember Filter per Source), Select by Flag, Rating
  and Label, Auto Advance, Lightroom's grid sort orders and grid marks.
- **Viewing.** Before/After views and Reference view, the Navigator in
  every view, focus peaking, raw clipping, colour assessment, High Quality
  Preview, a loupe overlay, Mirror Image Mode, a shortcuts overlay and a
  welcome sheet.
- **Colour and tone.** Camera and creative profiles with camera profile
  import, Saturation, Black & White, three-way Colour Grading,
  Calibration, Point Colour, a region tone curve, white balance presets
  and selector, Auto tone, hue isolation, HDR ranges, Match Exposures by
  Histogram, process versions, and a nine-band **Tone Equalizer** with
  Auto Align and a live band histogram.
- **Geometry, detail and effects.** Upright and the Transform panel, crop
  guides, flat-field correction, hot pixel removal, manual chromatic
  aberration, grain, post-crop vignetting, Lens Blur over a depth map,
  Inpaint Opposed highlight reconstruction, the LMMSE demosaic for high
  ISO, the camera's own white balance presets and DNG opcode corrections.
- **Masks and retouching.** Masks built from several components with
  blend modes, Edge refine, Smooth, Curve, Point Colour, Grain and a Tone
  Equalizer inside a mask; Select Objects, Channel and Pick Range, brush
  Auto Mask; mask presets and Copy and Paste Mask; a content-aware Remove
  with Fill and Blur modes, per-patch Opacity, Detect Objects, reflection
  removal through an imported model and Pet Eye.
- **Scopes.** RGB parade, two-up scopes, vectorscope guides, pinned colour
  samples, Selected Mask Only and Overlay Reference.
- **Export, print and proofing.** Wider colour spaces and ICC profiles,
  output sharpening, sizing and ppi, DNG with the look baked in or left
  editable, full HDR HEIC and AVIF, 16-bit PNG, HEIC, TIFF, OpenEXR, PDF
  pages and Combine into one PDF, borders, Export with Previous, adding
  exports to the catalog, soft proofing with rendering intents and black
  point compensation, and print presets, sharpening and printer profiles.
- **Presets and keyboard.** Preset folders, favourites and Manage
  Presets, preset Amount, Previous (⌥⌘V), selective Copy and Paste
  Settings, Sync Last Change, and rebindable shortcuts in Settings ›
  Keyboard.
- **Help.** Getting Started, three tutorials, Coming from Lightroom, a
  Glossary, an FAQ, and new Tone Equalizer and Filter Bar pages, all inside
  the app under Help › Latent Help.

### Speed

Measured on a 16 GB M4 against the 0.9-era code; the full numbers are in
[`docs/Performance-Profile.md`](docs/Performance-Profile.md).

- **Opening and switching photos no longer freezes the window.** The raw
  is decoded in the background and the neighbouring photos are decoded
  ahead, so a switch takes about 70-80 ms instead of 350-450 ms. While a
  photo opens, Loupe shows the camera's embedded JPEG as a placeholder
  until the full render is ready.
- **Slider drags are smooth.** A slider tick costs about 6 ms of main
  thread time instead of 22 (12 instead of 52 with every panel group
  open), renders no longer wait for the GPU on the main thread, and a drag
  shows a quicker draft, so heavy edits drag at full frame rate at fit.
- **High Quality Preview** is about four times faster and no longer
  blocks the window; selection to a sharp image went from about a second
  to about 0.2 s.
- **Launch** to the first photo: about 910 ms to 670 ms.
- **Import** of 2,000 raws from a cold disk: about 104 s to 20 s; a
  refresh of an unchanged folder is about five times faster; thumbnails
  are made about twice as fast.
- **Export** runs several photos at once (Automatic is 3 on a 16 GB Mac),
  about 2.4 times faster for a batch, and combined PDF pages are about 16
  times smaller.
- **Large folders**: smart collections with date rules evaluate about
  thirty times faster on 10,000 photos, and rating many photos while a
  collection is shown no longer stalls.

### Fixes

- **Data safety.** A folder or file renamed or moved outside Latent keeps
  its edits and sidecars, including files in iCloud waiting to download;
  moves and copies refuse a destination whose catalog can't be read; a
  damaged catalog is set aside and rebuilt from the sidecars; sidecar and
  thumbnail writes stay within file-name limits and never follow a link;
  an edit saved by a newer build is never overwritten.
- **Crash fixes for damaged files.** Damaged or unusual raws, sidecars,
  dust maps and model files are refused with a message instead of
  crashing, and a decode that hangs is ended inside the isolated decoder.
- **Correctness.** Undo and stored history in Develop, mask crashes,
  crop handling, lens profiles for in-camera crop modes, panorama
  brightness from HDR DNGs and bracket grouping, and a long list of
  smaller fixes from the November code review.
- **Packaging.** The app carries every third-party licence text, the
  release bundle is built and checked on every push, and `make_app.sh`
  now refuses a release build without an explicit version.

### Known limits

- **HDR Panorama is experimental.** It is tested on synthetic sweeps and
  on windows cut from a real bracket, but never on a real bracketed sweep.
  Panoramas are single-row.
- **Fujifilm X-Trans is not rendered**, nor Sigma Foveon, monochrome or
  four-colour sensors: those raws are catalogued for their metadata only.
- **Floating-point raw DNGs cannot be opened**, such as the output of
  HDRMerge.
- **SegFormer is for research use only.** The bundled SegFormer model
  behind Select by Class is under NVIDIA's non-commercial licence
  (research and evaluation use only).
- The wiki's [Limitations](docs/wiki/Limitations.md) page lists the rest.

## 0.9.0 (September 2026)

The beta for review: editing with red-eye and brush healing, a catalog
with a folder sidebar, Custom sort, Finder tags, moving and renaming
images, undo in the Library, AI masks, Loupe, Compare and Survey, export
with HDR gain maps and a watermark, soft proofing, printing, contact
sheets, a slideshow, hand-off to an external editor and Photo Merge (HDR,
single-row panoramas and an experimental HDR Panorama, all writing a
DNG).
