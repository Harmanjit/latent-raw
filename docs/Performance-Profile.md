# Latent performance profile: what takes how long

Measured November 2026 on `main` at `62625ef`, by five measuring agents (render, open, library, export, UI), each in its own worktree and branch (`perf/render`, `perf/open`, `perf/library`, `perf/export`, `perf/ui`). None of those branches is merged. Only numbers the agents measured appear here. Estimates are marked *(estimate)*.

The speed-up plan built on these numbers is in [Performance-Plan.md](Performance-Plan.md).

## 1. Machine and method

| Item | Value |
|---|---|
| Machine | Mac16,13 (MacBook Air), Apple M4, 16 GB RAM, internal SSD (about 2.55 GB/s read serially, 3.16 GB/s with 4 files in parallel) |
| OS | macOS 27 (Darwin 27.2) |
| Build | `swift build -c release -j 4`. The app and the test runs also used `-Xswiftc -DDEBUG` (so the SnapshotHarness and `LATENT_RAW_INPROCESS` are compiled in) and, for tests, `-enable-testing`. Optimisation is the same as a real release, but debug-only code is present. The UI agent also ran a plain debug build for comparison |
| Test photos | Nikon D750 NEFs, 24 MP (6032x4032), about 27 MB each (HSB_6548, 6664, 2615, 2639 from TestAssets). Folders were made of hard links (data already in memory, "warm") or `cp -c` APFS clones (fresh files, read from the SSD, "cold") |
| Shaders | No `default.metallib` ships: the Metal toolchain is not installed, so the app compiles its shaders from source at start-up (Metal caches the result) |
| Samples | 2 to 2,000 per row; most rows 5-9. Each row gives the **median** (the middle value: what you normally get) and the **worst** (the slowest sample) |
| Timers | Wall-clock time on the calling thread, plus GPU start/end timestamps where shown. UI rows use a run-loop busy monitor and `sample` profiles |

### Caveats: read these before trusting a number

- **Noise from other work.** Five agents shared one 16 GB machine. Runs waited for a load average under 4 and took a measuring lock, but some runs saw load 5-30. Rows taken under load are flagged, and rows that ran during load spikes were thrown away (a 30% spread between median and worst usually means load).
- **Engine time is not app time.** The render agent drove `EditorModel` without any views. The UI agent measured the real app window: the same slider tick costs about 3 ms of rendering but about 22 ms in total, because SwiftUI redraws most of the window. Both views are given below.
- **Warm disk.** Every raw read in the open and export tests came from the page cache. Purging it needs `sudo`, which was not used. A cold SSD or network drive will be slower. Cold import numbers used fresh APFS clones instead.
- **Synthetic large catalogs.** 10k-photo numbers come from synthetic test fixtures, not 10,000 real raws.
- **No real mouse.** Slider ticks were driven in code (what the slider's binding does), paced at 60 Hz. Real mouse event handling is not included.
- **Splitting a render into stages** (one command buffer per stage) adds about 0.1 ms of gaps. The app uses one buffer.

### Targets used for verdicts

| Target | Budget | Why |
|---|---|---|
| Smooth drag | 16.7 ms per tick | One frame at 60 fps |
| Instant | 100 ms | Feels immediate |
| Keeps flow | 1 s | The user notices the wait but keeps their train of thought |
| Background job | No hard limit, but compare with the disk or GPU limit | It should not lock the UI |

Verdicts: **OK** = within target, **Near** = within 1.5x, **Slow** = over 1.5x.

## 2. One-screen summary

| Operation (what the user does) | Time, median (worst) | What it blocks | Target | Verdict |
|---|---|---|---|---|
| Open photo: Library to Develop, new photo | 447 ms (511) in the app; main thread stuck in one go for 297 ms (332) | Main thread: whole UI frozen | 100 ms | **Slow** |
| Switch photo, Develop (next photo shown) | 402 ms (464); main blocked 312 ms (371) | Main thread | 100 ms | **Slow** |
| Switch photo, Loupe | 346 ms (485); main blocked 290 ms (416) | Main thread | 100 ms | **Slow** |
| Slider tick, default panel, fit, in the app | 22.2 ms (25.5): render 3.4 + SwiftUI/drawing 18.9. About 45 fps | Main thread | 16.7 ms | **Near** |
| Slider tick, all panel groups open, in the app | 52.0 ms (57.1). About 19 fps | Main thread | 16.7 ms | **Slow** |
| Slider tick, render only, base edit (engine) | 2.94 ms (4.65) | Main thread (waits for GPU) | 16.7 ms | OK |
| Slider tick, render only, heavy edit (masks, NR, presence, sharpen, effects) | 23.7 ms (27.7). About 42 fps | Main thread | 16.7 ms | **Near** |
| White-balance drag tick, render only, fit | 4.49 ms (6.23); heavy edit 28.6 ms (30.7) | Main thread | 16.7 ms | OK / **Near** |
| Slider tick at 100% zoom, in the app | 31.4 ms (35.9). About 31 fps | Main thread | 16.7 ms | **Slow** |
| White-balance tick at 100%, render only | 14.8 ms (15.3) base; 65.3 ms (66.2) heavy (about 15 fps) | Main thread | 16.7 ms | OK / **Slow** |
| Zoom to 100%: first tile render | 11.2 ms (11.9) RCD, 9.6 ms LMMSE, 3.7 ms bilinear. Whole zoom including UI not measured | Main thread | 100 ms | OK |
| High Quality Preview (sharp full-res render after an edit settles) | 92 ms (99) base, 209 ms (213) heavy, 118 ms in the app; starts 400 ms after the last change | Main thread | 100 ms | **Near** / **Slow** |
| Selection to sharp image (HQ preview on) | 866 ms (1010) Loupe; about 1053 ms Develop | Main thread for the 118 ms render | 1 s | **Near** |
| Launch to first photo drawn (warm) | 911 ms (919) | Main thread (critical path) | 1 s | **Near** |
| Launch to first photo, shaders not yet cached (first run after an update) | 1408 ms (1421); real cold compiles seen up to 2.3 s under load | Main thread waits | 1 s | **Slow** |
| Launch to window visible (warm) | 373 ms (384) | Main thread | 1 s | OK |
| Import 2,000 raws, cold disk | 104 s (114), 2 samples. 92-100 s of it is hashing | Background (status shows "Opening…") | Disk limit about 18 s *(estimate: 54 GB at 3.1 GB/s)* | **Slow** |
| Import 2,000 raws, warm (data in memory) | 12.7 s (12.9) | Background | n/a | Slow-ish |
| Thumbnails for 2,000 raws | Normal priority 16.8 s; High 10.5 s; Low 33.1 s (1 sample each) | Background | n/a | Slow-ish |
| Export 10 photos, full-size JPEG | 5.4-5.7 s per 10 (532 ms per photo, 105-111 per minute) | Background; GPU busy only 13% | n/a | OK, but could be about 2x faster |
| Export 10 photos, 2048 px JPEG | about 3.3 s per 10 *(estimate from 325 ms per photo)* | Background | n/a | OK |
| Filter / search keystroke, 10k photos | 23.0 ms (23.4) everything; 7.2 ms names only | Main thread | 100 ms | OK |
| Collection counts (9 collections), 10k photos | 129 ms (129) | Main thread | 100 ms | **Near** |

**Headline:** rendering is fast. The slow, user-visible things are (1) the raw decode running on the main thread at every photo open, (2) SwiftUI redrawing the whole window on every edit, and (3) background jobs (import hashing, export) that run one item at a time and leave the disk or GPU mostly idle.

## 3. Render stages (engine only, preview = 3016x2016 "binned-1", tile = 2816x1856 at 100%)

"WB miss" = a white-balance change, which forces the demosaic to re-run. "Exposure hit" = the cached demosaic is reused.

### 3.1 Whole renders

| Render | Condition | Median ms | Worst ms | Notes |
|---|---|---|---|---|
| Preview binned-2 (1504 px) | WB miss | 1.59 | 2.73 | Exposure hit 0.92 |
| Preview binned-1 (retina fit) | WB miss | 3.50 | 4.70 | |
| Preview binned-1 | Exposure hit | 2.27 | 2.99 | 1.29 with lens corrections off |
| Analysis render binned-4 (754x504) | Exposure hit | 0.33 | 0.45 | WB miss 0.93; heavy edit 1.66 |
| 100% tile, bilinear demosaic | WB miss | 3.68 | 4.90 | |
| 100% tile, RCD demosaic | WB miss | 11.24 | 11.88 | RCD itself 8.35 GPU |
| 100% tile, LMMSE demosaic | WB miss | 9.62 | 10.18 | LMMSE 7.05 GPU, faster than RCD |
| 100% tile, RCD | Exposure hit | 2.17 | 3.17 | |
| All stages, preview binned-1 | Exposure hit | 22.25 | 22.96 | See 3.3 |
| All stages, preview binned-1 | WB miss | 25.25 | 26.18 | |
| All stages, tile | Exposure hit / WB miss | 20.13 / 33.6 | 33.84 | |
| All stages, preview binned-2 | Exposure hit | 5.15 | 6.82 | 4.3x cheaper than binned-1 |
| Full res 6032x4032, RCD (export size) | WB miss | 45.3 | 46.2 | RCD 36.4 GPU |

### 3.2 Individual stages (GPU time)

| Stage | Preview binned-1 ms | Tile ms | Full res ms | Notes |
|---|---|---|---|---|
| Lens corrections (profile) | 0.98 | 0.86 | 3.9-4.1 | 0.26 at binned-2. Costs as much as the colour kernel |
| Colour and tone, 0 masks | 0.97 | similar | | |
| ... 1 radial / 1 brush / 4 / 8 masks | 1.37 / 1.59 / 3.13 / 5.41 | within 10% | | Whole render 2.66 / 2.90 / 4.61 / 6.90 |
| Brush mask full re-raster (CPU) | 5.76 (27.6 under load) | | | Only when the stroke list is replaced (undo, feather). Painting by appending costs about 0 |
| Local detail (radial with clarity + texture) | 8.98 | 8.81 | | Whole render 12.2 |
| Presence (clarity 0.3, texture 0.3, dehaze 0.2) | 6.98 | 7.10 | 33.7 | Re-runs every tick |
| Sharpen 0.6 | 2.27 | 2.14 | 10 | |
| Effects (vignette + grain) | 0.96 | 0.81 | | |
| Denoise (luminance 0.3) | 4.66 | about 4 | | Never cached: re-runs even on an exposure tick |
| Heal, 20 patches | skipped on hit | | | WB miss 5.23 whole render (heal 1.93 GPU) |
| Tone equalizer | 0.95 | | | WB drag rebuilds its mask: 3.0 |
| Tone equalizer region prepare (tile, WB miss) | | 14.71 | | Extra whole-image render + mask, with its own GPU wait |
| Scopes: histogram / waveform / vectorscope | 0.25 / 0.46 / 0.45-0.49 | | | At most every 100 ms |
| Scopes: "Selected Mask Only" histogram | 9.72 (13.3) | | | Extra render, 2 readbacks, CPU sum |

### 3.3 Where a heavy edit's 22 ms goes (preview, exposure tick, GPU ms)

| Presence | Denoise | Colour + 4 masks | Sharpen | Lens | Tone eq. | Effects |
|---|---|---|---|---|---|---|
| 6.85 | 5.4 | 3.2 | 2.5 | 1.0 | 0.97 | 0.94 |

### 3.4 One-time costs

| Item | Median ms | Worst ms | Notes |
|---|---|---|---|
| GPUContext init, shader cache hit | 11.0 (app), 57.8 (test, first in process) | 15.2 / 109 | 109 under load |
| GPUContext init, shader cache miss (cold compile) | 923 | 930 | Real cold compiles 1.1-2.3 s under load |
| 37 eager pipelines | 1.3 | 4.2 | |
| All 54 lazy pipelines, first use | 1.45 | 5.8 | Open agent: in the app no lazy pipeline was built during a normal open |
| First LMMSE tile vs warm | 24.1 vs 9.6 | 57 | Render agent attributes about 15 ms to pipeline compiles. **The open agent's numbers above disagree**; treat this as unconfirmed |
| First preview in process vs warm | 6.8 vs 1.6 | 25.2 | |

## 4. Slider tick breakdown

### 4.1 Engine only (no views), 2560x1600 window unless noted

| Tick | Median ms | Worst ms | Split |
|---|---|---|---|
| Exposure, fit, base edit | 2.94 | 4.65 | Preview 2.55 + analysis 0.33 |
| White balance, fit | 4.49 | 6.23 | Preview 3.36 + analysis 1.08 |
| Exposure, fit, 1500x1000 window | 1.18 | 4.02 | WB 2.77 |
| Mask slider, 4 masks | 6.25 | 7.51 | 2.70 at 1500x1000; 16.4 with "Selected Mask Only" scopes |
| With tone-equalizer panel open | 4.11 | 10.21 | WB drag 8.86 (mask rebuild) |
| With magnifier | 2.89 | 4.10 | Magnifier render 0.26 |
| Exposure at 100% | 4.83 | 6.11 | Preview 2.34 + analysis 0.30 + tile 1.90 |
| White balance at 100% | 14.81 | 15.32 | Tile 10.37 + preview 3.18 + analysis 0.84 |
| Pan at 100% | 2.10 | 3.24 | Pan is debounced 80 ms |
| HEAVY exposure / mask / brush, fit | 23.71 | 27.68 | Preview 21.3 + analysis 1.7 |
| HEAVY white balance, fit | 28.61 | 30.67 | |
| HEAVY exposure at 100% | 51.21 | 52.77 | Tile 26.8 + **preview 21.8 (hidden behind the tile)** + analysis 1.75 |
| HEAVY white balance at 100% | 65.30 | 66.21 | Tile 37.3 + preview 25.1 |

Main-thread time per tick is GPU time plus 0.2-0.5 ms: every render waits for the GPU to finish on the main thread.

### 4.2 In the real app (1400x900 window, 60 ticks at 60 Hz, release)

| Tick | Median ms | Worst ms | Render part | SwiftUI + drawing part | View bodies re-evaluated | fps |
|---|---|---|---|---|---|---|
| Default panel (WB/Tone/Presence open) | 22.2 | 25.5 | 3.4 | 18.9 | 67 | about 45 |
| All groups collapsed | 18.2 | 20.5 | 3.3 | 15.1 | 54 | about 54 |
| All groups expanded | 52.0 | 57.1 | 3.8 | 48.7 | 149 | about 19 |
| At 100% zoom | 31.4 | 35.9 | 11.5 | 20.1 | | about 31 |
| Status text change only (nothing to render) | 15.3 | 18.4 | 0 | 15.3 | 65 | |
| Status text change, groups expanded | 47.1 | 51.9 | 0 | 47.1 | | |

`sample` profile of the default tick: 74.5% of main in SwiftUI's `GraphHost.flushTransactions`, 14.2% in Core Animation commit, 10.7% in our render (9.8% of it waiting on the GPU). With groups expanded, `LensCorrectionsPanel.body` alone is 14.9% (it re-sorts the lens database twice per tick). Debug build is only about 10% slower, because the cost is in SwiftUI, not in our code. `ContentView.body` itself costs only 0.4 ms per call; the cost is SwiftUI diffing the huge tree it invalidates.

## 5. Opening and launch

### 5.1 Launch (warm unless noted)

| Step | Median ms | Worst ms | Notes |
|---|---|---|---|
| Process start to `applicationWillFinishLaunching` | 166 (140 in a 2nd set) | 175 | Before our code runs |
| Same, first launch after a rebuild or install | 1047 | 1098 | 21 MB binary paged in, signature checked |
| Process start to window content | 373 | 384 | |
| Window content to GPU attached on main | 229 | 240 | Main busy, inferred to be the first SwiftUI layout. The GPU context was ready at about 200 ms but waits |
| Process start to first photo drawn | 911 | 919 | Drawn at 3016x2016; the final fit-size preview arrives at about 1078 |
| Same, shaders not cached | 1408 | 1421 | |
| Lensfun database parse (background) | 142 | 142 | If an open arrives first, `ImageSession` init waits for it on main |

### 5.2 Opening one photo

| Step | Median ms | Worst ms | Blocks | Notes |
|---|---|---|---|---|
| Edit stack read before decode | 45 (Loupe) / 60 (Develop) | 66 | async, but delays the decode | |
| Raw decode through XPC | 237 | 238 | **Main** | 262-292 during switching runs |
| Raw decode in-process | 222 | 228 | **Main** | XPC adds only about 15 ms |
| `ImageSession` init | 4.6 | 4.7 | Main | Render agent measured 161 ms in a test that included more setup; the app number is 4.6 |
| Open render #1 (preview + analysis) | 22.7 at launch, 10.3 when switching | 23.3 | Main | |
| Open render #2 (duplicate) | 6.3 | 13.1 | Main | Happens whenever the new photo's settings differ (nearly always) |
| `open(url:)` synchronous total | 276 at launch; 263 test; 287 engine harness | 280-317 | Main | |
| Loupe: selection to first preview | 346 | 485 | Main blocked 290 | No embedded-JPEG fast path |
| Develop: selection to first preview | 402 | 464 | Main blocked 312 | |
| App: Library to Develop, new photo | 447 | 511 | One 297 ms freeze | |
| App: Library to Develop, same photo | 154 | 169 | Longest freeze 56 | Building the Develop views |
| App: Develop to Library | 134 | 155 | Longest freeze 54 | |
| Embedded JPEG decode, full size | 41.7 | 43.1 | could be background | Possible fast path; 47 ms straight to 2400 px |
| Open 76 MB Photo Merge DNG | 89.9 | 94.7 | Main | |
| AI-mask input render + readback | 3.1 | 3.9 | Main | Only for edits with AI masks |
| Touch-up analysis render | 11.4 | 13.3 | Main | Only for edits with touch-up |

### 5.3 High Quality Preview

| Step | Median ms | Worst ms | Notes |
|---|---|---|---|
| `renderHighQualityPreview`, base edit (engine) | 91.7 | 98.9 | Main. Runs 400 ms after the last change |
| Same, heavy edit | 208.7 | 213.5 | 141 ms GPU |
| Same, in the app | 117.8 | 137.9 | |
| Part: full render, texture pool released first (as the app does) | 73.2 | 73.4 | 47 GPU + about 26 allocating; the cached demosaic is thrown away |
| Part: full render, pool kept | 9.7 | 10.5 | |
| Part: resample 6032 to 2560 | 22.1 | 23.2 | New 24 MP buffer each call |
| UI: longest main freeze after one edit | 42.4 | 45.2 | About 2.5 dropped frames |

## 6. Library and catalog

| Operation | Median | Worst | Blocks | Notes |
|---|---|---|---|---|
| First import 200 NEF, cold | 10.2 s | 10.6 s | Background | Hashing 9.3 s at 583 MB/s (SSD can do 2.6 GB/s) |
| First import 2,000 NEF, cold (54 GB) | 104 s | 114 s | Background | 2 samples. Hashing 92-100 s; metadata re-reads every file (2.9 ms each) |
| First import 2,000 NEF, warm | 12.7 s | 12.9 s | Background | ExifExtras 6.1 s, hash 4.8 s, XPC metadata 1.1 s, sidecars 0.3 s, scan 0.18 s |
| First import 1,800 NEF + 200 JPEG, warm | 11.4 s | 11.5 s | Background | |
| Per file: XPC metadata | 0.6 ms | 18 ms | | Carries the 1 MB embedded JPEG every call; 2.9 ms cold |
| Per file: ExifExtras second ImageIO open | 3.1 ms | 90 ms | | 5x the LibRaw metadata read |
| Per file: hash via mmap, cold | 45.9 ms | 110 ms | | |
| No-change refresh, 2,000 (folder watcher) | 215 ms | 220 ms | Background | Directory scan 179 ms (about 90 µs per file) |
| `Library.open()` existing 2,000 catalog | 235 ms | 248 ms | Background; main stalls 1 ms | |
| `Catalog.open` 2,000 / 10k rows | 3-4 / 5.7 ms | 12.4 / 6.1 ms | Background | quick_check grows about 1.6 ms per MB |
| loadList queries after import, 2,000 | 38.6 ms | 43.6 ms | Background | |
| Thumbnails 200 NEF: Low / Normal / High | 3.2 / 1.7 / 1.2 s | 3.4 / 1.9 / 1.3 s | Background | 63 / 115 / 171 per second |
| Thumbnails 2,000 NEF: Low / Normal / High | 33.1 / 16.8 / 10.5 s | 1 sample | Background | HEIC encode 19-27 ms costs more than the JPEG decode 11.6-14.3 ms |
| Edited-photo thumbnail | 310 ms | 380 ms | Background | Full decode 268 ms of it |
| Paste Settings to 100: catalog writes | 86 ms | 87 ms | Main awaits | Not a problem |
| Paste Settings to 100: thumbnail re-render | 9.2 s | 10.8 s | Background | Decode-bound |
| Load 2,000 cached thumbnails (512 px) | 1.15 s | 1.22 s | Background | 0.58 ms each; memory cache holds about 381 at 512 px |
| Cached-thumbnail lookup x2,000 | 0.15 ms | 0.27 ms | Main | |
| Grid cell configure | 9.4 µs | | Main | |
| Verify Files 200, cold / warm | 2.0 / 0.72 s | 2.4 / 0.73 s | Background | Uses read(): 2.64 GB/s. Same files through import's mmap path: 9.0 s |
| Find Duplicates, 2,000 / 10k | 2.2 ms / about 9-11 ms | 2.8 ms | Main | |
| Filter text, 2,000 | 1.25 ms | 1.45 ms | Main | |
| Search keystroke, 10k | 23.0 ms | 23.4 ms | Main | Names only 7.2 ms |
| Collection counts, 10k | 129 ms | 129 ms | Main | Slowest library item |
| Smart collection, 10k | 56.4 ms | 56.5 ms | Main | |
| Sort 20k by file name | 52.4 ms | 57.5 ms | Main | By date 6.7 ms |
| Tone-equalizer mask percentiles | 14.0 ms | 14.1 ms | Main | |

## 7. Export (10 D750 NEFs, warm, per photo)

| Format | Median ms | Worst ms | Per minute | Breakdown (median) |
|---|---|---|---|---|
| JPEG q92, full size | 532 | 601 | 105-111 | Decode 260, render 104 (GPU 68), pack 17, CGImage 26, encode + write 111. GPU busy 13% |
| JPEG, full size, through XPC | 532 | 644 | 103 | XPC decode 291 vs 274 in-process |
| JPEG, 2048 px | 325 | 493 | 162 | Decode 264 (81%) |
| JPEG, full size, with output sharpening | 577 total | | 102 | Sharpen 12.5 |
| JPEG, 2048 px, with output sharpening | 483 total | | | First photo: +200 ms pipeline compile |
| HEIC q92 | 544 | 685 | 102 | Encode 98 |
| 16-bit TIFF | 705 | 1022 | 79 | Under load; decode inflated |
| PNG | 1903 | 3657 | 27 | ImageIO PNG encode 1447 (76%) |
| Render to DNG | 650 | 759 | 85 | Writer 205-211 (CPU colour conversion) |
| Combined PDF, A4 300 ppi | 455 render + 400-680 add | 497 | | Pages stored losslessly, about 18 MB each |
| Contact sheet PDF, 12 per page | 315 | 373 | | Decode-bound |
| Print render, A4 300 ppi 16-bit | 447 | 450 | | |
| Single photo in a new process | 808 | 910 | | First run after a build: +0.98 s shader compile |
| With a Subject mask (warm) | 1006 total; model 480 | 498 | 27 | First use in a process 11.7 s (38.5 s under load) |
| AI Denoise, default compute | 14,480 | 16,724 | 3.8 | 486 tiles of 256 px |
| AI Denoise, Neural Engine allowed | 10,011 | 10,259 | | 3 samples under load 18-29 |
| 10 photos in 1 / 2 / 3 processes | 4.7-6.7 / 2.8-3.8 / 2.5-5.2 s | | | 2 workers: 1.7-2x faster. About 0.5 GB RAM per worker |

## 8. UI and main thread (real app window)

| Action | Median ms | Worst ms | Notes |
|---|---|---|---|
| Library selection change (arrow key) | 22.9 busy | 29.7 | Longest single freeze 18.3; 47 view bodies re-evaluated |
| Export sheet open | 371 | 405 | Almost all AppKit's sheet slide animation; our code is negligible |
| Settings window open | 3.6 | 163 (first) | |
| Folder open + thumbnails, 8 photos | 93 | 1 sample | |

## 9. Not measured

| Gap | Why it matters |
|---|---|
| Real mouse drags and event coalescing | Real ticks may arrive faster or slower than 60 Hz |
| Frames actually reaching the screen (Metal present, display hitches) | Main-thread busy time is a proxy |
| Precompiled `default.metallib` path | Needs the Metal toolchain (a download); pipeline creation may become the slow part |
| Shared GPU command queue under contention (thumbnails or export running while editing) | Could add stalls to Develop |
| AI model stages: AI masks, lens blur, reflection removal, touch-up model inference | Need ML results the test tools don't build |
| Second display (Loupe on an external monitor) | |
| Truly cold disk for open and export; network volumes | Page cache always warm |
| Real 10k-raw import; real large catalogs with history | Only synthetic 10k fixtures |
| What exactly the main thread does in the 230 ms after the window appears | Profiling distorted it; "first SwiftUI layout" is an inference |
| Holding an arrow key (rapid switching, cancellation) | |
| Compare, Survey, full screen, Contact Sheet window, macOS print spooling | |
| HDR, AVIF, JPEG XL, EXR exports; wide-gamut conversions | |
| Peak GPU memory per export worker | maxRSS may miss private Metal memory |
| Directory scan split (tags vs lstat vs resource values) | Fix sizing comes from a code read |
| Release build without `-DDEBUG` | Debug-only code paths were compiled in |
