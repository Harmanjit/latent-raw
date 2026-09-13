# Latent, a catalog management and RAW editor for macOS

A native, Apple Silicon–first RAW photo manager and non-destructive editor for macOS.
Repository: `Harmanjit/latent-raw`.

- **Platform:** macOS 15 (Sequoia) and 26 (Tahoe), Apple Silicon M3 or newer.
  Metal 3 is the baseline; Metal 4 only for optional fast paths on Tahoe.
- **License:** GPLv3. See `LICENSE`.
- **Status:** beta (Phase 7). Editing, catalog, AI masks, export and soft-proofing work; expect rough edges.
- **Name:** the project was called *rawhead* until September 2026. Folders
  catalogued by those builds have a `_rawhead/` container; opening them in
  Latent renames it to `_latent/` in place, keeping every edit and sidecar.

See `DESIGN.md` for the full architecture: storage layout, pipeline design,
efficiency rules and the roadmap. See `PHASE0.md` for exactly what this
spike needs to prove before Phase 1 starts.

## Layout

```
Sources/
  RawCore/       LibRaw wrapper — unpacking, EXIF, embedded previews
  PixelEngine/    Metal pipeline: kernels, stage cache, heaps
  ColorKit/       ICC / ColorSync / camera matrix handling
  LensKit/        Lensfun + embedded lens-correction lookup
  Catalog/        Per-folder catalogs: GRDB schema, XMP read/write, import
  MLKit/          Vision + Core ML masking
  latent-cli/    Headless renderer for golden-image tests and benchmarks
  latent-app/    The SwiftUI/AppKit editor (viewport, adjustments, export)
Tests/            Unit and golden-image tests
vendor/           Vendored C/C++ dependencies (LibRaw, etc.) built as XCFrameworks
TestAssets/       Sample RAW files for the CI test matrix (not committed — see below)
```

## Building (on macOS, Apple Silicon, Xcode 16+)

```
swift build                                   # everything, debug
swift test                                    # unit + golden tests (GPU tests skip without TestAssets)
scripts/build_libraw.sh                      # once per clone: builds vendor/LibRaw.xcframework from a pinned tag
swift run latent-app TestAssets/photo.nef    # the editor, opening a file straight away
swift run latent-cli render photo.nef --out /tmp/out.png   # headless render + timings
```

For a proper `.app` (Dock icon, window memory, signed for this Mac):

```
scripts/make_app.sh 0.1.0        # builds release and assembles build/Latent.app
open build/Latent.app
```

## Keyboard reference

| Keys | Action |
|---|---|
| G / D | Library / Develop |
| ← → | previous / next image (loads it in Develop) |
| Return | open the selection in Develop |
| 0–5, P / X / U | rating, pick / reject / unflag |
| ⌘[ ⌘] | rotate |
| ⌘0 ⌘1 ⌘= ⌘- | fit, 100%, zoom in/out |
| \ | before / after |
| ⌘Z ⌘⇧Z | undo / redo |
| ⌘⇧C ⌘⇧V | copy / paste settings (to the Library selection when several are selected) |
| ⌘U | Auto adjust |
| ⌘⇧O ⌘⇧E | open folder, export selection |

`RawCore` depends on LibRaw as a vendored C library. See `vendor/README.md`
for how it's fetched and built as an XCFramework — this step needs to run
on macOS since it compiles native code for arm64.

## Test assets

Sample RAW files are intentionally not committed (they're large and mostly
redistributable-but-not-ours). `TestAssets/README.md` lists exactly which
files to pull from raw.pixls.us for the CI matrix, plus where to drop your
own D750/A7 III samples.

## Contributing

Not yet open for contributions — still pre-Phase-1.
