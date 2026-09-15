# Photo Merge for Latent: recommended strategy

## 0. Phase 0 findings (2026-09-15) — these override the sections below where they disagree

**DNG spike** (code in `~/latent-wt/spikes/dng`, becomes the Phase 3 writer). The plain-Swift writer produces float16 LinearRaw DNGs, and the vendored LibRaw reads every pixel back bit-for-bit (strips, tiles, odd sizes, deflate with float predictors). ImageIO and CIRAWFilter read and render them correctly.
- **Pixel values are normalised so the maximum is ≤ 1.0.** Divide by a power of two and add the same number of stops to `BaselineExposure`. Apple's RAW engine clips float values above 1.0. Float16 keeps about 14 normal stops below 1.0; wider merges may need 24-bit float (untested).
- **Always write `WhiteLevel = 1`,** and clear `LIBRAW_RAWOPTIONS_CONVERTFLOAT_TO_INT` in `imgdata.rawparams.options`.
- **Tiles, not strips, whenever compressing.** Apple's RawCamera crashes on deflate combined with strips. v1 writes uncompressed 512 px tiles: 45 MP ≈ 294 MB, written in 0.09 s and read in 0.12 s.
- **LibRaw quirks:** it rejects `Software` values that start with "Adobe" or "dcraw"; `dcraw_process()` fails on float data (we don't use it); linking needs Little CMS stubs only if `dcraw_process` is referenced.

**Vision spike** (code in `~/latent-wt/spikes/vision`). This **changes the alignment decision in 2c.**
- **Vision failed:** `VNHomographicImageRegistrationRequest` fails on 21–29% of HDR bracket pairs and on every panorama pair at 15–35% overlap. It only finds shifts up to about 4% of the long edge.
- **What worked:** **phase correlation** (a coarse shift from the Fourier transform) followed by **ECC refinement** (an iterative, brightness-invariant homography fit) over a 400 → 800 → 1600 → 3200 px pyramid.
  - HDR: p90 corner error 0.07–0.11 px, even 8 EV apart, in about 0.4 s on the CPU.
  - Panoramas at 25–35% overlap: p90 0.07–0.14 px with 0 failures (synthetic data).
- **Metal kernels can run the ECC steps later.** v1 does them on the CPU with Accelerate/vDSP.
- **Input:** downsample in linear light with a Gaussian prefilter, divide by exposure gain, clamp to the pair's shared valid range, take log2, and use the same size for both images.
- **Validation:** NCC ≥ **0.9** (not 0.6); overlap ≥ 5%; the scale-change limit applies to HDR only; decide "no warp needed" only after ECC.
- **Vision's matrix convention**, if we ever use it: `H(F→R) = Fy·W·Fy`, with `Fy = [[1,0,0],[0,−1,h],[0,0,1]]`.
- **Panorama fallback:** real panoramas add parallax and lens distortion, so plan a feature-matching fallback for pairs where ECC doesn't converge.

**Test assets.** No CC0 raw brackets or panorama sequences exist that we could find.
- **Best free options (CC BY 4.0, attribution needed):**
  - Ihrke `HDRTest_Raw.zip`: tripod bracket, 6 CR2s, 150 MB.
  - Empa HDR database: `MarketMires2`, `CreteSeashore1` (motion), about 240 MB.
- **CC0 options:**
  - Kolláth CR2 fisheye night panorama, 114 MB.
  - Soltesz 5-frame JPEG bracket and Hurd 4-frame JPEG panorama.
- **Shot list** for what's missing (handheld bracket, long panorama, HDR panorama) is in the Wave A report.

**Active-area fix** is merged: the sensor plane is cut to LibRaw's visible area, and old edits with geometry are migrated on load. The "Crop every frame to the active area" rule in 2a is therefore already true everywhere.

## 1. What Photo Merge will do

**Photo Merge** takes 2 or more photos you select in the grid and writes **one new photo file** next to them. Latent then catalogs it and edits it like any RAW.

- **HDR.** Combines a *bracket*: the same scene shot at different exposures, such as −2, 0 and +2 EV. You get clean shadows from the bright frames and unclipped highlights from the dark frames. *Clipped* means the sensor hit its maximum value, so the detail there is lost.
- **Panorama.** Stitches overlapping shots taken while turning the camera. It produces one wide photo.
- **HDR Panorama.** Merges each bracket to HDR first, then stitches the results. It also accepts HDR files you already merged, as Lightroom does.

**Out of scope, and why:**
- **Boundary Warp** (stretching panorama edges into a rectangle) and **Fill Edges** (inventing missing corners). Each is a research project.
- **Focus stacking.** Lightroom doesn't have it either. List it in `docs/wiki/Limitations.md`.
- **Multi-row and 360° panoramas.** They need our own feature matcher. That is a late phase.
- **Re-merge from a recipe** and **Stacks.** Latent has no grouping schema yet.

## 2. The key decisions

### 2a. Where in the pipeline to merge
**Choice:** merge after *demosaic*, in **scene-linear camera RGB at unit white balance**. The merged image enters the pipeline at the `cameraRGB` seam (`RenderPipeline.swift:419-446`).
- *Demosaic* turns the sensor's one-colour-per-pixel mosaic into full RGB.
- *Scene-linear* means pixel values are proportional to real light: twice the light gives twice the value, with no tone curve applied.
- *Unit white balance* means the per-channel WB gains have been divided back out.

**Alternative:** merge the raw Bayer mosaic before demosaic.

**Why not the alternative:**
- Aligning handheld frames needs sub-pixel warps, and a warp mixes red, green and blue photosites.
- `SensorPlane` is `uint16`, which cannot hold HDR range.
- Everything after the seam (denoise, heal, lens, `colorAndTone`) already works on any rgba16Float camera-RGB texture.

**Rules for every frame:**
- Demosaic all frames with the **reference frame's as-shot multipliers**. Pass these explicitly, not `multipliers(for:)`, which would pick up that frame's WB edits. Then divide them out.
- **Crop every frame to the sensor's active area.** Today the shim never reads `left_margin`/`top_margin` (`libraw_types.h:217`), and `plan()` uses the full `rawWidth×rawHeight`. The dark optical-black margin strips would be stitched into panoramas.

### 2b. The output file: one shared "master" contract
**Choice:** a **16-bit float LinearRaw DNG**, written into the reference photo's folder as `DSC_0107-HDR.dng` or `-Pano.dng`.
- *LinearRaw* is a DNG that is already demosaiced: 3 channels per pixel.

**Alternatives:**
- A float TIFF or EXR. It isn't cataloged (`Reconcile.swift:35-42` indexes RAW only). Other apps would show our WB-neutral data as green.
- A virtual recipe re-rendered on every open. The schema has no virtual rows, Reconcile deletes rows without files, and re-rendering is slow.

**Why DNG:**
- `dng` is already indexed.
- Moves, renames, sidecars and hashing all work unchanged.
- Lightroom, ACR and darktable can open it.

**The pixel contract.** The three designs disagreed on these; this settles them:

| Field | Value |
|---|---|
| Pixel values | Camera RGB, unit WB, radiance **relative to the brightest frame** (its white = 1.0). Darker frames' highlights reach 2^span, e.g. 128 for 7 EV. |
| `BaselineExposure` | log2(e_ref / e_brightest), so the merge opens looking like the reference |
| `AsShotNeutral` / `ColorMatrix1` | Reference frame's 1/`cam_mul` and `cam_xyz`, plus `CalibrationIlluminant1 = 21` (D65) |
| `clipScale` | Stored explicitly (= 2^span) in a `latent:Merge` XMP block |
| `lensApplied` | HDR: **false**, and the lens identity is kept, so Lensfun runs once on the master. Panorama: **true**, correction baked in, and `LensModel` removed from EXIF |
| Preview | ~1600 px JPEG in IFD0, so `Thumbnailer.swift:58` works unchanged |
| Recipe | `latent:Merge` JSON: kind, options, algorithm version, each source's relative path, xxhash and capture time. **Provenance only**; Latent does not promise re-merge |

Two notes on the table:
- **Why relative to the brightest frame.** Shadows come from that frame at their native scale. (The HDR design's "subnormal" argument was wrong in detail, but the conclusion holds.)
- **Why HDR keeps lens correction for later.** Vignetting and distortion are applied exactly after a linear merge, and it avoids resampling the image twice.

**Reading the file back: use the vendored LibRaw, not a new parser.** I checked the vendored source:
- `fp_dng.cpp:464` fills `float3_image` for 3-sample float DNGs, and `expandFloats` handles 16-bit half floats.
- Deflate decoding is compiled in (`-DUSE_ZLIB`).
- Float data is converted to integers only because `LIBRAW_RAWOPTIONS_CONVERTFLOAT_TO_INT` is the default (`init_close_utils.cpp:89`). The shim can clear that flag.
- LibRaw also exposes `dng_levels.baseline_exposure` (`libraw_types.h:267`) and the raw XMP packet `xmpdata` (`:206`).

So parsing stays inside the XPC service, and the hand-written `LinearDNGReader` (about 600 lines) is dropped.

### 2c. How to align frames
- *Alignment* means finding how each frame moved relative to the reference.
- A *homography* is a 3×3 matrix mapping points in one flat image to another. It covers shift, rotation, scale and perspective, which is everything a camera turning about its lens produces.

**Choice:** Apple Vision's `VNHomographicImageRegistrationRequest` gives a **first guess only**. Our own checks decide whether to use it:
- Measure NCC (a brightness-independent similarity score) on the warped overlap.
- Reject scale changes above 2%.
- If frames moved less than 0.1 px, skip the warp.

For HDR, register **neighbour to neighbour** in exposure order and chain the results. Very dark and very bright frames share almost nothing usable (critique M3).

**Alternatives:**
- Translation-only alignment: a 1° roll moves the corners about 50 px.
- ECC refinement plus tile phase correlation: good, but a lot of code for a first release.
- Our own GPU keypoints: needed eventually for multi-row panoramas.

**Why:** Vision is almost no code and Latent already imports it (`MLKit/AIMasks.swift`). Vision gives no quality signal of its own, which is why the checks decide. A synthetic test pins its matrix direction.

### 2d. Where the code lives
- **New `MergeKit` target.** Holds the `MergeFrameSource` protocol, orchestration, exposure maths, Vision, panorama geometry and the DNG writer. It depends on PixelEngine, RawCore and ColorKit.
- **Metal kernels in `PixelEngine/Shaders/Merge*.metal`,** so there is only one metallib.
  - PSOs are built **lazily** behind a `Mutex`, because `GPUContext` is `@unchecked Sendable` with eager `let`s.
  - Each kernel needs a `kernelNames` entry and globally unique helper names.
- **Linear source support by extending `RawFile` rather than a new `SourceImage` enum.**
  - `RawFile(path:)` already opens DNGs through XPC, so the 6 construction sites and about 14 `session.file` uses stay as they are.
  - Add `CFAPattern.linearRGB` and a `LinearPlane` IOSurface (RGBA half float) next to `SensorPlane`.
- **The merge core takes `MergeFrameSource`, not `RawFile`.** Tests can feed it synthetic frames.

**Critique points I did not take:**
- **Theil–Sen exposure fitting (M1).** Reading the per-channel black levels fixes the offset. A median log ratio is enough, and tests check the offset.
- **Mipmaps for binned previews.** Rejected per M5: spans can be any 2q, not only powers of two.
- **HDR design's Laplacian blending of radiance.** Rejected per M6: it causes halos.
- **Reference-frame picker.** The reference is chosen automatically (fewest clipped plus crushed pixels).
- **The HDR plan's float TIFF output.** It would be throwaway work.

## 3. HDR pipeline

A *seam*, in panorama terms, is the boundary where one photo hands over to the next. In HDR it is the handover between exposures.

| # | Stage | Where | Data | Memory (3×24 MP / 7×45 MP) |
|---|---|---|---|---|
| 1 | Validate: same camera, size and orientation; Bayer; sort by EXIF exposure e = t·ISO/N² | CPU | metadata | ~0 |
| 2 | Binned analysis frames (span 4), divided by the multipliers | GPU, existing `demosaicBinned` | rgba16Float | 12 / 22 MB each |
| 3 | Exposure ratio per neighbouring pair: median log2 ratio on pixels unclipped in both frames, mid-tone, low-gradient. Fall back to EXIF if there are fewer than 5k samples or the result differs from EXIF by more than 1 EV | CPU, Accelerate | readback | tens of MB |
| 4 | *(Phase 6)* Align with Vision plus validation | Vision/CPU | 8-bit exposure-matched luminance | <100 MB |
| 5 | *(Phase 6)* Deghost mask. Ghosts are things that moved between frames. Compare log luminance with the reference using its 3×3 min/max, so slight edge misalignment isn't flagged. Require a whole patch to agree, then dilate and feather | GPU + MPS blur/max | r8 at ¼ resolution | 3–6 MB each |
| 6 | **Per frame, one at a time:** decode → `mergeRawClipMask` (raw ≥ 0.98 × min(white, observed max), per-channel black) → RCD → unit WB → `mergeWarp` if aligned → `mergeAccumulate` | GPU | accumulator rgba32Float (Σw·x, Σw) | **~1.4 / ~2.7 GB**, flat in frame count |
| 7 | `mergeResolve`: divide by Σw | GPU | rgba16Float | 192 / 360 MB |
| 8 | Write the DNG tile by tile; free-space check first | CPU | float16 | 144 / 270 MB file |

**Stage 6 in more detail:**
- **Weights.** w = e × (1 − smoothstep(0.80, 0.95, clip)) × (1 − ghost). One weight is shared by all three channels, so no colour shift appears at handovers.
- **Where every frame is clipped.** The darkest frame keeps a weight floor of 1e-4. Fully clipped highlights therefore fall back to it with no special case.
- **Release memory between frames.** Drop each `ImageSession` before the next frame, because its pools keep textures alive.

## 4. Panorama pipeline

Every decision is made on a **1/8-scale** copy. Only the final warp and blend run at full size.

| # | Stage | Where | Notes |
|---|---|---|---|
| 1 | Group and order by capture time; inputs can be Bayer frames **or linear HDR masters** | CPU | |
| 2 | Prep each frame: RCD → `mergeLensPrep` → unit WB → EXIF exposure normalisation | GPU | `lensCorrect` maths, but alpha 0 outside the frame (today it clamps to the edge, `LensCorrect.metal:51`) and perspective off. Saved as a float16 scratch file plus a 1/8 copy |
| 3 | Pairwise Vision homographies between neighbours, validated by NCC (≥0.6) and overlap (≥5%) | Vision/CPU | log-luminance, ~1600 px |
| 4 | Camera solve: R = K⁻¹HK, orthonormalised with SVD; one shared focal length f from EXIF × crop factor; straighten the horizon | CPU doubles | no bundle adjustment in v1 |
| 5 | Choose a projection: Perspective if ≤70° wide, otherwise Cylindrical | CPU | |
| 6 | Gain compensation, a small linear solve over overlap means | CPU | excludes clipped pixels |
| 7 | Seams: Voronoi (each canvas pixel goes to the frame whose centre is nearest) | GPU at 1/8 | |
| 8 | Multi-band blend in log(x + ε), with ε ≈ 1e-3 × clip | GPU, 2048² tiles with a 128 px apron | |
| 9 | Auto Crop: largest rectangle inside the alpha mask, saved as the **EditStack crop** so it can be undone | CPU | |
| 10 | Write the DNG with `lensApplied = true` | CPU | |

**Terms used in the table:**
- **Projection:** how a sphere of viewing directions is flattened onto the canvas. Cylindrical wraps around horizontally, like a label on a can.
- **K** is the camera's focal-length matrix, and **R** is the camera's rotation.
- **Multi-band blend:** a *Laplacian pyramid* splits an image into coarse-to-fine detail layers. Coarse layers are blended over wide areas and fine detail over narrow ones, so seams disappear without ghosting.
- **Tile and apron:** the canvas is processed in squares (tiles), each with an overlapping border (the apron) so neighbouring tiles agree. Coarse pyramid levels are computed once globally.

**Output size: downsample instead of failing (Harman, 2026-09-15).** A panorama is never refused for being too big. If the full-resolution panorama would exceed what this Mac can edit, Latent works out the largest size that fits, tells the user, and merges at that size once they agree.

1. **The size is known before the slow part.** Stages 1–6 run on 1/8-scale copies, so the full-resolution canvas `W × H` is known in seconds. The canvas is trimmed to the area any photo covers (empty corners outside every frame are dropped), not to the Auto Crop rectangle. Auto Crop stays an undoable crop edit.
2. **Scale factor** `s = min(1, L / max(W, H), sqrt(P / (W × H)))`. Output dimensions are `floor(W × s) × floor(H × s)`.
   - `L` is the GPU's largest texture side, read from the Metal device (16,384 px on Apple Silicon), not hard-coded.
   - `P` is the pixel budget for *editing* the result on this Mac: `0.4 × recommendedMaxWorkingSetSize / bytesPerEditPixel`. `bytesPerEditPixel` is measured in Phase 2 from the real number of full-size textures an edit keeps (about 7 × 8 bytes). This comes to roughly 75 MP on a 16 GB Mac, about 150 MP on 32 GB and about 30 MP on 8 GB. It replaces the old fixed 64 MP cap.
   - `s` is never above 1: Latent never upsamples.
3. **Downsample cleanly and cheaply.** When `s ≤ ½`, each frame is demosaiced with the existing binned demosaic at the largest span `k` where `1/k ≥ s`. That still gives at least the target resolution, with less noise, and uses far less memory and time. The warp then covers the remaining ≤ 2× reduction with an area-averaging (box/Lanczos) sample. Feature matching and the camera solve don't change, because they already run at 1/8.
4. **Warning, confirmed every time.** For example: *"This panorama would be 58,210 × 5,940 px (346 MP). The largest this Mac can edit is 16,384 px on a side, so the photos will be reduced to 28% (16,384 × 1,672 px, 27 MP). [Cancel] [Merge at 28%]"*. The message names the limit that applies (texture side or memory). The preview sheet shows the final size live as options change.
5. **HDR Panorama** uses the same rule. When `s ≤ ½`, each position's HDR is also merged at the binned size.
6. **Tests:** a pure `PanoramaOutputSizer` covering each limit, rounding, never-upscale, the span choice at the boundaries, and the 20-frame case (20 × 4000 px-wide portrait frames with 30% overlap gives a canvas about 56,000 px wide, so s ≈ 0.29).

## 5. How the result enters the catalog and edit pipeline

**Commit order:**
1. Plan a unique name using the §5.7 rules: the file, its sidecar and a catalog row must all be free.
2. Write the sidecar containing `latent:Merge`. `XMPSidecar.render/parse` (`XMPSidecar.swift:77-110`) must learn this block, because unknown fields are dropped on rewrite.
3. Write the DNG with `SafeFileWriter.begin/commit`. If commit throws `DestinationExists`, delete the sidecar and plan the name again.
4. Run `Library.refresh()` and select the result.

**Opening the file:**
- **RawCore.** The shim returns `float3_image` for float DNGs. The XPC service converts it to a half-float `LinearPlane` IOSurface, which the host size-checks like `SensorPlane.swift:40-45`.
- **Session.** `ImageSession` accepts either plane type (`:198-205`).
- **Render.** `renderStages` stops rejecting non-Bayer input for `.linearRGB` sources (`:391`), and:
  - `linearUpload` multiplies the pixels by `multipliers(for:)`, so the WB sliders keep working;
  - `linearBinned` is a box downsample for any span;
  - `StageKey` gains the source kind.
- **Changes for HDR values above 1.0:**
  - **Highlight reconstruction:** `clipLevel = multipliers × clipScale` (`RenderPipeline.swift:923`). Without it, bright colours go grey.
  - **Lensfun:** matching (`ImageSession.swift:207-227`) checks `lensApplied` first, so copied EXIF can't cause a second correction.
  - **AI denoise:** hidden for linear sources. It clamps to [0, 1] and fades pixels between 0.85 and 1.0 (`AIDenoiser.swift:154,173`).
- **Thumbnails of edited merges** work automatically, because `EditedThumbnailRenderer.swift:19-20` still goes `RawFile` → `ImageSession`.

**Jobs:**
- Merges pass through the same one-GPU-job-at-a-time gate as exports (`ExportQueue.swift:133`).
- Each merge registers with `OutputJobs` and holds `ExportActivity`.
- Cancellation is checked between frames and between tiles.
- Scratch files are deleted on cancel or quit.

## 6. Memory and performance budget (16 GB M1 Pro)

| Job | GPU peak | Other |
|---|---|---|
| HDR 3×24 MP | ~1.4 GB | DNG 144 MB |
| HDR 7×45 MP | ~2.7 GB | DNG 270 MB |
| Pano 3×24 MP → 58 MP | ~0.5–0.7 GB | scratch 0.6 GB |
| Pano at the edit budget (~75 MP on 16 GB) | ~0.8 GB merge | DNG ~450 MB |
| **Editing** a 58–64 MP master | **~3–3.7 GB** (6–8 full-frame intermediates; export is not tiled, `ExportPlan.swift:37`) | XPC decode ~770 MB transient (float32) |

**Rules:**
- Release the viewport and Survey pools before a merge.
- `.critical` memory pressure cancels the merge with a clear message.
- On Macs where `MemoryPolicy.isConstrained` is true (8 GB), cap HDR at 5 frames. Panoramas are sized by the downsampling rule in §4, never refused.
- Check free disk space against 2× the output size.

**Performance targets** (not measured; `latent-cli merge --timings` will measure them):
- 3×24 MP tripod HDR under 10 s.
- 3-frame panorama under 30 s.

## 7. Testing plan

**Synthetic (XCTest, no fixtures):**
1. **Exposure:** known scene rendered at e = ¼, 1, 4, with EXIF saying 1/60 where the truth is 1/64, plus noise and black level 600. Ratios within 0.02 EV.
2. **Merge accuracy:** error under 1% wherever any frame is unclipped. A 10-stop ramp has no visible steps. A disc clipped in every frame equals the darkest frame. No NaN or Inf values.
3. **Per-channel black:** unequal `cblack` values produce no shadow colour cast.
4. **Alignment:** a known homography is recovered to under 0.3 px at the corners. A tripod set comes out bit-identical, with no warp. A Vision matrix-convention test.
5. **Deghost:** a moving square is fully masked. A static noisy scene with sharp edges flags under 0.1% of pixels.
6. **Panorama:**
   - Projection round trip within 1e-3 px.
   - Alpha exactly 0 outside frames.
   - **512 px and 4096 px tiles agree within 1e-4.**
   - Auto Crop finds known rectangles.
7. **DNG:** write, then read through `RawFile`, gives identical pixels, `cam_mul`, matrix, `baseline_exposure` and XMP. The `latent:Merge` block survives a sidecar rewrite, a rename and a move.
8. **Memory:** peak `currentAllocatedSize` stays within budget for 45 MP-sized synthetic frames.

**Golden tests:**
- **Seam round trip, the most important test.** Take the D750 NEF's camera RGB, divide by its multipliers, and inject it as a `LinearPlane`. It must match the existing goldens within the current tolerances (mean 0.0005, p99.9 0.005).
- Merged fixtures rendered through `ExportPlan` as a `Recipe`: an overview plus a 192 px window on a handover or seam.

**Real brackets and panoramas:**
- CC0 sets: tripod brackets, handheld brackets, brackets with moving people, a 3–6 frame panorama, and a 3×3 HDR panorama. Add them to `scripts/fetch_test_assets.sh` with SHA checks.
- Run `dng_validate` by hand when the writer changes.
- Compare against Lightroom by eye only.

## 8. Phased build plan

**⇉** marks work that can run as parallel agents in separate worktrees because the files don't overlap.

| # | Phase (each ends shippable or merged) | Size | Files / targets | Parallel |
|---|---|---|---|---|
| 0a | **DNG spike:** hand-write a float16 LinearRaw DNG; confirm LibRaw `float3_image`, `cam_mul`, matrix, baseline exposure, XMP; CGImageSource metadata | 2–3 d | scratch only | ⇉ with 0b |
| 0b | **Vision spike:** real brackets and 30%-overlap pairs; matrix convention | 2–3 d | scratch only | ⇉ with 0a |
| 1 | **RawCore:** margins/active area, per-channel black, float plane, `LinearPlane`, `.linearRGB`, XPC wire | 1 wk | `clibraw_shim.cpp/.h`, `RawFile.swift`, `RawDecoderXPC.swift`, `LinearPlane.swift` | ⇉ with 5a |
| 2 | **Linear source seam:** `linearUpload`/`linearBinned`, `StageKey`, `clipScale`, `lensApplied`, AI denoise gate, lazy-PSO registry, round-trip golden | 2–3 wk | `ImageSession.swift`, `RenderPipeline.swift`, `GPUContext.swift`, `Shaders/LinearSource.metal`, tests | ⇉ with 3 (after 1) |
| 3 | **MergeKit + DNG writer** (tags, tiles, preview, XMP) via `SafeFileWriter` | 1–2 wk | `Package.swift`, `Sources/MergeKit/DNG/*`, `Tests/MergeKitTests` | ⇉ with 2 |
| 4 | **Tripod HDR core + `latent-cli merge-hdr`** | 2–3 wk | `MergeKit/HDR/*`, `Shaders/MergeHDR.metal`, `latent-cli/main.swift` | after 2+3 |
| 5a | **Catalog:** `latent:Merge` sidecar block + tests | 3 d | `XMPSidecar.swift`, CatalogTests | ⇉ from phase 1 on |
| 5b | **App: Photo › Photo Merge › HDR… (⌃H), tripod only.** Small options sheet, job, naming/commit, docs | 2 wk | `BareKeys.swift`, `AppMenus.swift`, `ContentView.swift`, `MergeJob.swift`, `LatentApp.swift`, `docs/wiki/*` | after 4 |
| 6a | **Auto Align:** Vision chain, validation, `mergeWarp` | 1.5 wk | `MergeKit/Align/*`, `Shaders/MergeWarp.metal` | ⇉ with 6b |
| 6b | **Deghost** None/Low/Med/High + overlay (not red-only) | 1.5 wk | `MergeKit/Deghost/*`, `Shaders/MergeDeghost.metal` | ⇉ with 6a |
| 7 | Preview sheet on cached binned frames, Auto Settings, headless ⇧⌃H, Undo to Trash | 2 wk | app + `MergeKit/Preview` | — |
| 8a | **Panorama geometry:** camera solve, projections, CPU twin, gains, crop | 2 wk | `MergeKit/Pano/Geometry/*` | ⇉ with 8b (agree the `PanoCameras` struct first) |
| 8b | **Panorama GPU:** `mergeLensPrep`, warp, Voronoi, tiled blend, scratch files | 2–3 wk | `MergeKit/Pano/Blend/*`, `Shaders/MergePano.metal` | ⇉ with 8a |
| 8c | Panorama CLI + app (⌃M), `PanoramaOutputSizer` + downsample warning | 1 wk | CLI, app | after 8a+8b |
| 9 | HDR Panorama (**experimental**): bracket grouping, per-position HDR → panorama. No real HDR panorama test set exists (none are freely licensed and Harman hasn't shot one), so tests build synthetic ones: overlapping windows cut from the real Ihrke and Empa brackets, warped by known camera rotations. The menu item and docs say "Experimental" until a real set has been checked. | 1–2 wk | `MergeKit/HDRPano/*`, app | — |
| 10 | Later: own FAST/BRIEF matcher + bundle adjustment (multi-row/360), spherical projection, graph-cut seams, tiled editor/export, deflate, Find Bracket Sets, stacks | large | — | — |

**Timeline:** first user-visible release (tripod HDR) at the end of phase 5b, about 8–11 weeks. That is realistic for step-by-step work; the earlier "preliminary step" framing undersold phases 1–2.

**Docs work in 5b:**
- Regenerate `Keyboard-Shortcuts.md`, or `ShortcutsPageTests` fails.
- Update `Limitations.md` ("merges write DNG; export doesn't").
- Update DESIGN §5.5, §9.1 and §14.

## 9. Risks and open questions for Harman

**Decisions (answered by Harman, 2026-09-15):**
1. Ship tripod-only HDR first (phase 5b), with a warning if the frames look misaligned: **yes**.
2. The dialog tells users that develop edits on the source photos are ignored: **yes**.
3. Test fixtures: **find free-to-use CC0 sets**.
4. Build order: **agreed**.
5. Oversized panoramas: **downsample to the largest size that fits, after the user agrees** (§4).

Still using my defaults unless Harman says otherwise:
- Block frames whose camera orientation differs, and copy the reference frame's `user_rotation`.
- Merge exactly the selected photos.
- Keep the full reference frame for HDR, with no auto-crop.
- Cap HDR at 5 frames on 8 GB Macs.

**Risks:**
- **Vision** may be inaccurate at 25–30% overlap, and can change between OS releases. Mitigation: validation, the 0b spike, and a phase-10 matcher.
- **Chained homographies drift** over many frames. Mitigation: cap panorama v1 at 6 frames.
- **The margin bug likely affects ordinary renders today** (full `rawWidth` includes optical black). Fixing it globally may change goldens for some cameras; fix it only in the merge path first.
- **Lightroom and ACR compatibility** of our DNG is unproven until `dng_validate` and a manual open pass.
- **Editing masters above the pixel budget** needs a tiled editor and export. Until then, panoramas are downsampled to fit (§4).
- **Timing and memory figures are estimates.** Phase 4's CLI timings are the first real numbers.