# Architecture

Swift 6 with strict concurrency, built with SwiftPM. No Xcode project.

## Modules

| Target | Role |
|---|---|
| `RawCore` | LibRaw behind a small C shim; the isolated decoder client; the reader for the metadata exports carry |
| `latent-rawdecoder` | The XPC service that runs LibRaw in its own sandbox |
| `PixelEngine` | The Metal render pipeline, edit stack, crop, healing and red-eye, tone ranges, presence, presenter and magnifier, what mouse and trackpad input means, exporter, resampler, watermark, HDR gain maps, page layout for prints and contact sheets, slideshow transitions, safe file writes, memory-pressure monitor. It also owns Photo Merge's GPU kernels, which MergeKit drives: `MergeHDR`, `MergeWarp`, `MergeDeghost`, `MergePanoPrep` and `MergePanoBlend` |
| `ColorKit` | Colour science: camera matrices, white balance, working space (Rec.2020 linear), output transforms |
| `LensKit` | A Lensfun database subset and a matcher, in pure Swift |
| `Catalog` | SQLite (GRDB) catalog, XMP sidecars, reconciliation, thumbnails and the thumbnail loader, filtering and sorting (Custom order, Finder tags), moving, copying and renaming images with their sidecars, undo for library actions, folder history, folder access, export naming, batch planning and size estimates |
| `MLKit` | Core ML: Segment Anything 2.1, SegFormer-B2, NAFNet; Vision face landmarks for red-eye; the export worker, which also renders pixels for prints, contact sheets and slides |
| `MergeKit` | Photo Merge, with no user interface of its own: frame alignment (`Align`), deghosting (`Deghost`), the HDR merge and its dialog preview (`HDR`), the panorama's geometry, prep and stitcher (`Pano`), the HDR panorama that composes the two (`HDRPano`), the float16 LinearRaw DNG writer (`DNG`) and the `latent:Merge` recipe and its XMP (`Recipe`). The app sees it only through the `HDRMerging`, `PanoramaMerging` and `HDRPanoramaMerging` protocols, so dialogs and jobs are tested with fake engines |
| `HelpKit` | Help window: the wiki's Markdown as blocks, links between pages, search |
| `latent-app` | SwiftUI and AppKit: the views, sidebar and filmstrip, Survey, full-screen image and the second display, editor model, menus and the one shortcut table, preferences, print, contact sheets, the slideshow, Edit in External Editor, the Help window |
| `latent-cli` | Headless render for benchmarks and tests, plus the merge commands the engine is developed against: `merge-hdr` (with `--preview`), `pano-layout`, `merge-pano`, `merge-hdrpano` and `catalog` |

## The render pipeline

One Metal command buffer per render, stages back to back:

1. Black level and white balance on the raw plane.
2. Demosaic: RCD or bilinear at full resolution for tiles, or binning for previews. The result is cached per white balance and region, so tone edits skip it.
3. Neural denoise blend (if run), classic denoise, spot removal (patches in order, heal by a ratio field; a brush stroke heals piece by piece along its path), red-eye (flash-red pixels inside each circle turned a dark neutral), lens corrections, all in camera space.
4. Colour and tone: highlight reconstruction, camera matrix, exposure, tone ranges (Highlights, Shadows, Whites, Blacks), local adjustments in scene-linear light, sigmoid tone mapping with display headroom, then grading (curve, master and RGB; HSL, vibrance, split toning) in a perceptual domain, soft proof.
5. Presence (texture, clarity, dehaze, defringe) and sharpening on the display-referred result.
6. Present: a single affine map folds crop, straighten, rotation, zoom and pan into one sampling pass to the screen, rolling highlights off to the headroom the screen shows at that moment. Past 200% it samples the nearest pixel, so pixels show as squares, and the magnifier is a third layer drawn in the same pass. Export uses the same map into a packed 8- or 16-bit texture; a resized export adds a linear-light Lanczos 3 resample, a watermark is stamped into the pixels after that, and a gain map needs a second render with headroom.

The viewport keeps a binned whole-image preview always, and renders a full-resolution tile of the visible region when zoomed in, so gestures never wait on the pipeline. The magnifier renders a small full-resolution tile of the area under the pointer, only when the pointer leaves the one it has, at most every 33 ms. Frames are presented through a display link that runs only while a frame is pending, and a screen brightness change costs a present, not a render. The Loupe on a second display draws the editor's own preview, with no second decode or render.

## Storage

Edits are a module-keyed JSON document. Adding a module is additive; old sidecars lack the key and get the default. Copy, paste, presets, snapshots and history are all operations on that one document. A catalog database SQLite reports as damaged is moved aside and rebuilt from the sidecars.

A file's Finder tags are cached in the catalog (`images.finder_tags`) and read again at every reconcile; the file stays the source. The Custom sort's arrangement is a list of paths in `_latent/custom-order.json`, outside the database so a rebuild keeps it. Moving, copying or renaming an image writes its sidecar at the destination before the file arrives and removes the original last, never overwrites a file, and changes only the open catalog's database; any other catalog catches up from the sidecar the next time it opens.

## Machine learning

Models are bundled as Core ML packages and compiled on first use into the app container. They run on the GPU by default; the Neural Engine is opt-in because its compiler hangs on some macOS 15 builds. Conversion scripts in `scripts/` pin the source revisions and verify checksums. When macOS runs low on memory, loaded models, cached render textures and, if critical, the AI denoise result are released and rebuilt when next needed.

## Tests and CI

1,112 XCTest tests and 13 Swift Testing tests across seven test targets: `PixelEngineTests`, `CatalogTests`, `LensKitTests`, `MLKitTests`, `MergeKitTests`, `HelpKitTests` and `LatentAppTests`. Golden-image tests render a public-domain D750 raw with seventeen fixed edits, brush-stroke healing and red-eye among them, and compare against reference PNGs. Moves and copies are tested with failures injected part-way. `MergeKitTests` covers Photo Merge without the app: DNGs written and read back through LibRaw, synthetic brackets and sweeps whose answer is known exactly, and the real sample sets under `TestAssets/merge` and `TestAssets/pano` (three brackets and a 17-frame sweep), which skip themselves where those files aren't present. `HelpKitTests` checks that every wiki page parses, follows `_Sidebar.md`, and links only to pages and headings that exist. `LatentAppTests` tests the app target itself: the key and menu tables, command enabling, VoiceOver wording, and that the [Keyboard Shortcuts](Keyboard-Shortcuts) page matches `Sources/latent-app/Shortcuts.swift`, from which it is generated. GPU and camera-file tests skip themselves when their sample raw is absent. GitHub Actions builds LibRaw from the pinned commit, caches it, builds and runs the suite on an Apple Silicon runner on every push to main and every pull request.

Debug builds also carry a snapshot harness that walks the app through its main views (and, on request, dialogs such as Rename, Print, Contact Sheet and the quality comparison, the slideshow and full-screen image) and saves a picture of the window at each, without screen-recording permission (`LATENT_SNAPSHOT_DIR`; see `SnapshotHarness.swift`). Release builds contain none of it.

## Numbers

Measured on an M4 MacBook Air. On an M1 Pro MacBook Pro the editor is at least as fast: slider re-renders stay under 3 ms, since that chip has the larger GPU.

| | |
|---|---|
| Preview render | 2–4 ms |
| Tile at 100% | 4–11 ms |
| Slider with demosaic cached | ~1 ms |
| Export, 24 MP JPEG | ~130 ms plus decode |
| Raw decode, 24 MP NEF | ~220 ms in process, ~240 ms via the service |
| SegFormer class mask | ~260 ms |
| SAM 2 click | ~40 ms after a one-time encode |
| NAFNet denoise, 24 MP | ~11 s |
