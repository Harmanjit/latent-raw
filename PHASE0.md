# Phase 0 checklist

Tracks DESIGN.md §13. Work through this on your Mac in order — each step
unblocks the next.

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
- [ ] Instrument `RawFile.rawSensorPlane()` — check actual pointer alignment
      and length of LibRaw's `raw_image` allocation for a real D750/A7III file
- [ ] If page-aligned with page-multiple length: try `makeBuffer(bytesNoCopy:)`
      directly, skip the copy in `GPUContext.makeSharedBuffer`
- [ ] If not: measure the copy cost in Instruments. DESIGN.md §13 estimates
      a few ms for ~48MB — confirm, and decide whether a LibRaw allocator
      patch (option b) is worth the maintenance cost. Default to the copy
      unless the measurement says otherwise.

## 4. Correctness
- [x] Drop sample files into `TestAssets/` per `TestAssets/README.md`
- [x] `swift run rawhead-cli render TestAssets/nikon_d750_sample.nef --out /tmp/out.png`
      produces a recognizable (if rough — it's bilinear) image
- [ ] Repeat for the A7 III sample
- [ ] Render the same files in RawTherapee with a neutral profile, compare
      colors by eye first, then decide what "within tolerance" should mean
      for the golden-image tests in `Tests/PixelEngineTests`

## 5. Instruments verification
- [ ] Metal System Trace: confirm buffer/texture allocations match the
      storage-mode policy in DESIGN.md §7.2 (shared for the sensor plane,
      private for the demosaiced texture)
- [ ] Confirm no unexpected extra copies in the CPU->GPU path
- [ ] Record actual timings against the targets in DESIGN.md §13:
      - GPU time for demosaic + color stages: target <30ms at 24MP
        (note: Phase 0's demosaic is bilinear, not RCD, so this number
        isn't final — it's a pipeline-overhead sanity check for now)
      - File-open-to-screen: target <300ms
      - Idle CPU/GPU: ~0%

## 6. Metal 3/4 API boundary check (DESIGN.md §13 task 6)
- [ ] rawhead must run on both Sequoia (macOS 15) and Tahoe (macOS 26) —
      confirm which Metal APIs are Metal 3 (available on both) vs.
      Metal-4-only (Tahoe-only): residency sets, tensors, in-shader ML
- [ ] Update `GPUContext.swift`'s `#available(macOS 26, *)` gates to match
      what you find — the current scaffold has no Metal-4-only calls yet,
      so this is about confirming the plan before Phase 1 adds any
- [ ] Test on a real Sequoia machine (you have one) before assuming a Tahoe
      API is actually available there

## Exit
All boxes above checked = Phase 0 done, move to Phase 1 (DESIGN.md §14):
highlight reconstruction, sigmoid tone mapping, the real stage cache,
viewport-resolution rendering.
