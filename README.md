# rawhead

A native, Apple Silicon–first RAW photo manager and non-destructive editor for macOS.

- **Platform:** macOS 15 (Sequoia) and 26 (Tahoe), Apple Silicon M3 or newer.
  Metal 3 is the baseline; Metal 4 only for optional fast paths on Tahoe.
- **License:** GPLv3. See `LICENSE`.
- **Status:** Phase 1 (core pipeline). Nothing here is stable.

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
  rawhead-cli/    Headless renderer for golden-image tests and benchmarks
  rawhead-app/    The SwiftUI/AppKit editor (viewport, adjustments, export)
Tests/            Unit and golden-image tests
vendor/           Vendored C/C++ dependencies (LibRaw, etc.) built as XCFrameworks
TestAssets/       Sample RAW files for the CI test matrix (not committed — see below)
```

## Building (on macOS, Apple Silicon, Xcode 16+)

```
swift build                                   # everything, debug
swift test                                    # unit + golden tests (GPU tests skip without TestAssets)
swift run rawhead-app TestAssets/photo.nef    # the editor, opening a file straight away
swift run rawhead-cli render photo.nef --out /tmp/out.png   # headless render + timings
```

The app is a plain SwiftPM executable for now — no `.xcodeproj`, no app
bundle. That's deliberate while the pipeline is moving fast.

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
