# Architecture

Swift 6 with strict concurrency, built with SwiftPM. No Xcode project.

## Modules

| Target | Role |
|---|---|
| `RawCore` | LibRaw behind a small C shim; the isolated decoder client; the reader for the metadata exports carry |
| `latent-rawdecoder` | The XPC service that runs LibRaw in its own sandbox |
| `PixelEngine` | The Metal render pipeline, edit stack, crop, healing, tone ranges, presence, presenter, exporter, resampler, HDR gain maps, safe file writes, memory-pressure monitor |
| `ColorKit` | Colour science: camera matrices, white balance, working space (Rec.2020 linear), output transforms |
| `LensKit` | A Lensfun database subset and a matcher, in pure Swift |
| `Catalog` | SQLite (GRDB) catalog, XMP sidecars, reconciliation, thumbnails and the thumbnail loader, filtering, folder access, export naming and batch planning |
| `MLKit` | Core ML: Segment Anything 2.1, SegFormer-B2, NAFNet; the export worker |
| `HelpKit` | Help window: the wiki's Markdown as blocks, links between pages, search |
| `latent-app` | SwiftUI and AppKit: the views, sidebar and filmstrip, editor model, menus and the one shortcut table, preferences, the Help window |
| `latent-cli` | Headless render for benchmarks and tests |

## The render pipeline

One Metal command buffer per render, stages back to back:

1. Black level and white balance on the raw plane.
2. Demosaic: RCD or bilinear at full resolution for tiles, or binning for previews. The result is cached per white balance and region, so tone edits skip it.
3. Neural denoise blend (if run), classic denoise, spot removal (patches in order, heal by a ratio field), lens corrections, all in camera space.
4. Colour and tone: highlight reconstruction, camera matrix, exposure, tone ranges (Highlights, Shadows, Whites, Blacks), local adjustments in scene-linear light, sigmoid tone mapping with display headroom, then grading (curve, master and RGB; HSL, vibrance, split toning) in a perceptual domain, soft proof.
5. Presence (texture, clarity, dehaze, defringe) and sharpening on the display-referred result.
6. Present: a single affine map folds crop, straighten, rotation, zoom and pan into one sampling pass to the screen, rolling highlights off to the headroom the screen shows at that moment. Export uses the same map into a packed 8- or 16-bit texture; a resized export adds a linear-light Lanczos 3 resample, and a gain map a second render with headroom.

The viewport keeps a binned whole-image preview always, and renders a full-resolution tile of the visible region when zoomed in, so gestures never wait on the pipeline. Frames are presented through a display link that runs only while a frame is pending, and a screen brightness change costs a present, not a render.

## Storage

Edits are a module-keyed JSON document. Adding a module is additive; old sidecars lack the key and get the default. Copy, paste, presets, snapshots and history are all operations on that one document. A catalog database SQLite reports as damaged is moved aside and rebuilt from the sidecars.

## Machine learning

Models are bundled as Core ML packages and compiled on first use into the app container. They run on the GPU by default; the Neural Engine is opt-in because its compiler hangs on some macOS 15 builds. Conversion scripts in `scripts/` pin the source revisions and verify checksums. When macOS runs low on memory, loaded models, cached render textures and, if critical, the AI denoise result are released and rebuilt when next needed.

## Tests and CI

327 XCTest tests and 13 Swift Testing tests across six test targets: `PixelEngineTests`, `CatalogTests`, `LensKitTests`, `MLKitTests`, `HelpKitTests` and `LatentAppTests`. Golden-image tests render a public-domain D750 raw with fifteen fixed edits and compare against reference PNGs. `HelpKitTests` checks that every wiki page parses, follows `_Sidebar.md`, and links only to pages and headings that exist. `LatentAppTests` tests the app target itself: the key and menu tables, command enabling, VoiceOver wording, and that the [Keyboard Shortcuts](Keyboard-Shortcuts) page matches `Sources/latent-app/Shortcuts.swift`, from which it is generated. GPU and camera-file tests skip themselves when their sample raw is absent. GitHub Actions builds LibRaw from the pinned commit, caches it, builds and runs the suite on an Apple Silicon runner on every push to main and every pull request.

Debug builds also carry a snapshot harness that walks the app through its main views and saves a picture of the window at each, without screen-recording permission (`LATENT_SNAPSHOT_DIR`; see `SnapshotHarness.swift`). Release builds contain none of it.

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
