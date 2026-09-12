# rawhead

A native, Apple Silicon–first RAW photo manager and non-destructive editor for macOS.

- **Platform:** macOS (latest), Apple Silicon M3 or newer, Metal 4.
- **License:** GPLv3. See `LICENSE`.
- **Status:** Phase 0 (spike). Nothing here is stable.

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
App/rawhead/      The SwiftUI/AppKit application target (Xcode project)
Tests/            Unit and golden-image tests
vendor/           Vendored C/C++ dependencies (LibRaw, etc.) built as XCFrameworks
TestAssets/       Sample RAW files for the CI test matrix (not committed — see below)
```

## Building (on macOS, Apple Silicon, Xcode 16+)

This repo was scaffolded outside of macOS, so nothing has been build-verified yet.
The first thing to do on your Mac is:

```
swift package resolve
swift build            # builds the library targets: RawCore, PixelEngine, etc.
open App/rawhead.xcodeproj   # once the Xcode project is generated — see PHASE0.md
```

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
