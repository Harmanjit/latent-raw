# Phase 0 checklist

Tracks DESIGN.md §13. **Phase 0 is closed** (September 2026): everything
below that mattered is done, and Phase 1 work (tiled zoom, stage cache)
has started on top of it. Unchecked items are deferred, not blocking —
notes say why.

## 0. Prerequisites
- [x] Xcode installed (last version compatible with your current OS is fine —
      confirmed working: Xcode 26.2 on Sequoia, M4)
- [x] `xcode-select -s /Applications/Xcode.app/Contents/Developer`
- [x] `swift --version` reports Swift 6 (confirmed: 6.2.3, target arm64-apple-macosx15.0)
- [x] `brew install autoconf automake libtool pkg-config`

## 1. Vendor LibRaw
- [x] `git ls-remote --tags --sort=-v:refname https://github.com/LibRaw/LibRaw.git | head -5`
      to get the real current tag — don't hardcode one from this doc
- [x] Follow `vendor/README.md` to build `LibRaw.xcframework`. If you hit
      "couldn't be copied... item with the same name already exists": that's
      a stale/partial output — `rm -rf vendor/LibRaw.xcframework` and rerun
      `xcodebuild -create-xcframework` (fixed in the README; don't pre-stage
      the `macos-arm64/` folder yourself, xcodebuild builds that itself)
- [x] `#include <libraw/libraw.h>` resolves from `CLibRaw` target — you may
      need to add a `linkerSettings`/`cSettings` header search path in
      `Package.swift` pointing at the XCFramework's headers; this scaffold
      assumes SwiftPM can find them via the XCFramework but that's untested

## 2. First build
- [x] `swift build` succeeds for all library targets
- [x] Fix any drift between `clibraw_shim.cpp` and the real LibRaw API —
      it was written from memory of the 0.20/0.21 API shape, not against
      real headers (see the note at the top of that file)

## 3. Zero-copy ingest decision (DESIGN.md §13 task 2)
- [x] Instrument `RawFile.rawSensorPlane()` — LibRaw's allocation is
      page-aligned but its length is not a page multiple
- [x] `makeBuffer(bytesNoCopy:)` not usable without padding past the
      allocation — rejected
- [x] Decision: keep the copy (option c). Measured ~3ms per image, paid
      once. See the note in `GPUContext.makeSharedBuffer`.

## 4. Correctness
- [x] Drop sample files into `TestAssets/` per `TestAssets/README.md`
- [x] `swift run latent-cli render TestAssets/nikon_d750_sample.nef --out /tmp/out.png`
      produces a recognizable (if rough — it's bilinear) image
- [ ] Repeat for the A7 III sample — deferred until an ARW is dropped in
- [ ] Render the same files in RawTherapee with a neutral profile, compare
      colors by eye first, then decide what "within tolerance" should mean
      for the golden-image tests — deferred; renders look right by eye
      against a Photoshop export of the same NEF, but this is still owed

## 5. Instruments verification
- [ ] Metal System Trace: not done; the code follows the §7.2 policy by
      construction (see `GPUContext`) and there's one copy, by decision
- [x] Timings, measured with `latent-cli --repeat` (M4, warm GPU):
      - Full 24MP RCD + colour: ~46ms — over the 30ms target; but the
        viewport never renders the full frame any more (tiles: ~9ms for
        a 5MP tile; half-size preview: ~3ms), so this only matters for export
      - LibRaw unpack: ~210-250ms, dominates file-open time
      - Idle: no display link, no timers — the app draws only on input

## 6. Metal 3/4 API boundary check (DESIGN.md §13 task 6)
- [x] Nothing in `PixelEngine` uses a Metal-4-only API; everything builds
      and runs on Sequoia. Revisit when residency sets or in-shader ML
      are actually wanted.

## Exit
All boxes above checked = Phase 0 done, move to Phase 1 (DESIGN.md §14):
highlight reconstruction, sigmoid tone mapping, the real stage cache,
viewport-resolution rendering.
