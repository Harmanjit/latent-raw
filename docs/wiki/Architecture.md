# Architecture

Swift 6 with strict concurrency, built with SwiftPM. No Xcode project.

## Modules

| Target | Role |
|---|---|
| `RawCore` | LibRaw behind a small C shim; the isolated decoder client |
| `latent-rawdecoder` | The XPC service that runs LibRaw in its own sandbox |
| `PixelEngine` | The Metal render pipeline, edit stack, crop, healing, presence, presenter, exporter |
| `ColorKit` | Colour science: camera matrices, white balance, working space (Rec.2020 linear), output transforms |
| `LensKit` | A Lensfun database subset and a matcher, in pure Swift |
| `Catalog` | SQLite (GRDB) catalog, XMP sidecars, reconciliation, thumbnails, filtering, naming |
| `MLKit` | Core ML: Segment Anything 2.1, SegFormer-B2, NAFNet; the export worker |
| `latent-app` | SwiftUI and AppKit: the views, editor model, preferences |
| `latent-cli` | Headless render for benchmarks and tests |

## The render pipeline

One Metal command buffer per render, stages back to back:

1. Black level and white balance on the raw plane.
2. Demosaic: RCD or bilinear at full resolution for tiles, or binning for previews. The result is cached per white balance and region, so tone edits skip it.
3. Neural denoise blend (if run), classic denoise, spot removal, lens corrections, all in camera space.
4. Colour and tone: highlight reconstruction, camera matrix, exposure, local adjustments in scene-linear light, sigmoid tone mapping with display headroom, then grading (curve, HSL, vibrance, split toning) in a perceptual domain, soft proof.
5. Presence (texture, clarity, dehaze, defringe) and sharpening on the display-referred result.
6. Present: a single affine map folds crop, straighten, rotation, zoom and pan into one sampling pass to the screen. Export uses the same map into a packed 8- or 16-bit texture.

The viewport keeps a binned whole-image preview always, and renders a full-resolution tile of the visible region when zoomed in, so gestures never wait on the pipeline.

## Storage

Edits are a module-keyed JSON document. Adding a module is additive; old sidecars lack the key and get the default. Copy, paste, presets, snapshots and history are all operations on that one document.

## Machine learning

Models are bundled as Core ML packages and compiled on first use into the app container. They run on the GPU by default; the Neural Engine is opt-in because its compiler hangs on some macOS 15 builds. Conversion scripts in `scripts/` pin the source revisions and verify checksums.

## Tests and CI

125 XCTest cases across four test targets. GPU and camera-file tests skip themselves when the sample raw is absent. GitHub Actions builds LibRaw from the pinned commit, caches it, builds and runs the suite on an Apple Silicon runner on every push.

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
