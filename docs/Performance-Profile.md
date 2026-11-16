# Latent performance profile: what takes how long

Measured November 2026 on `main` at `62625ef`, by five measuring agents (render, open, library, export, UI), each in its own worktree and branch (`perf/render`, `perf/open`, `perf/library`, `perf/export`, `perf/ui`). None of those branches is merged. Only numbers the agents measured appear here. Estimates are marked *(estimate)*.

Re-measured on `main` at `1170c1a`, after speed waves 1 and 2, by five agents again (same areas, branches `remeasure/*`). The original numbers are kept everywhere. The new ones sit next to them in an **After** column or row. "Not re-measured" means nobody timed that row again.

The speed-up plan built on these numbers is in [Performance-Plan.md](Performance-Plan.md).

## 0. After waves 1 and 2 (November 2026, main 1170c1a)

### 0.1 Headline operations, before and after

Each cell is median (worst). "Main" is the time the main thread is blocked. "Ready" is when the result is done (GPU finished, readbacks in place). Before wave 2, every render waited for the GPU on main, so the old figure is both.

| Operation (what the user does) | Before (62625ef) | After (1170c1a) | Verdict before / after |
|---|---|---|---|
| Open photo: Library to Develop, new photo | 447 ms (511); one 297 ms (332) freeze | Neighbour already prefetched: 78 ms (88), longest main turn 53.0. Decode needed: 254 ms (321), longest main turn 50.5 (77.9). UI harness: longest main iteration 28.0 (55.1) | **Slow** / OK |
| Switch photo, Develop | 402 ms (464); main blocked 312 (371) | Prefetched: 83 ms (110), longest main turn 66.5 (106.9). Decode needed: 278 ms (291), longest main turn 45.7 (53.1) *(load 4-7)* | **Slow** / OK (prefetched), **Slow** but not frozen (decode needed) |
| Switch photo, Loupe | 346 ms (485); main blocked 290 (416) | Prefetched: 68 ms (114), longest main turn 56.8 (98.6). Decode needed: 245 ms (286), longest turn 39.5 (48.5); camera JPEG shown at 74 ms *(load 4-7)* | **Slow** / OK |
| Slider tick, default panel, fit, in the app | 22.2 ms (25.5); 67 view bodies | 6.28 ms (13.97) main per tick; 5 view bodies | **Near** / OK |
| Slider tick, all panel groups open, in the app | 52.0 ms (57.1); 149 view bodies | 12.48 ms (19.66); 11 view bodies | **Slow** / OK |
| Slider tick, render only, base edit (engine) | 2.94 ms (4.65), all on main | Main 0.04 ms. Ready 1.21 (2.22) during a drag; 2.32 (3.61) at full quality | OK / OK |
| Slider tick, render only, heavy edit | 23.7 ms (27.7), all on main | Main 0.11 ms. Ready 4.96 (6.48) during a drag; 17.45 (18.28) at full quality | **Near** / OK |
| White-balance tick, render only, fit | 4.49 ms (6.23); heavy 28.6 (30.7) | Ready 4.02 (5.41) full / 2.14 (3.63) drag; heavy 26.90 (28.24) full / 9.85 (10.94) drag. Main 0.05-0.19 | OK / OK; heavy **Near** / OK |
| Slider tick at 100% zoom, in the app | 31.4 ms (35.9) | 7.81 ms (16.10) main per tick | **Slow** / OK |
| White-balance tick at 100%, render only | 14.8 ms (15.3) base; 65.3 (66.2) heavy | Base ready 14.45 full / 11.15 drag. Heavy ready 63.46 full / 36.69 (38.94) drag; about 27 fps in a 60 Hz drag. Main 0.45 | OK / OK; heavy **Slow** / **Slow** (but off main) |
| Zoom to 100%: first tile render | 11.2 ms RCD, 9.6 LMMSE, 3.7 bilinear | 11.56 RCD, 9.81 LMMSE, 4.50 bilinear | OK / OK |
| High Quality Preview | 92 ms (99) base, 209 (213) heavy, 118 in the app; all on main | In the editor: ready 20.84 (31.44) base, 82.14 (91.25) heavy; main 0.03 / 0.12. In-app 118 row not re-measured | **Near** / OK |
| Selection to sharp image (HQ preview on) | 866 ms (1010) Loupe; about 1053 Develop | 204 (215) Loupe; 215 (229) Develop | **Near** / OK |
| Launch to first photo drawn (warm) | 911 ms (919) | 668 (692); on screen at 716 (747) | **Near** / OK |
| Launch to first photo, shaders not cached | 1408 ms (1421) | 1192 (1407) *(load 5.2-5.6, worst inflated)* | **Slow** / **Near** |
| Launch to window visible (warm) | 373 ms (384) | 328 (355) | OK / OK |
| Import 2,000 raws, cold disk | 104 s (114), 2 samples | 19.6 s (24.6), 5 samples *(load 3.5-4.8)* | **Slow** / near the disk limit (about 18 s) |
| Import 2,000 raws, warm | 12.7 s (12.9) | 6.36 s (6.59) | Slow-ish / OK |
| Thumbnails for 2,000 raws, Normal | 16.8 s (1 sample) | 8.06 s (9.08). Low and High not re-measured | Slow-ish / OK |
| Export 10 photos, full-size JPEG | 5.4-5.7 s per 10; 105-111 per minute; GPU busy 13% | Automatic (3 at once): 2.29 s (2.35), 262.5 per minute. One at a time: 4.79 s, 125.3 per minute | OK / OK, 2.4x |
| Export 10 photos, 2048 px JPEG | about 3.3 s *(estimate)*; 162 per minute | Automatic: 1.30 s, 462.2 per minute. One at a time: 205.9 per minute *(load 4.1-5.0)* | OK / OK |
| Filter / search keystroke, 10k photos | 23.0 ms (23.4); names only 7.2 | 22.13 (25.83); names only 6.81 | OK / OK (no change) |
| Collection counts (9), 10k photos | 129 ms (129) | 125.7 (126.1) | **Near** / **Near** (no change) |

### 0.2 In plain words

**What got faster.**

- **Opening and switching photos no longer freezes the window.** The raw decode runs in the background and the next photo is decoded before you ask for it. A switch to a prefetched photo takes about 70-80 ms instead of 350-450 ms. Without prefetch it still takes about 250 ms, but the main thread is now blocked for about 40-50 ms, not about 300.
- **Slider drags are smooth.** In the app a tick costs about 6 ms of main time instead of 22 (default panel), and about 12 ms instead of 52 with every group open. SwiftUI now re-runs 5 view bodies per tick, not 67. Renders no longer wait for the GPU on main: the setter only encodes (0.04-0.45 ms).
- **Heavy edits drag at 60 fps at fit.** A drag renders a smaller draft: the heavy tick is ready in about 5 ms instead of 24. The full-quality render follows 150 ms after the drag stops.
- **High Quality Preview** is about 4x faster for a base edit (21 ms instead of 92) and no longer runs on main. Selection to sharp image went from about 0.9-1.05 s to about 0.2 s.
- **Launch** to first photo: 911 to 668 ms. Launching with a file argument now opens a window.
- **Import** is 5x faster cold (104 to 19.6 s for 2,000) and 2x faster warm. Folder refresh is 5x faster (215 to 44 ms). Thumbnails are about 2.1-2.4x faster.
- **Export** of a batch is about 2.2-2.4x faster: Automatic now runs 3 photos at once (262-278 per minute for full JPEG, against 105-111). Combined PDF pages are about 16x smaller.

**What did not change.**

- White balance at 100%: base 14.8 to 14.5 ms, heavy 65.3 to 63.5 ms at full quality. The RCD tile demosaic dominates (plan #36, blocked by the goldens rule).
- Single render stages: no kernel changed. The only structural gain is the cached denoise.
- Library search, collection counts, smart collections and sorting on 10k photos: within noise. Collection counts are still **Near** (126 ms).
- Develop to Library still has a 50 ms freeze (54 before). Fix #32 aimed for under 16 ms.
- A single non-drag edit with all groups open still costs about 45-50 ms of main time in most runs. The big gains apply to drag ticks.

**Regressions and new costs** (details in each section):

- Brush full re-raster on the synchronous path: 5.76 ms before, now 5.8 or 13.4 ms (bimodal). Code unchanged; most likely an efficiency core. It no longer runs on the editor's main thread.
- 100% bilinear tile, WB miss: 3.68 to 4.50 ms (+22%). No demosaic code changed; probably noise. Bilinear is not the default.
- First window layout at launch: 229 to 263 ms (+34 ms), probably because the hidden Develop panel is now built at launch (#32). Launch as a whole is still 243 ms faster.
- Settings window open: longest main iteration +7 ms (28.8 against 21.8 with the old binary the same day). Library selection change: +1-2 ms against the old binary. Export sheet: possibly +20 ms, within the spread. All three are probably the kept-alive Develop panel (#32).
- High Quality Preview through the engine test after an open: 99.3 ms call to shown, against 91.7 (+8%), but main time fell from 92 to 0.2 ms.
- Raw decode: about +4% (222 to 231 in-process). Decoder code unchanged; probably noise.
- Export memory: Automatic = 3 takes peak footprint from about 1.6 GB to 4.6-5.3 GB. The plan's rule was at most 2 workers on this 16 GB Mac.
- New work, not slower: a full-quality settle render after every drag (2.5-3.9 ms base fit, 17-24 ms heavy fit, 37-44 ms heavy 100%), never on main.

### 0.3 How the after numbers were taken

| Item | Value |
|---|---|
| Machine | Same Mac16,13, M4, 16 GB |
| Build | Release, `-j 4`. Render: `-enable-testing`, no `-DDEBUG`. Open, library tests and export: as before (open with `-DDEBUG`). UI: the documented `--product latent-app` command, no `-DDEBUG` |
| Medians | Most rows give the median of the per-run medians (for example 3 tick runs of 9, or 4 stage runs of 7). Worst = slowest single sample in all runs |
| Load average | Runs waited for load under 4 inside the measuring lock. Some blocks still ran higher: photo switching, HQ and prefetch rows at 4-7, cold-shader launch at 5.2-5.6, the 3-worker PDF block at 5.6-6.2, the 2048 px export block at 4.1-5.0, and one cold 2,000 import at 4.81. Those rows are flagged *(load ...)*; treat them as upper bounds |
| UI A/B | The UI agent also ran the original `perf/ui` binary (built from `62625ef`) 3 times on the same day. Every UI regression call is based on that A/B |
| Branches | `remeasure/render`, `remeasure/open`, `remeasure/library`, `remeasure/export`, `remeasure/ui` in `/Users/harman/latent-wt/re-*`. Not pushed, never to be merged |

New caveats for the after numbers:

- **Main versus ready.** Since wave 2 the main thread only encodes a render; the GPU finishes later. Rows give both figures. "Ready" is when the GPU is done and the editor has the result, not when the screen shows it.
- **Drag drafts.** During a drag the editor renders a smaller draft (fix #4): a 1508x1008 preview at fit, or a 754x504 backdrop plus the full tile at 100%. Rows marked "full quality" force the old full-size preview for a like-for-like comparison.
- **Prefetch.** In the app's default flow the next photo is already decoded (fix #17). Rows marked "decode needed" turn prefetch off and compare like for like with the original.
- **Not re-measured:** the in-app HQ (117.8 ms), real mouse drags, frames on screen, first launch after a rebuild, Photo Merge DNG open, Lensfun parse, AI model exports, contact sheets, print. See section 9.

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

## 2. One-screen summary (before, 62625ef)

The after numbers for these rows are in section 0.1.

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

**Headline (before):** rendering is fast. The slow, user-visible things are (1) the raw decode running on the main thread at every photo open, (2) SwiftUI redrawing the whole window on every edit, and (3) background jobs (import hashing, export) that run one item at a time and leave the disk or GPU mostly idle. Waves 1 and 2 addressed all three (section 0).

## 3. Render stages (engine only, preview = 3016x2016 "binned-1", tile = 2816x1856 at 100%)

"WB miss" = a white-balance change, which forces the demosaic to re-run. "Exposure hit" = the cached demosaic is reused.

After numbers: 4 stage runs of 7 samples (28), load 3.2-4.5 (the 4th run started slightly over 4). Engine renders are synchronous, so main-thread time does not apply.

### 3.1 Whole renders

| Render | Condition | Median ms | Worst ms | After, median (worst) | Notes |
|---|---|---|---|---|---|
| Preview binned-2 (1504 px) | WB miss | 1.59 | 2.73 | 1.64 (3.40); exposure hit 0.81 (1.70) | Exposure hit 0.92. Now the drag-draft size at fit |
| Preview binned-1 (retina fit) | WB miss | 3.50 | 4.70 | 3.51 (5.33) | |
| Preview binned-1 | Exposure hit | 2.27 | 2.99 | 2.48 (4.00) | 1.29 with lens corrections off. +9% after, but no stage code changed: noise between runs |
| Analysis render binned-4 (754x504) | Exposure hit | 0.33 | 0.45 | 0.34 (0.40); WB miss 1.01; heavy 1.41 | WB miss 0.93; heavy edit 1.66. Heavy is lower now because denoise is cached |
| 100% tile, bilinear demosaic | WB miss | 3.68 | 4.90 | 4.50 (6.34) | +22%: see regressions in 3.5 |
| 100% tile, RCD demosaic | WB miss | 11.24 | 11.88 | 11.56 (13.38) | RCD itself 8.35 GPU. +3% is within noise |
| 100% tile, LMMSE demosaic | WB miss | 9.62 | 10.18 | 9.81 (10.89) | LMMSE 7.05 GPU, faster than RCD |
| 100% tile, RCD | Exposure hit | 2.17 | 3.17 | 2.35 (3.68) | Within noise |
| All stages, preview binned-1 | Exposure hit | 22.25 | 22.96 | 17.28 (18.54) | See 3.3. Denoise is now cached on an exposure hit |
| All stages, preview binned-1 | WB miss | 25.25 | 26.18 | 25.48 (28.27) | A WB miss re-runs denoise, so no gain |
| All stages, tile | Exposure hit / WB miss | 20.13 / 33.6 | 33.84 | 16.45 / 33.88 (27.06 / 40.88) | WB miss worst is one spike in run 3 |
| All stages, preview binned-2 | Exposure hit | 5.15 | 6.82 | 4.42 (7.55) | 4.3x cheaper than binned-1 |
| Full res 6032x4032, RCD (export size) | WB miss | 45.3 | 46.2 | 45.64 (49.05) | RCD 36.4 GPU. Unchanged |

### 3.2 Individual stages (GPU time)

After = the spread of the per-run medians across the 4 runs, preview binned-1, exposure hit. No stage's kernel changed.

| Stage | Preview binned-1 ms | Tile ms | Full res ms | After, preview binned-1 | Notes |
|---|---|---|---|---|---|
| Lens corrections (profile) | 0.98 | 0.86 | 3.9-4.1 | 0.96-1.16 | 0.26 at binned-2. Costs as much as the colour kernel |
| Colour and tone, 0 masks | 0.97 | similar | | 0.94-1.07 | |
| ... 1 radial / 1 brush / 4 / 8 masks | 1.37 / 1.59 / 3.13 / 5.41 | within 10% | | 4 masks 3.11-3.31; 8 masks 5.62; others not re-measured | Whole render 2.66 / 2.90 / 4.61 / 6.90 |
| Brush mask full re-raster (CPU) | 5.76 (27.6 under load) | | | 10.6 (median of run medians 13.40, 5.84, 13.41, 7.75); whole render worst 19.06 | Only when the stroke list is replaced (undo, feather). Painting by appending costs about 0. After: bimodal, see 3.5. Editor renders now redraw it off main (fix #27) |
| Local detail (radial with clarity + texture) | 8.98 | 8.81 | | 9.08 (run 1) | Whole render 12.2 |
| Presence (clarity 0.3, texture 0.3, dehaze 0.2) | 6.98 | 7.10 | 33.7 | 6.60-7.19 | Re-runs every tick. Drags now use coarser blurs (fix #25) |
| Sharpen 0.6 | 2.27 | 2.14 | 10 | 2.24-2.46 | |
| Effects (vignette + grain) | 0.96 | 0.81 | | 1.04-1.36 | |
| Denoise (luminance 0.3) | 4.66 | about 4 | | 4.64-5.80 on a miss; 0 on an exposure hit | Before: never cached. Now cached under the heal key (fix #5) |
| Heal, 20 patches | skipped on hit | | | not re-measured | WB miss 5.23 whole render (heal 1.93 GPU) |
| Tone equalizer | 0.95 | | | 1.01-1.08 | WB drag rebuilds its mask: 3.0 before, 2.90-3.11 after |
| Tone equalizer region prepare (tile, WB miss) | | 14.71 | | not re-measured | Extra whole-image render + mask, with its own GPU wait |
| Scopes: histogram / waveform / vectorscope | 0.25 / 0.46 / 0.45-0.49 | | | not re-measured | At most every 100 ms |
| Scopes: "Selected Mask Only" histogram | 9.72 (13.3) | | | 0.82-1.09, off main (fix #26) | Extra render, 2 readbacks, CPU sum |

### 3.3 Where a heavy edit's 22 ms goes (preview, exposure tick, GPU ms)

| | Presence | Denoise | Colour + 4 masks | Sharpen | Lens | Tone eq. | Effects |
|---|---|---|---|---|---|---|---|
| Before | 6.85 | 5.4 | 3.2 | 2.5 | 1.0 | 0.97 | 0.94 |
| After | 7.2-7.9 | 0 (cached) | not split out | not split out | not split out | not split out | not split out |

After: the whole heavy exposure-hit render is 17.28 ms. Presence is now the largest stage.

### 3.4 One-time costs

| Item | Median ms | Worst ms | After, median (worst) | Notes |
|---|---|---|---|---|
| GPUContext init, shader cache hit | 11.0 (app), 57.8 (test, first in process) | 15.2 / 109 | Test: 54.4 (67.8); app not re-measured | 109 under load. After: 1 sample per run, 4 in all |
| GPUContext init, shader cache miss (cold compile) | 923 | 930 | Test harness: 822 (824). In the app, shader library compile 965 in the background *(load 5.2-5.6)* | Real cold compiles 1.1-2.3 s under load |
| 37 eager pipelines | 1.3 | 4.2 | not re-measured | |
| All 54 lazy pipelines, first use | 1.45 | 5.8 | not re-measured | Open agent: in the app no lazy pipeline was built during a normal open |
| First LMMSE tile vs warm | 24.1 vs 9.6 | 57 | 22.75 (29.1) | Render agent attributes about 15 ms to pipeline compiles. **The open agent's numbers above disagree**; treat this as unconfirmed |
| First preview in process vs warm | 6.8 vs 1.6 | 25.2 | 9.25 (10.9), first preview at 1500 px | Not the same size as before, so not directly comparable |
| `ImageSession` init in the test process | 161 | | 177.6 (201.0) | 4 samples, noisy |

### 3.5 Render regressions found in the re-measure

| Item | Before | After | Best explanation |
|---|---|---|---|
| Brush full re-raster, synchronous path | 5.76 ms | Bimodal: 5.84 / 7.75 / 13.40 / 13.41 in the 4 runs | Rasterizer code is unchanged; #27 adds one fingerprint pass. A 2.3x step looks like a single-threaded CoreGraphics job landing on an efficiency core (the old profile saw 27.6 under load). Unconfirmed: a run pinned to high QoS would settle it. Only export, magnifier and masked scopes still take this path; editor renders redraw off main |
| 100% bilinear tile, WB miss | 3.68 ms | 4.50 (6.34) | No demosaic or stage code changed. Run 1 was 4.97, runs 2-4 4.41-4.58: noise or thermal on a small kernel. Bilinear is not the default |
| Old `HighQualityPreview.render` path | 91.7 / 208.7 ms | 100.79 / 206.41 (worst 129.73 / 269.87) | Code unchanged, run 2 alone gave 89.7. The editor no longer uses this path |

## 4. Slider tick breakdown

### 4.1 Engine only (no views), 2560x1600 window unless noted

Before: every render waited for the GPU on main, so the number is both main time and ready time. After: "main" is the setter's time on main (it now only encodes), "ready" runs until the GPU is done and the result is in place. After = 3 runs of 9 ticks (27), load 2.4-3.4.

| Tick | Median ms | Worst ms | Split | After, full quality: ready (worst) | After, during a drag: ready (worst) | After: main |
|---|---|---|---|---|---|---|
| Exposure, fit, base edit | 2.94 | 4.65 | Preview 2.55 + analysis 0.33 | 2.32 (3.61) | 1.21 (2.22) | 0.04 (0.15) |
| White balance, fit | 4.49 | 6.23 | Preview 3.36 + analysis 1.08 | 4.02 (5.41) | 2.14 (3.63) | 0.05 (0.15) |
| Exposure, fit, 1500x1000 window | 1.18 | 4.02 | WB 2.77 | 0.97 (5.45); WB 2.69 (9.85) | 0.46; WB 1.17 | 0.03-0.08 |
| Mask slider, 4 masks | 6.25 | 7.51 | 2.70 at 1500x1000; 16.4 with "Selected Mask Only" scopes | settle 4.8-6.5 | 1.71 (3.20); with "Selected Mask Only" 3.14 (5.22) | 0.05; 0.11 |
| With tone-equalizer panel open | 4.11 | 10.21 | WB drag 8.86 (mask rebuild) | not re-measured | 1.47 (2.65); WB 4.03 (6.44) | 0.09-0.10 |
| With magnifier | 2.89 | 4.10 | Magnifier render 0.26 | not re-measured | 1.20 (3.32) | 0.04 |
| Exposure at 100% | 4.83 | 6.11 | Preview 2.34 + analysis 0.30 + tile 1.90 | 4.05 (5.70) | 2.38 (3.41) | 0.21 full; 0.36 drag |
| White balance at 100% | 14.81 | 15.32 | Tile 10.37 + preview 3.18 + analysis 0.84 | 14.45 (15.28) | 11.15 (11.64), 1 intact run of 9 | 0.45 |
| Pan at 100% | 2.10 | 3.24 | Pan is debounced 80 ms | 2.68 (3.77) | | 0.51 |
| HEAVY exposure / mask / brush, fit | 23.71 | 27.68 | Preview 21.3 + analysis 1.7 | 17.45 (18.28) | 4.96 (6.48); mask 5.07 (6.25); brush 5.17 (7.38) | 0.10-0.11 |
| HEAVY white balance, fit | 28.61 | 30.67 | | 26.90 (28.24) | 9.85 (10.94) | 0.19 |
| HEAVY exposure at 100% | 51.21 | 52.77 | Tile 26.8 + **preview 21.8 (hidden behind the tile)** + analysis 1.75 | 37.46 (39.65) | 18.52 (20.35); mask 18.59; brush 18.64 | 0.40 |
| HEAVY white balance at 100% | 65.30 | 66.21 | Tile 37.3 + preview 25.1 | 63.46 (65.17) | 36.69 (38.94) | 0.45 |

Main-thread time per tick (before) is GPU time plus 0.2-0.5 ms: every render waits for the GPU to finish on the main thread. **After:** the main thread only encodes (0.03-0.45 ms median, 2.32 worst); the GPU finishes on its own. After a drag stops, a full-quality settle render runs 150 ms later: ready 2.8-3.1 ms base fit, 17.1-17.7 heavy fit, 37.2-39.7 heavy 100%, 44 heavy 100% WB.

**New: paced 60 Hz drag, latest wins** (10 drags of 60 ticks per condition, load 3.0-3.4). Main per tick 0.05-0.23 ms (worst 1.98). Renders delivered: base fit 60.4-60.7 fps; heavy fit exposure 60.0 / WB 59.2 fps; heavy 100% exposure 55.7 / WB 26.7 fps (lowest 23.1). Heavy 100% WB is GPU-bound by its 36 ms draft tile, so in-between ticks are dropped.

### 4.2 In the real app (1400x900 window, 60 ticks at 60 Hz, release)

After = median of the per-run medians over 5 runs (300 ticks per row, 150 at 100%), load 1.9-4.0. Same-day A/B with the old binary in the notes. The render / SwiftUI split is not available after (on Darwin 27 the Core Animation commit runs inside another run-loop source), so only totals are given.

| Tick | Median ms | Worst ms | Render part | SwiftUI + drawing part | View bodies re-evaluated | fps | After: main per tick, median (worst) | After: bodies | After: result ready |
|---|---|---|---|---|---|---|---|---|---|
| Default panel (WB/Tone/Presence open) | 22.2 | 25.5 | 3.4 | 18.9 | 67 | about 45 | 6.28 (13.97); old binary same day 22.9 | 5 | 6.15 (13.96) |
| All groups collapsed | 18.2 | 20.5 | 3.3 | 15.1 | 54 | about 54 | 5.28 (15.37); old binary 16.9 | 3 | 5.20 (15.32) |
| All groups expanded | 52.0 | 57.1 | 3.8 | 48.7 | 149 | about 19 | 12.48 (19.66); old binary 54.5 | 11 | 11.0 (31.95) |
| At 100% zoom | 31.4 | 35.9 | 11.5 | 20.1 | | about 31 | 7.81 (16.10); old binary 32.4 | 6 | 7.31 (18.49) |
| Status text change only (nothing to render) | 15.3 | 18.4 | 0 | 15.3 | 65 | | 3.69 (8.36); old binary 15.6 | 0 | n/a |
| Status text change, groups expanded | 47.1 | 51.9 | 0 | 47.1 | | | 6.12 (10.39); old binary 49.3 | | n/a |
| New: Lens Corrections group open | | | | | | | 6.37 (16.75) | 5 | 6.13 |

`sample` profile of the default tick (before): 74.5% of main in SwiftUI's `GraphHost.flushTransactions`, 14.2% in Core Animation commit, 10.7% in our render (9.8% of it waiting on the GPU). With groups expanded, `LensCorrectionsPanel.body` alone is 14.9% (it re-sorts the lens database twice per tick). Debug build is only about 10% slower, because the cost is in SwiftUI, not in our code. `ContentView.body` itself costs only 0.4 ms per call; the cost is SwiftUI diffing the huge tree it invalidates.

**After:** main time spent encoding in the setter fell from 3.2 to 0.15 ms (fit) and from 12.6 to 0.36 ms (100%). Ticks render as drag drafts. The Lens Corrections panel is no longer re-evaluated on a tick (fixes #2 and #23).

**New: a single full-quality edit (not a drag), left to finish** (HQ preview on, 40 samples, load 2.7-4.0):

| Condition | Result ready, median (worst) | Main busy | Notes |
|---|---|---|---|
| Default panel | 33.3 (39.7) | 34.7; longest iteration 11.8 | HQ off: ready 12.7. Probably re-allocating the textures the HQ pass released (not confirmed) |
| All groups expanded | 35.0 (70.8); run medians 21.1 and 48.8 | | Bimodal. HQ off: 47.7. Close to the old 52 ms tick: only drag ticks got the big gain |
| 100% zoom | 16.5 (35.1) | 12.4; longest 3.6 | HQ off: 30.7 |

## 5. Opening and launch

### 5.1 Launch (warm unless noted)

After: 7 launches after 1 discarded, load 3.1-3.7, release with `-DDEBUG`.

| Step | Median ms | Worst ms | After, median (worst) | Notes |
|---|---|---|---|---|
| Process start to `applicationWillFinishLaunching` | 166 (140 in a 2nd set) | 175 | 127 | Before our code runs |
| Same, first launch after a rebuild or install | 1047 | 1098 | not re-measured (one discarded run: 989) | 21 MB binary paged in, signature checked |
| Process start to window content | 373 | 384 | 328 (355) | |
| Window content to GPU attached on main | 229 | 240 | 263 (265), window onAppear to main free | Main busy, inferred to be the first SwiftUI layout. The GPU context was ready at about 200 ms but waits. After: about 34 ms slower, probably because the hidden Develop panel is built at launch (#32). attachGPU now follows 0.3 ms after main frees, at 591 from process start |
| Process start to first photo drawn | 911 | 919 | 668 (692); on screen 716 (747) | Drawn at 3016x2016; the final fit-size preview arrives at about 1078. After: the fit-size preview is ready at 685 (750). The decode runs in the background beside GPU start; apply is 6.6 ms on main |
| Same, shaders not cached | 1408 | 1421 | 1192 (1407) *(load 5.2-5.6)* | After: shader compile 965 in the background |
| File argument (`Latent file.NEF`) | no window opened | | 668 (767) to first frame; on screen 712 (835) *(load 5-7)* | Fix #14: a window opened in all 7 launches |
| Lensfun database parse (background) | 142 | 142 | not re-measured | If an open arrives first, `ImageSession` init waits for it on main |

### 5.2 Opening one photo

After: switching rows are from 6 runs (prefetched) or 3 runs (decode needed), mostly at load 4-7. "Main" after = the longest single run-loop turn between the selection and the result.

| Step | Median ms | Worst ms | Blocks | After, median (worst) | Notes |
|---|---|---|---|---|---|
| Edit stack read before decode | 45 (Loupe) / 60 (Develop) | 66 | async, but delays the decode | 34 (Develop), now beside the decode (fix #7) | |
| Raw decode through XPC | 237 | 238 | **Main** | 246.7 (259.6), background | 262-292 during switching runs. Decoder unchanged; +4% is probably noise |
| Raw decode in-process | 222 | 228 | **Main** | 230.7 (256.0) | XPC adds only about 15 ms |
| `ImageSession` init | 4.6 | 4.7 | Main | 4.5 (5.9) | Render agent measured 161 ms in a test that included more setup; the app number is 4.6 |
| Open render #1 (preview + analysis) | 22.7 at launch, 10.3 when switching | 23.3 | Main | Encode 0.1-0.3 on main; completes about 1 ms after open returns | |
| Open render #2 (duplicate) | 6.3 | 13.1 | Main | gone (fix #8) | Happens whenever the new photo's settings differ (nearly always) |
| `open(url:)` synchronous total | 276 at launch; 263 test; 287 engine harness | 280-317 | Main | 234.9 test (267.3) | After: this path (Open File, Compare/Survey panes, tests) still decodes on main. The catalog uses the async open: 245.0 (286.0) call to settled |
| Loupe: selection to first preview | 346 | 485 | Main blocked 290 | Prefetched 68 (114), main 56.8 (98.6). Decode needed 245 (286), main 39.5 (48.5) | Before: no embedded-JPEG fast path. After: the camera JPEG shows at 74 (87) (fix #18) |
| Develop: selection to first preview | 402 | 464 | Main blocked 312 | Prefetched 83 (110), main 66.5 (106.9). Decode needed 278 (291), main 45.7 (53.1) | After: the open's own main work is 6 ms (apply 5.7, encode 0.3). The rest of the long turn is SwiftUI reacting to the selection |
| App: Library to Develop, new photo | 447 | 511 | One 297 ms freeze | Open harness: decode needed 254 (321), longest turn 50.5 (77.9); prefetched 78 (88), longest 53.0. UI harness: longest iteration 28.0 (55.1), wall 127 (386 cold first) | |
| App: Library to Develop, same photo | 154 | 169 | Longest freeze 56 | Longest 29.9 (34.4); settle 90.2 (97.7) | Building the Develop views. After: Develop is kept built (#32) |
| App: Develop to Library | 134 | 155 | Longest freeze 54 | Longest 50.0 (58.1); settle 136.6 (151.4) | After: only slightly better. #32 aimed for under 16 ms |
| Embedded JPEG decode, full size | 41.7 | 43.1 | could be background | 42.4 (45.5), background | Possible fast path; 47 ms straight to 2400 px (47.4 after) |
| Open 76 MB Photo Merge DNG | 89.9 | 94.7 | Main | not re-measured | |
| AI-mask input render + readback | 3.1 | 3.9 | Main | 3.04 (7.77) | Only for edits with AI masks |
| Touch-up analysis render | 11.4 | 13.3 | Main | 10.64 (12.21) | Only for edits with touch-up |

New after: every switch still has one main run-loop turn of about 50-67 ms (worst 107) near the selection. The open itself is only 6 ms of it. This is the next main-thread target in the open path.

### 5.3 High Quality Preview

| Step | Median ms | Worst ms | After, median (worst) | Notes |
|---|---|---|---|---|
| `renderHighQualityPreview`, base edit (engine) | 91.7 | 98.9 | In the editor, kept buffers: ready 20.84 (31.44), main 0.03. Open area's engine test, right after an open: 99.3 (106.1) call to shown, main 0.21 | Before: main, runs 400 ms after the last change. After: off main (fix #20). The plan estimated about 15 ms; the rest is the resample. The open-area figure is about 8% slower than before; best guess is the async completion hop and a different pool shape. At 1500x1000: ready 24.23 (28.82) |
| Same, heavy edit | 208.7 | 213.5 | Ready 82.14 (91.25), main 0.12 | 141 ms GPU before; 70.45 GPU after. Plan estimate was about 110 |
| Same, in the app | 117.8 | 137.9 | not re-measured | |
| Part: full render, texture pool released first (as the app did) | 73.2 | 73.4 | 75.41 (86.24) | 47 GPU + about 26 allocating; the cached demosaic is thrown away. The editor now keeps the pool |
| Part: full render, pool kept | 9.7 | 10.5 | 9.46 (10.52) | |
| Part: resample 6032 to 2560 | 22.1 | 23.2 | 23.79 (26.41) | New 24 MP buffer each call |
| UI: longest main freeze after one edit | 42.4 | 45.2 | 35.0 (39.7) | About 2.5 dropped frames before. After: bimodal in both binaries (run medians 36.0, 35.0, 35.5, 17.8, 15.5; old binary same day 44.3, 15.8, 16.6) |
| Selection to sharp image, Loupe | 866 | 1010 | 204 (215) *(load 4-7)* | HQ now follows an open with no 400 ms wait (fix #10). HQ GPU 98 ms, encode 0.3 on main |
| Selection to sharp image, Develop | about 1053 | | 215 (229) *(load 4-7)* | HQ GPU 102.5 ms. apply 10.7 ms with HQ on, 5.7 off |

## 6. Library and catalog

After: release, XPC decoder, 5 samples per row unless noted, load 2.1-4.1 (cold 2,000 import 3.5-4.8). Main-thread stalls during `Library.open` and refresh: at most 1.6 ms.

| Operation | Median | Worst | Blocks | After, median (worst) | Notes |
|---|---|---|---|---|---|
| First import 200 NEF, cold | 10.2 s | 10.6 s | Background | 2.52 s (2.64) | Hashing 9.3 s at 583 MB/s (SSD can do 2.6 GB/s). After: about 4x (#1, #22). Five more cold-200 runs gave 1.84 s (1.85) at load 3.3-3.4 |
| First import 2,000 NEF, cold (54 GB) | 104 s | 114 s | Background | 19.6 s (24.6) *(load 3.5-4.8)* | 2 samples before. Hashing 92-100 s; metadata re-reads every file (2.9 ms each). After: about 5.3x, close to the 18 s disk limit |
| First import 2,000 NEF, warm | 12.7 s | 12.9 s | Background | 6.36 s (6.59) | ExifExtras 6.1 s, hash 4.8 s, XPC metadata 1.1 s, sidecars 0.3 s, scan 0.18 s. After: stage split no longer maps onto the new one-pass import. ExifExtras still opens each file a second time, now inside the parallel workers |
| First import 1,800 NEF + 200 JPEG, warm | 11.4 s | 11.5 s | Background | not re-measured | |
| Per file: XPC metadata | 0.6 ms | 18 ms | | not re-measured (1.8-1.9 s total across workers for 2,000 warm) | Carries the 1 MB embedded JPEG every call; 2.9 ms cold |
| Per file: ExifExtras second ImageIO open | 3.1 ms | 90 ms | | not re-measured | 5x the LibRaw metadata read |
| Per file: hash via mmap, cold | 45.9 ms | 110 ms | | not re-measured (now chunked `read()`) | |
| No-change refresh, 2,000 (folder watcher) | 215 ms | 220 ms | Background | 43.7 ms (45.5), 25 samples | Directory scan 179 ms (about 90 µs per file). After: about 4.9x (#11) |
| `Library.open()` existing 2,000 catalog | 235 ms | 248 ms | Background; main stalls 1 ms | 79.2 ms (80.7); main stall 0.9 ms | |
| `Catalog.open` 2,000 / 10k rows | 3-4 / 5.7 ms | 12.4 / 6.1 ms | Background | not re-measured | quick_check grows about 1.6 ms per MB |
| loadList queries after import, 2,000 | 38.6 ms | 43.6 ms | Background | 19.3 ms | |
| Thumbnails 200 NEF: Low / Normal / High | 3.2 / 1.7 / 1.2 s | 3.4 / 1.9 / 1.3 s | Background | 1.32 / 0.79 / 0.52 s (1.40 / 0.82 / 0.53) | 63 / 115 / 171 per second before; 152 / 253 / 384 after. Mostly #31 (JPEG cache) |
| Thumbnails 2,000 NEF: Low / Normal / High | 33.1 / 16.8 / 10.5 s | 1 sample | Background | Normal 8.06 s (9.08) *(load 3.9)*; Low and High not re-measured | HEIC encode 19-27 ms costs more than the JPEG decode 11.6-14.3 ms |
| New: thumbnail pass right after a fresh import, 200 NEF | | | Background | 719 ms (731) | Reuses the previews the import already read (#29): about 278 per second, against 253 without the handoff |
| Edited-photo thumbnail | 310 ms | 380 ms | Background | not re-measured | Full decode 268 ms of it |
| Paste Settings to 100: catalog writes | 86 ms | 87 ms | Main awaits | about 80 ms (57-190) | Not a problem |
| Paste Settings to 100: thumbnail re-render, Normal pass | 9.2 s | 10.8 s | Background | 7.75 s (10.21), 15 samples | Decode-bound. About 16% faster at the same settings |
| New: Paste Settings to 100, urgent pass (#13: High, 8 at once, changed first) | | | Background | 6.46 s (9.66), 15 samples *(load 3.1-4.1)* | Splits in two: quiet processes 5.0-5.6 s, busy ones 9.0-9.4 s. Very sensitive to other CPU load |
| Load 2,000 cached thumbnails (512 px) | 1.15 s | 1.22 s | Background | not re-measured | 0.58 ms each; memory cache holds about 381 at 512 px |
| Cached-thumbnail lookup x2,000 | 0.15 ms | 0.27 ms | Main | not re-measured | |
| Grid cell configure | 9.4 µs | | Main | 9.2 µs (9.3) | |
| Verify Files 200, cold / warm | 2.0 / 0.72 s | 2.4 / 0.73 s | Background | not re-measured | Uses read(): 2.64 GB/s. Same files through import's mmap path: 9.0 s |
| Find Duplicates, 2,000 / 10k | 2.2 ms / about 9-11 ms | 2.8 ms | Main | not re-measured | |
| Filter text, 2,000 | 1.25 ms | 1.45 ms | Main | 1.28 ms (1.31) | No change |
| Search keystroke, 10k | 23.0 ms | 23.4 ms | Main | 22.13 ms (25.83) | Names only 7.2 ms before, 6.81 after |
| Collection counts, 10k | 129 ms | 129 ms | Main | 125.7 ms (126.1) | Slowest library item. Still **Near** |
| Smart collection, 10k | 56.4 ms | 56.5 ms | Main | 54.96 ms (55.16) | |
| Sort 20k by file name | 52.4 ms | 57.5 ms | Main | 49.79 ms (50.70) | By date 6.7 ms before, 6.32 after |
| Tone-equalizer mask percentiles | 14.0 ms | 14.1 ms | Main | 13.57 ms (13.6) | |

Nothing in the library area got slower.

## 7. Export (10 D750 NEFs, warm, per photo)

After: `latent-cli`, 5 samples per block (10 for the one-at-a-time JPEG block), load 2.1-5.1. "Auto" = Photos at once Automatic, which picked 3 on this Mac. Each photo takes a little longer while others are in flight; the batch is still much faster.

| Format | Median ms | Worst ms | Per minute | Breakdown (median) | After, one at a time: per photo (worst), per minute | After, Automatic (3): per minute |
|---|---|---|---|---|---|---|
| JPEG q92, full size | 532 | 601 | 105-111 | Decode 260, render 104 (GPU 68), pack 17, CGImage 26, encode + write 111. GPU busy 13% | 467 (1005), 125.3 | 262.5 (explicit 3: 278.2). GPU busy 24-25% |
| JPEG, full size, through XPC | 532 | 644 | 103 | XPC decode 291 vs 274 in-process | not re-measured | not re-measured |
| JPEG, 2048 px | 325 | 493 | 162 | Decode 264 (81%) | 262 (320), 205.9 *(load 4.1-5.0)* | 462.2 *(load 4.1-5.0)* |
| JPEG, full size, with output sharpening | 577 total | | 102 | Sharpen 12.5 | 442 (511), 127.5 | 263.7 |
| JPEG, 2048 px, with output sharpening | 483 total | | | First photo: +200 ms pipeline compile | not re-measured | not re-measured |
| HEIC q92 | 544 | 685 | 102 | Encode 98 | 432 (494), 129.6 | 207.8 (only 1.6x: the HEIC encoder probably serialises) |
| 16-bit TIFF | 705 | 1022 | 79 | Under load; decode inflated | 524 (581), 108.6 | 217.4 |
| PNG | 1903 | 3657 | 27 | ImageIO PNG encode 1447 (76%) | 1348 (1477), 43.3 | 96.8 (3.6x; the plan aimed for about 3x) |
| Render to DNG | 650 | 759 | 85 | Writer 205-211 (CPU colour conversion) | 509 (598), sequential | n/a |
| Combined PDF, A4 300 ppi | 455 render + 400-680 add | 497 | | Pages stored losslessly, about 18 MB each | JPEG pages (new default, #30): 427 (508) per page = render 373 + JPEG 34 + add 24; 1.1 MB per page. Lossless pages: 554 (646), 7.2 MB per page | 3 at once: 202 (204) per page *(load 5.6-6.2)* |
| Contact sheet PDF, 12 per page | 315 | 373 | | Decode-bound | not re-measured | |
| Print render, A4 300 ppi 16-bit | 447 | 450 | | | not re-measured | |
| Single photo in a new process | 808 | 910 | | First run after a build: +0.98 s shader compile | 573 export / 620 process (630) | same (one photo cannot use more workers) |
| With a Subject mask (warm) | 1006 total; model 480 | 498 | 27 | First use in a process 11.7 s (38.5 s under load) | not re-measured | |
| AI Denoise, default compute | 14,480 | 16,724 | 3.8 | 486 tiles of 256 px | not re-measured | |
| AI Denoise, Neural Engine allowed | 10,011 | 10,259 | | 3 samples under load 18-29 | not re-measured | |
| 10 photos in 1 / 2 / 3 processes | 4.7-6.7 / 2.8-3.8 / 2.5-5.2 s | | | 2 workers: 1.7-2x faster. About 0.5 GB RAM per worker | Now workers in one process, 10 full JPEGs: 1 / 2 / 3 at once 4.79 / 2.66 / 2.16 s (6.20 / 2.70 / 2.19); 4 is capped to 3 | |

After, warm JPEG step times (one at a time): decode 244, render wait 90 (GPU 65), pack 6, CGImage 18, encode + write 96.

**Memory after:** peak process footprint about 1.6 GB one at a time, 3.1 GB at 2, 4.6 GB at 3 (5.2-5.3 GB for TIFF and output sharpening). maxRSS shows only up to 0.97 GB because it does not count Metal's private memory. The plan's rule was at most 2 workers on this 16 GB Mac; Automatic is now 3 (commit `1478325`).

## 8. UI and main thread (real app window)

After: 5 runs, same-day A/B with the old binary (3 runs), load 1.9-4.0.

| Action | Median ms | Worst ms | After, median (worst) | Notes |
|---|---|---|---|---|
| Library selection change (arrow key) | 22.9 busy | 29.7 | 21.0 busy (27.5); longest 16.2 (21.2) | Longest single freeze 18.3 before; 47 view bodies re-evaluated (still 47). After: old binary the same day gave 19.1 busy / 15.0 longest, so this is about +1-2 ms. Marginal but consistent |
| Export sheet open | 371 | 405 | 393.9 (443.4) | Almost all AppKit's sheet slide animation; our code is negligible. Old binary the same day: 371. Possibly +20 ms, but run spreads overlap |
| Settings window open | 3.6 | 163 (first) | 49.7 to visible (167.4 first); longest iteration 28.8 | 3.6 could not be reproduced today with either binary (old: 44.8 / 24.2 / 21.3). Longest iteration is about +7 ms against the old binary (21.8) |
| Lens Corrections group open (disclosure click) | | | 2.07 (3.15) | New row. Longest iteration 2.0 |
| Folder open + thumbnails, 8 photos | 93 | 1 sample | not re-measured | |

The UI regressions (Settings, Library selection, maybe export sheet) are probably the kept-alive Develop panel (#32): the window now holds a larger AppKit tree. Not confirmed with a profile.

## 9. Not measured

| Gap | Why it matters | After waves 1 and 2 |
|---|---|---|
| Real mouse drags and event coalescing | Real ticks may arrive faster or slower than 60 Hz | Still not measured |
| Frames actually reaching the screen (Metal present, display hitches) | Main-thread busy time is a proxy | Still not measured in the tick rows. The launch and Library-to-Develop rows have a few on-screen figures (40-50 ms after "ready") |
| Precompiled `default.metallib` path | Needs the Metal toolchain (a download); pipeline creation may become the slow part | Still parked |
| Shared GPU command queue under contention (thumbnails or export running while editing) | Could add stalls to Develop | Separate queues landed (#24); contention still not measured |
| AI model stages: AI masks, lens blur, reflection removal, touch-up model inference | Need ML results the test tools don't build | Still not measured |
| Second display (Loupe on an external monitor) | | Still not measured |
| Truly cold disk for open and export; network volumes | Page cache always warm | Still warm |
| Real 10k-raw import; real large catalogs with history | Only synthetic 10k fixtures | Still synthetic |
| What exactly the main thread does in the 230 ms after the window appears | Profiling distorted it; "first SwiftUI layout" is an inference | Now 263 ms; still an inference |
| Holding an arrow key (rapid switching, cancellation) | | Still not measured |
| Compare, Survey, full screen, Contact Sheet window, macOS print spooling | | Still not measured |
| HDR, AVIF, JPEG XL, EXR exports; wide-gamut conversions | | Still not measured |
| Peak GPU memory per export worker | maxRSS may miss private Metal memory | Now measured as peak footprint (section 7) |
| Directory scan split (tags vs lstat vs resource values) | Fix sizing comes from a code read | Not re-split |
| Release build without `-DDEBUG` | Debug-only code paths were compiled in | Render and UI after-runs used no `-DDEBUG` |
| New: in-app High Quality Preview (117.8 ms) and the in-app tick rows from the render harness | The render harness drives `EditorModel` without views | Not re-measured |
| New: first launch after a rebuild (1047 ms), Photo Merge DNG open, Lensfun parse, Catalog.open | | Not re-measured |
| New: export of contact sheets, print, Subject mask, AI Denoise; Photos at once = 2 for formats other than JPEG | | Not re-measured |
| New: why the HQ settle and Settings rows are bimodal run to run | Suspected window occlusion by other agents' apps | Not checked |
