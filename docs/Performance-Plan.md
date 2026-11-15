# Latent speed-up plan

Built on the measurements in [Performance-Profile.md](Performance-Profile.md) (main `62625ef`, November 2026). Every "problem" number below was measured; every "expected gain" is the measuring agent's estimate until someone re-runs the measurement.

## Rules every fix must follow

| Constraint | What it means for this plan |
|---|---|
| **Golden images must not change** | Run `swift test --filter GoldenImageTests` (and the DNG/LibRaw pixel round-trip tests) after every fix. A fix that changes export pixels is either redesigned or dropped. Fixes that only change the *drag preview* (what you see while a slider moves) are allowed, because goldens and export use the full render |
| **EditStack: no schema bump** | No fix here adds fields to the edit stack. The thumbnail cache key version is a separate cache key, not the EditStack |
| **Swift 6.1 CI** | No Swift 6.2-only features (for example `@concurrent` or default-MainActor build settings). `@Observable` (macOS 14+) and plain actors are fine |
| **No downloads without approval** | Installing the Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`) is a download. It stays parked until Harman says yes |
| **No Apple developer account** | Nothing here needs signing beyond today's ad-hoc signing |
| **16 GB machine** | Every new cache has a size cap and is dropped on memory pressure or photo change. Export runs at most 2 workers, capped by megapixels |

## How the fixes are ranked

Score = user-visible gain divided by (effort + risk). Effort: **S** = an afternoon, **M** = a few days, **L** = a week or more. "Who sees it" says how often the user feels it.

## Ranked overview

| # | Fix | Problem (measured) | Expected gain | Effort | Risk | Phase |
|---|---|---|---|---|---|---|
| 1 | Hash imports with `read()` instead of mmap, 2-4 files at once | Cold import hashing at 583 MB/s on a 2.6 GB/s SSD; 2,000 raws take 104 s | 2,000 cold: about 104 s to 25-30 s | S | Low | 1 |
| 2 | Memoise the lens-profile list | `LensCorrectionsPanel.body` = 14.9% of main when open (about 7-8 ms per tick) | 7-8 ms per tick with the panel open | S | Low | 1 |
| 3 | Cheaper backdrop preview at 100% zoom | Heavy 100% tick 51.2 ms, of which 21.8 ms renders a preview the tile hides | 51 to about 30 ms (19 to 33 fps) | S | Low | 1 |
| 4 | Drag preview at displayed size on retina | Heavy preview binned-1 22.3 ms vs binned-2 5.2 ms | Heavy fit tick about 24 to 7 ms | S | Low | 1 |
| 5 | Cache the denoise result | Denoise re-runs every tick: 4.66 ms of a 6.95 ms render | About 5 ms per tick when NR is on | S | Low | 1 |
| 6 | Remove the second SwiftUI pass per tick | 4 main views evaluate exactly 2x per tick | 5-9 ms per tick (plausible, not proven) | S | Low | 1 |
| 7 | Start the decode while the edit stack is read | Decode waits 45-60 ms for the edit stack read | 45-60 ms off every switch | S | Low | 1 |
| 8 | Drop the duplicate render in `open(url:)` | Second render 6.3 ms (13.1 worst) on nearly every open | 5-13 ms per switch | S | Low | 1 |
| 9 | Launch: don't park the open behind the GPU-attach task; warm Lensfun earlier | First photo waits about 230 ms after the window | Warm launch to first photo 0.9 to about 0.65 s | S | Low | 1 |
| 10 | Skip the 400 ms HQ wait right after an open | Selection to sharp 866 ms (Loupe) | Sharp about 400 ms sooner | S | Low | 1 |
| 11 | Faster no-change folder refresh | Refresh of 2,000: 215 ms, scan 179 ms | About 60-80 ms | S | Low | 1 |
| 12 | Subsampled JPEG decode for thumbnails | Full 6000x4000 decode for a 512 px thumb (11.6-14.3 ms) | 6-8 ms per thumbnail | S | Low | 1 |
| 13 | Higher priority for paste-triggered thumbnails | Paste to 100: 9.2 s at 4 workers | About 2x | S | Low | 1 |
| 14 | Fix: file argument at launch opens no window | `Latent file.NEF` shows no window for 40 s+ | Bug fix, no timing change | S | Low | 1 |
| 15 | Develop rendering off the main thread, latest-wins | Main waits for the GPU on every tick (3-65 ms) | Main busy per tick under 1 ms of encode | L | Med | 2 |
| 16 | Split what SwiftUI observes in EditorModel | 15.3 ms of SwiftUI per change even when nothing renders; 18.9 of 22.2 ms per tick | Tick about 22 to under 16.7 ms *(estimate)*; status changes nearly free | L | Med | 2 |
| 17 | Decode off main + prefetch neighbours | Main frozen 290-312 ms per photo switch | No freeze; adjacent switch about 345-400 to 30-60 ms | M | Med | 2 |
| 18 | Loupe: show embedded JPEG first | Loupe first image 346 ms | About 60-100 ms | M | Med | 2 |
| 19 | Pipeline the export queue (2 workers) | GPU idle 87-95% during export; 2 processes are 1.7-2x faster | Full JPEG about 110 to 190-230 per minute | M | Med | 2 |
| 20 | HQ preview: keep the full-res pool, render off main | 92 ms base / 209 ms heavy on main | Base about 15 ms, heavy about 110 ms, none on main | M | Med | 2 |
| 21 | Read EXIF extras in the LibRaw pass | Second ImageIO open: 3.1 ms per file, 6.1 s of a 12.7 s warm import | Warm 2,000 import 12.7 to about 6.6 s | M | Low | 2 |
| 22 | One-pass, parallel import | Cold 2,000: metadata pass re-reads every file (5.8 s) | With #1: cold heads to the disk limit (about 18 s) | M | Med | 2 |
| 23 | Equatable slider rows | 149 view bodies per tick with groups open; 52 ms tick | Most of the 34 ms gap between collapsed and expanded | M | Med | 2 |
| 24 | Per-purpose GPU command queues | Thumbnails, HQ and export share one queue with Develop (contention not measured) | Develop not stuck behind background GPU work | M | Med | 2 |
| 25 | Lower-resolution presence / local-detail blurs during drags | Presence 7 ms, local detail 9 ms per tick | Up to about 10 ms per tick | M | Med | 2 |
| 26 | "Selected Mask Only" scopes on the GPU | 9.7 ms on main every 100 ms | About 9 ms | M | Low | 2 |
| 27 | Brush re-raster off main or on the GPU | 5.8 ms CPU per undo/feather change | About 6 ms+ per such tick | M | Low | 2 |
| 28 | Edited thumbnails from the live session | 268 ms decode per edited thumbnail | About 250 ms each after a settled edit | M | Low | 2 |
| 29 | Reuse the embedded preview from import for thumbnails | 2.1 GB of previews cross XPC twice per 2,000 | 1.1 s warm / 5.8 s cold per 2,000 | M | Low | 2 |
| 30 | Combined PDF with JPEG-backed pages | `add()` 400-680 ms per page; 18 MB pages | 0.4-0.6 s per photo; files 4-6x smaller | S | Med (lossy) | 2 |
| 31 | Thumbnail cache format (JPEG or reused encoder) | HEIC encode 19-27 ms per thumb | About 2x thumbnail throughput (with #12) | S | Med | 2 |
| 32 | Mode switch: keep both views alive | Library/Develop switch 134-154 ms, 54-56 ms freezes | Freeze under 16 ms *(estimate)* | M | Med | 2 |
| 33 | AI Denoise: bigger tiles, faster pack/unpack, re-test the Neural Engine | 14.5 s per photo; Neural Engine run took 10.0 s | 30-50% | M | Med | 3 |
| 34 | DNG write: colour conversion on the GPU | Writer 190-245 ms per DNG | About 150 ms per DNG | M | Med | 3 |
| 35 | Half-res proxy cache | Decode is 50-85% of export, thumbnails, contact sheets | Paste-100 thumbnails 9 s to 1-2 s | L | Med | 3 |
| 36 | White balance without re-demosaic | WB tick at 100% 14.8 ms (vs 4.8 exposure) | 14.8 to about 5 ms | M | **High (goldens)** | 3 |
| 37 | Ship a precompiled metallib | Cold shader compile 0.9-2.3 s once per update | First launch after update 1.4-2.3 to about 0.65 s | S once approved | Needs download | 3 |
| 38 | Smaller binary start | First launch after install: about 1 s before our code runs | Perhaps 200-500 ms *(uncertain)* | L | Med | 3 |
| 39 | Reuse one RenderPipeline across an export batch | 35 ms per photo between GPU end and wait return (cause unconfirmed) | Up to 35 ms per photo | S | Low | 3 (measure first) |
| 40 | Pre-warm lazy pipelines and export/sharpen pipelines | First LMMSE tile +15 ms; first export sharpen +200 ms; first export render +108 ms | 0.3-0.5 s off the first export | S | Low | 3 (evidence conflicts) |

## Phase 1: quick wins (S effort, low risk)

Do these first, one per branch, in this order. Each is small enough to review in one sitting.

| # | Problem (measured) | The change, in plain terms | Files | Expected gain | Risk | How to verify |
|---|---|---|---|---|---|---|
| 1 | Import hashes files by memory-mapping them, which reads at 583 MB/s. Cold 200 NEF import 10.2 s (9.3 s hashing); 2,000 cold 104 s | Read each file in 4-8 MB chunks with `read()` into one reused buffer (the code already exists in `FileIntegrity.uncachedXXH64`, minus `F_NOCACHE`) and hash 2-4 files at once | `Sources/Catalog/FileHash.swift`, `Reconcile.swift`, `FileIntegrity.swift` | 200 cold: 10.2 to about 3 s. 2,000 cold: about 104 to 25-30 s | Low. Hash values must stay identical (existing catalogs depend on them) | `latent-cli perf-library reconcile` on a cold clone folder; catalog tests; compare hashes before and after on the same files |
| 2 | The lens-profile picker filters, de-duplicates and sorts the whole lensfun database twice on every redraw: 14.9% of main with groups open | Work out the list once per camera and keep it; precompute lowercase sort keys once | `Sources/LensKit/LensProfileOverrides.swift`, `Sources/latent-app/DetailPanels.swift` | About 7-8 ms per tick whenever Lens Corrections is open | Low. Clear the memo if the lens database reloads or a user profile is added | UI soak `LATENT_PERF_UI_SOAK=expanded` + `sample`; LensKit tests |
| 3 | At 100% zoom every tick also renders the full 3016x2016 preview behind the tile: 21.8 of 51.2 ms (heavy), 3.2 of 14.8 ms (base WB) | While the tile covers the view, render that backdrop at a coarse size (or reuse the analysis render) during the drag; refresh it when the drag ends | `Sources/latent-app/EditorModel+Rendering.swift`, `SecondaryDisplay.swift` | Heavy 100% tick 51 to about 30 ms; 2-3 ms on base edits | Low. Edges may look soft for a moment during fast pans; the second display needs its own size | `EditorTickPerfTests/testHeavyEditTicks`; UI run at 100%; goldens unchanged (preview only) |
| 4 | A retina "fit" view renders the preview at 3016x2016 (6 MP); heavy stages scale with pixels: 22.3 ms vs 5.2 ms at half size | During a drag, render at about the displayed size; render full size when the drag settles (the HQ preview follows anyway) | `EditorModel+Rendering.swift`, `SecondaryDisplay.swift` | Heavy fit tick about 24 to 7 ms (40 to 140 fps) | Low. Slightly softer while dragging | `EditorTickPerfTests`; snapshot harness to check the settled image is sharp; goldens unchanged |
| 5 | Noise reduction re-runs on every tick, even exposure: 4.66 ms of 6.95 ms. The heal cache only stores results when heal patches exist | Cache the denoised camera-RGB under the heal cache key even without patches | `Sources/PixelEngine/RenderPipeline.swift`, `ImageSession.swift` | About 5 ms per preview tick and 4 ms per tile tick with NR on | Low. About 50-100 MB more per cached size; must be dropped with the other caches | `RenderStagePerfTests` (denoise row); `GoldenImageTests` must be identical |
| 6 | `ImageViewport`, `DevelopImageArea`, `LibraryPanel` and `DescriptiveMetadataSection` each redraw exactly twice per tick: the model publishes over two run-loop turns | Find the second-turn publisher (likely scopes, status/renderReport or a deferred flag), move it into the same turn, and skip assignments that don't change the value | `EditorModel+Rendering.swift`, `EditorModel.swift` | Up to about half the SwiftUI cost: 5-9 ms per tick *(plausible, not proven)* | Low | UI run (`PERFUI` body counts should drop to 1 per tick) |
| 7 | Switching waits 45-60 ms reading the edit stack before the 235 ms decode starts | Start the decode the moment the selection changes and read the edit stack at the same time; apply when both are done | `Sources/latent-app/ContentView.swift` | 45-60 ms off every switch | Low. Keep the "is this load still current" checks | `switch_runs.sh` |
| 8 | `open(url:)` renders twice (once from `parameters` didSet, once explicitly): extra 6.3 ms (13.1 worst) | Suppress the didSet render inside `open`, keep its other side effects (saving, mask hooks). At launch, give the drawable size before the first render | `EditorModel+Opening.swift`, `EditorModel+Rendering.swift` | 5-13 ms per switch; final-size preview about 170 ms earlier at launch | Low | `OpenPerformanceTests`; render count in the PERF log should be 1 |
| 9 | At launch the GPU context is ready by about 200 ms but the open waits until 601 ms behind a main-actor task; `ImageSession` blocks on Lensfun (142 ms) if it is not parsed yet | Use the already-built GPU context directly in `open`; start the Lensfun warm-up in `applicationWillFinishLaunching`; optionally start the raw decode at launch in parallel | `GPUContext.swift`, `EditorModel.swift`, `EditorModel+Opening.swift`, `ContentView.swift`, `Sources/LensKit/LensfunDatabase.swift` | Warm launch to first photo about 0.9 to 0.65 s (about 0.4 s if the decode overlaps) | Low | `launch_runs.sh warm 7` |
| 10 | HQ preview waits 400 ms after every change, including right after an open where nothing is being dragged. Selection to sharp 866 ms | No (or a short) settle delay after an open | `Sources/latent-app/EditorModel+HighQualityPreview.swift` | Sharp image about 400 ms sooner | Low | `switch_runs.sh` with `-latent.viewing.highQualityPreview YES` |
| 11 | Folder-watcher refresh of 2,000 files: 215 ms, scan 179 ms (about 90 µs per file: resource values, Finder-tag xattr, lstat) | Get tags from the directory enumerator instead of one xattr call per file; skip the lstat when not needed; reuse the first `fetchAll`; list the xmp folder once | `Sources/Catalog/Reconcile.swift`, `FinderTags.swift` | About 215 to 60-80 ms; about 1 s per event on a 10k folder *(estimate)* | Low. Finder-tag and dataless tests cover it | `latent-cli perf-library library <folder> --refreshes 25`; catalog tests |
| 12 | Thumbnails decode the full 6000x4000 embedded JPEG to make a 512 px image (11.6-14.3 ms) | Ask ImageIO for a subsampled decode (`kCGImageSourceSubsampleFactor`), which uses the JPEG's built-in 1/8 scale | `Sources/Catalog/Thumbnailer.swift` | About 6-8 ms per thumbnail | Low. Check thumbnails still look sharp at 512 px | `latent-cli perf-library thumbs --priority normal` |
| 13 | Paste Settings to 100 photos re-renders thumbnails in 9.2 s at 4 workers | Run paste-triggered passes at High priority (8 workers) and render visible cells first | `Sources/Catalog/Library.swift`, `Thumbnails.swift` | About 2x | Low. More heat and memory while it runs; watch RAM on 16 GB | `latent-cli perf-batch sync <folder>` |
| 14 | Launching with a file (`Latent file.NEF`, Finder "Open With") shows no window at all | Handle `application(_:open:)` in the app delegate: show the main window and route the file through `LaunchArguments` | `Sources/latent-app/LatentApp.swift`, `Sources/Catalog/LaunchArguments.swift` | Restores opening from the command line and Finder | Low | Launch with a file; `LaunchArgumentsTests` |

**Expected effect of Phase 1 together** *(estimates)*: heavy-edit drag at fit about 24 to under 10 ms render; 100% heavy drag about 51 to about 30 ms; every photo switch 50-70 ms shorter; launch about 0.25 s faster; cold import about 3-4x faster; thumbnails faster. It does **not** fix the two biggest feelings (the freeze when opening a photo, and SwiftUI cost per tick); those are Phase 2.

## Phase 2: structural

Bigger changes. Each needs its own plan, tests first, and the snapshot harness to catch lost UI updates.

| # | Problem (measured) | The change, in plain terms | Files | Expected gain | Risk | How to verify |
|---|---|---|---|---|---|---|
| 15 | Every render runs on the main thread and waits for the GPU (`waitUntilCompleted`): main is blocked 3-65 ms per tick | Send the render to the GPU without waiting; show it when the GPU says it is done. Keep one render in flight and drop in-between ticks (latest wins). Or a render actor with the same rule | `Sources/PixelEngine/RenderPipeline.swift`, `Sources/latent-app/EditorModel+Rendering.swift` | Main busy per tick under 1 ms of encoding; the UI stays responsive. Frame rate is still limited by the GPU (about 40 fps heavy) | Medium. Textures must not be reused while the GPU still reads them (double-buffer); scopes and tests expect synchronous results | `EditorTickPerfTests`, UI run; goldens identical (the export path is untouched) |
| 16 | `ContentView` and about 79 views observe the whole `EditorModel`: any change redraws the window. Status-only change 15.3 ms; 18.9 of 22.2 ms per tick is SwiftUI | Move `EditorModel` to `@Observable` (tracks each property) or split hot state (parameters, preview/tile, scopes, status) into small objects; pass panels only what they need; move LibraryPanel and the status bar out of the model-observing body | `ContentView.swift`, `EditorModel.swift` (+ about 46 view files) | Non-render time per tick about 19 to 3-6 ms *(estimate)*; default ticks fit 60 fps | Medium. Wide refactor; an update that relied on whole-model redraw can go missing. `@Observable` is Swift 6.1-compatible | UI run + soak `status`; snapshot harness |
| 17 | The raw decode runs on the main thread: 290 ms (Loupe) / 312 ms (Develop) frozen per switch; 222-262 ms of it is LibRaw | Decode and build the session in a background task (`RawDecoderClient` is already thread-safe), apply on main; cancel stale loads when an arrow key is held; prefetch the previous and next photo (2-3 kept, about 50 MB each) | `EditorModel+Opening.swift`, `ContentView.swift`, `Sources/RawCore/RawFile.swift`, `RawDecoderXPC.swift` | No freeze per switch; with prefetch, adjacent switch about 345-400 to 30-60 ms | Medium. `open` sets a lot of state at once (history, masks, tools, AI and touch-up regeneration); a stale result must never overwrite a newer one | `switch_runs.sh`; `OpenPerformanceTests`; harness rapid "next" steps |
| 18 | Loupe waits for decode and render (346 ms) although every NEF holds a full-size JPEG (41.7 ms to decode) | In Loupe show the embedded JPEG (or the cached thumbnail) at once, then swap in the real render; for unedited photos at fit, maybe skip the decode | `ContentView.swift`, `ImageViewport.swift`, `RawFile.swift` | First image about 60-100 ms | Medium. The camera JPEG looks different from Latent's render, so the image visibly changes; orientation and crop must match | `switch_runs.sh` (Loupe rows) |
| 19 | Export does one photo at a time; the GPU is idle 87-95% of it. Two processes finished 10 photos 1.7-2x faster | Overlap: decode photo N+1 while N renders, encode N while N+1 renders; or 2 workers capped by megapixels | `Sources/latent-app/ExportQueue.swift`, `Sources/MLKit/ExportWorker.swift` | Full JPEG about 110 to 190-230 per minute; 2048 px about 160 to 300; PNG about 3x | Medium. About 0.5 GB more RAM per photo in flight: cap at 2 on 16 GB and for very large files | `scripts/perf-export/runall.sh` and `run4.sh`; export output tests and goldens byte-identical |
| 20 | HQ preview throws away the full-res demosaic and reallocates every time: 92 ms base, 209 ms heavy, on main (73 ms with the pool released vs 9.7 kept; resample 22 ms) | Keep the full-res camera-RGB and buffers while the photo is open (drop on photo change or memory pressure); keep the resample buffers; render off main with its own pool | `Sources/PixelEngine/HighQualityPreview.swift`, `ExportResampler.swift`, `EditorModel+HighQualityPreview.swift` | Base about 15 ms, heavy about 110 ms, and not on main | Medium. 200-400 MB GPU memory held per open photo: must be released under pressure | `EditorTickPerfTests` HQ rows; UI "settle" row |
| 21 | Import opens every raw a second time with ImageIO for EXIF extras: 3.1 ms per file, 6.1 of 12.7 s warm | Read GPS, flash, exposure bias, metering and WB mode in the LibRaw metadata call (or the XPC reply); keep ImageIO for non-raw files and as fallback | `Sources/Catalog/ExifExtras.swift`, `Reconcile.swift`, `Sources/RawCore/RawFile.swift`, `RawDecoderService.swift` | Warm 2,000 import 12.7 to about 6.6 s; about 6 s cold | Low. LibRaw may lack some fields for some makes | `perf-library reconcile`; catalog tests compare extracted fields |
| 22 | Import hashes every file, then reads metadata for every file, one at a time; on big folders the second pass re-reads from disk | Handle each new file once in a bounded group of 4-8: read, hash, metadata; plan renames after all hashes are in; write rows in one transaction | `Sources/Catalog/Reconcile.swift` | With #1: cold 2,000 toward about 18 s (disk limit); warm about 6.6 to 2 s *(estimates)* | Medium | `perf-library reconcile` cold and warm; `ReconcileEdgeTests` |
| 23 | With groups open, 149 view bodies per tick; `ResettableSlider` 39x | Slider rows compare their value/range/format and skip redraws when unchanged (`.equatable()`); consider a lazy stack | `ContentView.swift`, `DetailPanels.swift` | Most of the 34 ms between collapsed and expanded | Medium. Can hide needed updates (enabled state, WB ranges) | UI run `expanded`; snapshot harness |
| 24 | Develop, thumbnails, HQ preview and export share one `MTLCommandQueue` (contention not measured) | Separate queues for interactive, HQ and background work | `Sources/PixelEngine/GPUContext.swift`, `RenderPipeline.swift` | Develop no longer waits behind background GPU work | Medium. Measure contention first (not done yet) | Tick test while an export runs (new measurement) |
| 25 | Presence (7 ms) and local detail (9 ms) recompute their blurs every tick | During drags, compute the blurs at lower resolution; full quality on settle and export | `RenderPipeline.swift`, `Sources/PixelEngine/LocalDetailStage.swift` | Up to about 10 ms per tick | Medium. Export and goldens must stay on the full path | `RenderStagePerfTests`; goldens identical |
| 26 | "Selected Mask Only" histogram: 9.7 ms on main every 100 ms | Weighted accumulate on the GPU with a mask texture, or off main | `Sources/latent-app/EditorModel+MaskedScopes.swift` | About 9 ms | Low | `EditorTickPerfTests` masked-scope row |
| 27 | Replacing a brush stroke list re-rasterizes on the CPU inside the render: 5.8 ms | Rasterize on the GPU or off main | `Sources/PixelEngine/LocalAdjustments.swift`, `ImageSession.swift` | About 6 ms+ per undo/feather tick | Low | `RenderStagePerfTests` brush row; goldens |
| 28 | Edited thumbnails decode the raw again: 310 ms each | Render the thumbnail from the open session when there is one | `Sources/latent-app/EditedThumbnailRenderer.swift`, `Sources/Catalog/Thumbnails.swift` | About 250 ms per edited thumbnail | Low | `perf-library thumbs --edited` |
| 29 | The thumbnail pass reads metadata over XPC again, moving 2.1 GB of previews a second time per 2,000 | Hand the preview from import straight to the thumbnailer (streamed, not all held) | `Thumbnailer.swift`, `Reconcile.swift`, `RawDecoderService.swift` | 1.1 s warm / 5.8 s cold per 2,000 | Low. Must not hold 2 GB in memory | `perf-library reconcile` then `thumbs` |
| 30 | Combined PDF stores each page losslessly: 400-680 ms and about 18 MB per page | Use the existing `ContactSheetWriter.jpegBacked` path, off the render thread, with a quality option | `Sources/PixelEngine/ExportPDF+Combined.swift`, `Sources/latent-app/ContactSheetWriter.swift` | 0.4-0.6 s per photo; files 4-6x smaller | Medium. Lossy; keep a lossless choice | `run3.sh` (pdf) |
| 31 | HEIC thumbnail encode costs 19-27 ms, more than the decode | JPEG (or a reused encoder) for the thumbnail cache | `Thumbnailer.swift`, `ThumbnailLoader.swift` | About 2x thumbnail throughput with #12 | Medium. New cache key version, one-time rebuild | `perf-library thumbs` at all priorities |
| 32 | Library/Develop switch rebuilds big view trees: 54-56 ms freezes | Keep both subtrees alive (hidden), cache `metadataRows` | `ContentView.swift` | Freeze under 16 ms *(estimate)* | Medium. More memory | UI soak `modes` |

## Phase 3: longer term or blocked

| # | Problem (measured) | The change | Files | Expected gain | Risk / blocker | How to verify |
|---|---|---|---|---|---|---|
| 33 | AI Denoise 14.5 s per photo (486 tiles, 31% overlap); Neural Engine allowed: 10.0 s | 512 px tiles, vDSP/GPU pack and unpack, more in flight; re-test the Neural Engine (it hung in the past) | `Sources/MLKit/AIDenoiser.swift`, `CoreMLStore.swift` | 30-50% | Medium. Bigger tiles may shift seams; Neural Engine hang history | `LATENT_PERF_EDIT=denoise` export run |
| 34 | DNG writer 190-245 ms of a 650 ms DNG export | Apply the camera matrix on the GPU before readback; compress tiles in parallel | `Sources/MergeKit/DNG/RenderedDNGExport.swift` | About 150 ms per DNG | Medium. DNG round-trip tests must still match | `run3.sh` (dng); DNG pixel tests |
| 35 | Decode is 50-85% of export, contact sheets, thumbnails | Half-res linear proxy cache on disk | `RawFile.swift`, `EditedThumbnailRenderer.swift`, `Thumbnails.swift` | Paste-100 thumbnails 9 s to 1-2 s; small exports 2-4x | Medium. Invalidation and disk space; full-size export must still use the raw | `perf-batch sync`; export goldens |
| 36 | WB drags miss the demosaic cache: 14.8 ms vs 4.8 ms at 100% | Demosaic without WB multipliers and apply WB in the colour kernel | `RenderPipeline.swift`, `ToneEqualizerStage.swift` | 14.8 to about 5 ms | **High: RCD/LMMSE depend on channel balance, so export pixels will likely shift. Blocked by the goldens rule** unless done for the drag preview only | `GoldenImageTests` must be identical |
| 37 | Cold shader compile 0.9-2.3 s, paid once per update | Install the Metal toolchain so `make_app.sh` ships `default.metallib`, then re-measure (pipeline creation may become the cost) | `scripts/make_app.sh`, `GPUContext.swift` | First launch after update 1.4-2.3 to about 0.65 s | **Needs Harman's approval (download)** | `launch_runs.sh cold` |
| 38 | First launch after install: about 1 s before `main` runs | Dead-strip, move rarely used code into lazily loaded frameworks, check static initialisers | `Package.swift`, `scripts/make_app.sh` | Perhaps 200-500 ms *(uncertain)* | Medium; once per update only | First-run launch timing |
| 39 | About 35 ms per photo between GPU end and wait return during export (cause unconfirmed) | Reuse one RenderPipeline/texture pool across a batch | `ExportWorker.swift`, `RenderPipeline.swift` | Up to 35 ms per photo | Low; gain may not appear | `runall.sh`: compare render wall vs GPU |
| 40 | First LMMSE tile 24 vs 9.6 ms; first export sharpen +200 ms; first export render +108 ms | Build the lazy pipelines in the background after launch or when the export sheet opens | `GPUContext.swift`, `Sources/MLKit/AIMasks.swift` | 0.3-0.5 s off the first export; maybe 15 ms one-time | Low. **Evidence conflicts**: the open agent timed all 54 lazy pipelines at 1.45 ms. Measure which part is really pipeline creation first | `GPUStartupPerfTests`; first-photo rows in `runall.sh` |

## How to measure again

Each measuring branch lives in its own worktree. Heavy commands go through `/Users/harman/latent-wt/with-slot.sh` (limits parallel builds; the Mac swaps with more than 2) and `/Users/harman/latent-wt/bin/measure-lock.sh` (one measurement at a time). Wait for a quiet machine (load under 4) before trusting numbers, and compare medians, not single runs.

**Golden check after every fix (from `/Users/harman/latent`):**

```
swift test --filter 'GoldenImageTests|DNGPixelTests|LibRawPixelRoundTripTests'
```

### Render and slider ticks (`/Users/harman/latent-wt/render`, branch `perf/render`)

```
cd /Users/harman/latent-wt/render
/Users/harman/latent-wt/with-slot.sh swift build -c release -j 4 -Xswiftc -enable-testing --build-tests
scripts/perf/run-render-perf.sh RenderStagePerfTests out-stages.txt
scripts/perf/run-render-perf.sh EditorTickPerfTests out-ticks.txt
# or just the heavy edit: scripts/perf/run-render-perf.sh EditorTickPerfTests/testHeavyEditTicks out.txt
```

Lines start with `PERFROW` (per stage: GPU ms `g` / CPU encode ms `c`) or `PERFTICK` (tick wall, then each render: #0 preview, #1 analysis, #2 tile or masked scope). `LATENT_PERF_FILE=<name in TestAssets>` picks another raw. The script waits for load under 4 and takes the lock.

### Launch and photo switching (`/Users/harman/latent-wt/open`, branch `perf/open`)

```
cd /Users/harman/latent-wt/open
/Users/harman/latent-wt/with-slot.sh swift build -c release -j 4 --product latent-app -Xswiftc -DDEBUG
/Users/harman/latent-wt/with-slot.sh swift build -c release -j 4 --product latent-rawdecoder -Xswiftc -DDEBUG
scripts/perf/make_perf_app.sh
# once: defaults write com.latent.app.perfopen latent.welcomeSeen -bool YES

# launch -> first photo ('cold' instead of 'warm' salts the shaders; LATENT_RAW_INPROCESS=1 for in-process decode)
scripts/perf/quiet.sh 300 /Users/harman/latent-wt/bin/measure-lock.sh scripts/perf/launch_runs.sh <logdir> warm 7 <dir>/single/HSB_6548.NEF
python3 scripts/perf/summarise_launch.py warm <logdir>/warm-{2..7}.err

# switching in Loupe and Develop (add -latent.viewing.highQualityPreview YES after the folder for HQ)
scripts/perf/quiet.sh 300 /Users/harman/latent-wt/bin/measure-lock.sh scripts/perf/switch_runs.sh <logdir>/sw-xpc-1.err <dir>/sw
python3 scripts/perf/summarise_switch.py <logdir>/sw-*.err

# tests
/Users/harman/latent-wt/with-slot.sh swift build -c release -j 4 --scratch-path .build-perftest -Xswiftc -DDEBUG -Xswiftc -enable-testing --build-tests
scripts/perf/quiet.sh 300 /Users/harman/latent-wt/bin/measure-lock.sh env LATENT_PERF=1 swift test -c release --scratch-path .build-perftest -Xswiftc -DDEBUG -Xswiftc -enable-testing --skip-build --filter 'GPUStartupPerfTests|OpenPerformanceTests|CatalogOpenPerfTests|LensfunParsePerfTests' | grep -E 'PERFROW|PERFINFO'
```

The bundle id is `com.latent.app.perfopen`, so the real app's settings and shader cache are untouched. Switches: `LATENT_PERF=1`, `LATENT_PERF_OPEN_FILE=<raw>`, `LATENT_PERF_EXIT_AFTER_PRESENT_MS=<ms>`, `LATENT_PERF_SHADER_SALT=<any>`. The `single` (4 NEFs) and `sw` (12 hard-linked NEFs) folders are under `/private/tmp/claude-501/-Users-harman-Anthropic-sandbox/d01ac1f3-dc26-47b9-874e-003abad8eab0/scratchpad/perf-open/` (scratchpad: may be cleared by a reboot).

### Library, import, thumbnails (`/Users/harman/latent-wt/library`, branch `perf/library`)

```
cd /Users/harman/latent-wt/library
/Users/harman/latent-wt/with-slot.sh swift build -c release -j 4 --product latent-cli
/Users/harman/latent-wt/with-slot.sh swift build -c release -j 4 --product latent-rawdecoder
# assemble LibPerf.app as scripts/perf-library/README.txt describes (latent-cli + LatentRawDecoder.xpc, ad-hoc signed)
LATENT_PERF=1 /Users/harman/latent-wt/bin/measure-lock.sh <LibPerf.app>/Contents/MacOS/latent-cli perf-library reconcile <folder>
#   other modes: library <folder> [--refreshes N] | thumbs <folder> [--priority low|normal|high] [--edited --limit N]
#                thumbload <folder> | verify <folder> | dupes <folder> [--scale N]
```

Warm folders: hard links. Cold folders: `cp -c` APFS clones (new files, no extra disk space). Runner scripts: `scripts/perf-library/import.sh`, `phase2.sh`, `phase3.sh` (edit the `S=` / `W=` line first). Release PERF suites:

```
/Users/harman/latent-wt/with-slot.sh swift build -c release -j 4 --scratch-path .build-perftest --build-tests -Xswiftc -enable-testing -Xswiftc -DDEBUG
LATENT_PERF=1 swift test -c release --scratch-path .build-perftest --skip-build -Xswiftc -enable-testing -Xswiftc -DDEBUG --filter "LargeFolderPerformanceTests|LargeFolderGridPerformanceTests|LibraryPerformanceTests"
```

### Export (`/Users/harman/latent-wt/export`, branch `perf/export`)

```
cd /Users/harman/latent-wt/export
/Users/harman/latent-wt/with-slot.sh swift build -c release -j 4 --product latent-cli
# folders of hard-linked NEFs under $PERF_SCRATCH (default /tmp/latent-perf-export): ten/, one/, three/, hundred/, split2a-b, split3a-c
# copy scripts/perf-export/sharpen*.json there
/Users/harman/latent-wt/bin/measure-lock.sh scripts/perf-export/runall.sh   # all formats, Subject mask, denoise
/Users/harman/latent-wt/bin/measure-lock.sh scripts/perf-export/run3.sh     # XPC, DNG, PDF, sheet, print, sync
/Users/harman/latent-wt/bin/measure-lock.sh scripts/perf-export/run4.sh     # 1/2/3-process throughput
python3 scripts/perf-export/parse.py $PERF_SCRATCH/logs/*.log
# single run:
LATENT_PERF=1 .build/release/latent-cli export <folder> --out-dir <dir> --on-conflict replace [--format jpeg|heic|tiff|png] [--long-edge 2048] [--preset sharpen.json]
```

`LATENT_PERF_EDIT=subject` or `denoise` adds a Subject mask or AI Denoise; `LATENT_ML_COMPUTE=all` allows the Neural Engine. `run2.sh` covers cold model loads and cold processes.

### UI and main thread (`/Users/harman/latent-wt/ui`, branch `perf/ui`)

```
cd /Users/harman/latent-wt/ui
/Users/harman/latent-wt/with-slot.sh swift build -c release -j 4 --product latent-app
LATENT_PERF_UI=1 LATENT_PERF_UI_FOLDER=<folder of 8 hard-linked NEFs> /Users/harman/latent-wt/bin/measure-lock.sh .build/release/latent-app 2> out.err
grep PERFUI out.err
# profiling soak: LATENT_PERF_UI_SOAK=default|expanded|collapsed|status|export|modes (loops 14 s after 'SOAK START pid=N')
sample <pid> 10 1 -file s.txt
```

### Which measurement proves which fix

| Fix | Re-run |
|---|---|
| 1, 21, 22 | `perf-library reconcile` cold (clones) and warm (hard links) |
| 2, 6, 16, 23, 32 | UI run (`PERFUI`), soak `expanded` / `status` / `modes` + `sample` |
| 3, 4, 5, 15, 25, 26, 27 | `RenderStagePerfTests`, `EditorTickPerfTests` (+ UI run for 15) |
| 7, 8, 10, 17, 18 | `switch_runs.sh` (+ HQ flag for 10); `OpenPerformanceTests` |
| 9, 37, 38, 40 | `launch_runs.sh warm` / `cold`; `GPUStartupPerfTests` |
| 11 | `perf-library library --refreshes 25` |
| 12, 13, 28, 29, 31, 35 | `perf-library thumbs`, `perf-batch sync` |
| 19, 30, 33, 34, 39 | `scripts/perf-export/runall.sh`, `run3.sh`, `run4.sh` |
| 20 | `EditorTickPerfTests` HQ rows; UI settle row |
| All | `swift test --filter 'GoldenImageTests|DNGPixelTests|LibRawPixelRoundTripTests'` must pass unchanged |
