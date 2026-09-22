# Retouch: sensor dust, portrait touch-up and subject-selection models

The plan for three Develop features, written 21 September 2026 from a design
pass over the code as it stood at v0.9.0 (commit 7e4fed9) and refined by
independent reviews of each part. §0 records what has been measured since; it
overrides anything below that disagrees with it. The Swift contracts every task
builds against are in the appendix.

## 0. Wave 0 findings (measured, 21 September 2026)

**Status (21 September 2026):** Waves 0–3 have landed on `main`: the contracts, the BiRefNet-lite package and manifests, the engine (registry, importer, segmenter, blob and dust detectors, heal cache, touch-up kernel, face landmarks and regions), the app (Settings › AI › Models, the Add and Model menus, the Sensor Dust and Touch-up panels and tools, Photo › Remove Dust…, the `SelectionJobQueue` jobs), the conversion scripts for the catalogue and the docs. Where the code differs from the text below, the code and DESIGN.md are right: the bundled BiRefNet-lite package is 103 MB, not ~89; the models list shows Apple Vision as a built-in row; Find Faces after a pasted touch-up also runs for the image shown in Loupe, Compare and Survey (and Compare's Select pane and Survey's focused pane find faces on screen at once); the heal list's three caps are `HealPatch.maximumDustCount`, `maximumBlemishCount` and `TouchUp.maximumFaces`; `convert_sam2.py`'s hashes for Tiny, Base+ and Large are still `<pin me>`.

A five-dimension review then found 32 faults, of which 31 are fixed on `main` with a test each; the rest of this file still describes the plan, so where it differs the code is right. The fixes that change what the text below says: a batch job commits only to the catalog it started from and gives up if the folder changed; Find Spots renders its analysis on the main thread, as red-eye does, and only the detection runs off it; the touch-up and model masks follow undo, history and snapshots; clicks and rings map between the corrected view and the raw sensor grid (`rawNormalized`/`outputNormalized`); the importer refuses symbolic links, bounds an archive's entries and size, accepts a one-package `.mlpackage` whose manifest sits at its own root (`scripts/latent_manifest.py --inside`), and sweeps abandoned half-copies at launch as well as before an import; dust maps are checked as they are read; an export note tells an empty click-to-select mask from a substituted one; and Settings › AI is as tall as its list needs. The Heal and Red-Eye tools still mix the two grids the same way the new tools did, which is older than this work and not fixed here.

- **BiRefNet-lite converts and is fast enough.** `ZhengPeng7/BiRefNet_lite`
  (MIT) at revision `aa62cd87eafb9cc43056d08ef3615a14628b831d`, safetensors
  SHA-256 `4417d897…0815`, converted with coremltools 9.0 / torch 2.14 to an
  fp16 ML Program for macOS 15: 103.2 MB package (`weight.bin` 100,677,296
  bytes = 96.0 MiB, under GitHub's 100 MiB file limit, about 12 MB of it folded
  Swin attention masks and sampling grids). The deformable convolutions are
  rewritten as `grid_sample` taps plus 1×1 convolutions (max difference from
  torchvision 2e-4); the traced graph needed the Swin block, attention, patch
  embed/merge, decoder and ASPP forward functions rewritten for coremltools 9,
  with the masks and grids captured as constants. Against PyTorch fp32 on a
  real photo: **GPU path 468 ms median on an M4, IoU@0.5 0.9966**; CPU-only
  1,076 ms, IoU 0.982. `computeUnits = .all` does not hang but the ANE compiler
  spends 103 s and every prediction then fails with "Error in building plan",
  so the manifest pins `cpuAndGPU`. Orientation matters: the model must see an
  upright image. The U²-Net fallback was not needed. Spike files:
  `~/latent-wt/spikes/birefnet/{convert.py,NOTES.md,bench.py}`.
- **Portrait test asset chosen:** NASA's official portrait of astronaut
  candidate Zena Cardman (2017, NASA/Bill Stafford, photo JSC2017-E-116316),
  public domain as a US government work (`{{PD-USGov-NASA}}` on Wikimedia
  Commons), 4800 × 6000 JPEG, SHA-256 `9364c55a…7044`. Apple Vision finds the
  face (confidence 1.0) with both eyes, outer and inner lips. Fetched by
  `scripts/fetch_test_assets.sh --portrait` into `TestAssets/portrait/`.
- **Owner's decisions:** bundle SAM 2.1 Small and BiRefNet-lite, everything
  else import-only with a source link; dust is found both automatically and
  from a reference photo's map; Touch-up is a new Develop module with skin
  smoothing, blemish removal, teeth whitening and eyes, per face; Auto Adjust
  (⌘U) does not run Find Spots; no dust test photos exist yet, so the detector
  is tested on synthetic dust and checked on real photos when some turn up.

## 1. Overview

Three Develop features built on five shared pieces: a model registry (MLKit), one Vision face pass (MLKit), one classical blob detector (PixelEngine), two automatic heal lists rendered by the existing heal kernel (PixelEngine), and one Library batch-write API (Catalog). No network entitlement, no notarisation, no history rewrite. Sidecars stay schema 1: every new module is omitted when neutral, so untouched sidecars stay byte-identical and the 0.9.0 beta ignores what it does not know. British spelling and plain words in every user-facing string. Dependencies stay MLKit → PixelEngine (never the reverse); latent-app depends on both. Detection that needs no model (dust) lives in PixelEngine so PixelEngineTests drive it; anything touching Core ML or Vision lives in MLKit. Stage numbers are DESIGN.md §8.1's as numbered today (5 spot heal, 6 red-eye, 7 lens, 8–15 `colorAndTone`, 16 presence, 17 sharpening).

## 2. Shared contracts (exact Swift in the contracts list)

**A. Model registry (MLKit).** `ModelManifest` (Codable; one `<id>.model.json` beside its packages), `ModelRef`, `PackageHash`, `ModelEntry`, `LoadedModel`, `ModelRegistry`, `ModelImporter`, and a manifest-aware `CoreMLStore.load(_:of:at:computeUnits:)`. Decisions:

- `packages[].sha256` hashes the package *contents*: SHA-256 over `Manifest.json`, `Data/com.apple.CoreML/model.mlmodel`, `Data/com.apple.CoreML/weights/weight.bin`, in that order, each fed as relative-path bytes + `0x00` + file bytes; a package holding any other regular file is refused. `scripts/latent_manifest.py` and `PackageHash.sha256(ofPackageAt:)` compute it identically. It catches corruption and keys the compile cache; the sandbox, not the hash, is the security boundary (the manifest arrives from the same untrusted folder). Catalogue rows carry `sha256: nil`; the importer refuses a nil hash.
- Compile cache key `"<id>-<package.name>-<sha16>.mlmodelc"`; each load deletes older `"<id>-<package.name>-*"` entries. A CI test hashes every bundled package against its manifest.
- `ModelRegistry` is a `final class: @unchecked Sendable` with one `OSAllocatedUnfairLock` guarding the listing cache and the loaded-model dictionary (static mutable state in an enum is a Swift 6 error; `SharedModel` is generic over one type). `LoadedModel` is a typed enum with accessors `subject(id:)`, `prompted(id:)`, `semantic(id:)`. AIDenoiser keeps its own loading.
- Compute units: rank cpuOnly 0, cpuAndGPU 1, cpuAndNeuralEngine 1, all 2; `effective = lowest rank of {preference, manifest.computeUnits ?? .all, status == .bundled ? .all : .cpuAndGPU}`. Bundled manifests leave `computeUnits` nil (today's behaviour); BiRefNet's says `cpuAndGPU`.
- `id` must match `^[a-z0-9][a-z0-9.-]{0,63}$`; `sourceURL` and `licence.url` must be http(s); both checked in `init(from:)`.
- Resolution is by id only: a different installed version runs and the mask row reads "made with version 1, now version 2". A string `ModelRef` cannot parse counts as missing: the kind's default runs and is reported (`substitutedModel`) on screen and in export.
- `AIMaskKind.modelVersion` becomes registry-driven: `.subject` → `defaultSubject().manifest.modelVersion`; classes → `segformer-b2-ade20k-512@1` when installed, else `latent.skyHeuristic@1` for sky (`ExportWorkerTests.swift:126` follows).
- Bundled manifests and `ModelCatalog.json` live in `Sources/MLKit/Resources/Models/` (found through `Bundle.latentResources` in the app and under `swift test`). Imported models live in `externalModelsDirectory/<id>/`; the flat legacy layout is searched only for `NAFNet_SIDD_width64`.
- The dormant download path goes (`OptionalModel`, `ModelDownloader`, `EditorModel.downloadHighQualityModel/removeHighQualityModel`, the `modelDownload*`/`highQualityModelInstalled` fields); `entriesAreSafe`/`listEntries`/`unzip` move into `ModelImporter`. The denoise picker stays hidden (recording w32 while running w64 would contradict the rule that the edit names its model); `ContentView.swift:1699` comment updated. The catalogue lists subject and prompted kinds only.

**B. FaceLandmarker (MLKit).** One `VNDetectFaceLandmarksRequest` (revision 3, 76 points) on the upright image (`UprightImage.rotated`, moved from `RedEyeDetector`), returning `[FaceObservation]` in normalised coordinates of the render's grid (top-left origin), left to right. `seeds:` are sensor-normalised rectangles; the function enlarges each by 20 %, converts to Vision's upright bottom-left frame itself and refits with `inputFaceObservations`; `refit` returns nil per seed that failed, never a silent drop. `RedEyeDetector.eyeCandidates` becomes a consumer; `RedEyeDetectorTests` stay unchanged.

**C. BlobDetector (PixelEngine; Swift + Accelerate, no Metal).** Input is a `Map` (Float32: log2 luminance, or a* for `.reddish`, with an optional per-pixel weight such as a skin mask). Noise: 1.4826 × MAD per 64² tile of `D − G₁∗D`, bilinear between tiles. Scales `s ∈ {r_lo, √(r_lo·r_hi), r_hi}`, each DoG `G_{3s}∗D − G_s∗D` built on a **pyramid**: downsample by 2 per octave (vImage) until s/2^k ≤ 4 px, blur there, upsample the response bilinearly for peak picking (a σ = 60 px direct Gaussian on a 6 MP map costs seconds). Candidates: 3×3 and across-scale maxima with `R ≥ max(minimumContrast, contrastSigma·σ_local)`; region = flood fill of `R > 0.5·peak` within 2s; keep when `r_eq = √(A/π) ∈ radiusRange`, `4πA/P² ≥ minimumCircularity`, centre below the annulus `[1.5r, 3r]` mean by ≥ threshold, annulus residual std ≤ `smoothSurround·σ_local`, mean |∇(G_{2r}∗D)| over the annulus ≤ `maximumSurroundGradient`, and centre weight ≥ 0.5 when a weight map is given; `score = contrast/threshold × circularity × weight`; merge closer than `1.5(r₁+r₂)`; cap `maximumCount`, best first. One scale at a time into two reused buffers; only candidate lists persist; ≤ 400 ms for a 24 MP-equivalent map at the Large band (tested).

**D. Automatic heal lists (PixelEngine).** `EditParameters.dust: [HealPatch]` (cap 200, group `.dust` "Sensor Dust") and `EditParameters.touchUp.blemishes` (cap 64, inside group `.touchUp`). Stage 5 renders `parameters.allHealPatches = dust + touchUp.activeBlemishes + heals`, in that order, through the unchanged kernels; `HealStage.encode` loses its `prefix(HealPatch.maximumCount)` (each list is capped on decode; the UI guards stay). The four tile-planning sites (`EditorModel+Rendering.swift:58/188`, `EditorModel+Magnifier.swift:111/135`) use `allHealPatches` of the parameters each uses today, so Before shows no dust. `HealPatch` and `RedEyeSpot` become `Hashable` (heal cache key). `ActiveAreaMigration.geometryGroups` adds `.dust` when `modules.dust != nil` and `.touchUp` when the module has faces or blemishes; `migratingGeometry` maps dust and blemishes as heals, face boxes with `map.point` on the origin and `size × map.scale`. `EditHistory.describeChange` appends "Sensor Dust" and "Touch-up". `RenderOutput` gains `spotVisualisation` and `touchUpOverlay`, both in its `==`.

**E. Library batch write (Catalog).** `Library.setEdits(_:expecting:undoName:)` writes precomputed results for explicit records in ONE undo group (`fileFreshUndo` is internal to Catalog; `transformSelectedEdits` files a group per call over the whole selection), called inside `library.perform` so quitting waits, skipping and naming any image no longer in `images` or whose stored JSON differs from what the job read. `Library.batchTargets(onlyPrimary:)` makes `metadataTargets` public.

## 3. Sidecar JSON

```json
{"schema":1,"process":"1.0","frame":"active-area","modules":{
  "locals":[{"name":"Subject 1","shape":{"ai":{"kind":"subject","modelVersion":"birefnet-lite@1"}}}],
  "dust":[{"id":"7A1C…","target":[0.412,0.087],"source":[0.418,0.087],"radius":0.0021,"feather":0.5,"mode":"heal"}],
  "touchup":{"faces":[{"id":"…","boundingBox":[0.41,0.18,0.12,0.17],"enabled":true}],
             "skinSmoothing":45,"teethWhitening":30,"eyes":20,"blemishRemoval":true,
             "blemishes":[{"id":"…","target":[0.452,0.271],"source":[0.458,0.269],"radius":0.0018,"feather":0.5,"mode":"heal"}],
             "modelVersion":"vision.faceLandmarks.3"},
  "heal":[{"id":"…","target":[0.50,0.55],"source":[0.58,0.47],"radius":0.03,"feather":0.35,"mode":"clone"}]}}
```

Mask JSON keeps its shape; only the `modelVersion` string changes form (a prompted mask writes e.g. `"sam2.1-large@1"`). The 0.9.0 beta never reads it (`AIMasks.swift:84-103`, `ExportWorker.swift:258-271`), so it renders subject with Vision and prompted with SAM Small, and ignores `dust` and `touchup`. Legacy literals (`sam2.1-small.1`, `vision.foregroundInstance.1`, `segformer-b2-ade20k-512.1`, `latent.skyHeuristic.1`) are parsed, never rewritten on load. `dust`, `touchup` and `frame` are written only when non-empty/non-neutral. Face boxes are on the **raw** sensor grid (§7); dust and blemishes are raw-grid heal patches; `touchup` decodes leniently (every key optional; sliders clamped, faces cut to 16, blemishes to 64 and sanitised).

## 4. Pipeline placement

- Stage 5: list = dust, then touch-up blemishes, then the user's patches; a user patch over a dust spot reads the dust-healed image.
- Stages 3–5: heal cache (§6); on a hit the three stages are skipped.
- **New 16 Touch-up**: after 15 (output transform), before presence; display-referred; `touchUpApply` via `LazyKernel.touchUpApply`; gated by `parameters.touchUp.wantsMasks && session.touchUpMaskTexture(enabled:) != nil`.
- 17 Presence, 18 Sharpening: renumbered (comments at `RenderPipeline.swift:579/589`, DESIGN, wiki).
- Display pass after 18: `dustVisualise`, viewport only, driven by `RenderOutput.spotVisualisation`; never in exports, like `maskOverlay`.

Touch-up masks are sampled by output position like local masks (`ColorPipeline.metal:396`), so they are built on the output grid.

## 5. Subject-selection models

**Bundle.** BiRefNet general-lite (`birefnet-lite`, MIT, ~89 MB, 1024²) after the Phase-0 spike (`scripts/convert_birefnet.py --variant lite`: pinned revision, SHA-256 of the safetensors, `DeformableConv2d` rewritten with `grid_sample`, fp16 ML Program, macOS 15). Exit: loads with `.cpuAndGPU`; IoU ≥ 0.97 against PyTorch **measured on the GPU path** (and on CPU; if only CPU passes, the manifest pins `cpuOnly` and the time budget is restated, or the fallback is taken); ≤ 1.5 s per 1024² on an M1 GPU; `weight.bin` < 95 MB (GitHub's per-file limit); first compile + load < 20 s on an 8 GB M1; two runs IoU ≥ 0.99. Fallback: U²-Net full (`u2net`, Apache-2.0, `convert_u2net.py`) with `refine: guided`. Converted once; the package is a permanent git blob.

**Registry, importer, segmenter.** As contract A. `ModelImporter` accepts a folder, `.mlpackage` or `.zip`; a zip is first copied with `FileManager` into the container's temporary directory (the open-panel grant belongs to the app process, not to a spawned `ditto`), listed with `zipinfo`, checked with `entriesAreSafe`, unpacked with `ditto` into a staging folder; then validation (exactly one `*.model.json`, id pattern, known kind, not bundled or built-in, every `packages[].name` present and no stray files, hashes match, a semantic kind has its labels file), copy to `external/<id>/` (replacing a previous import), a compile check one package at a time with `.cpuAndGPU` off the main actor with feature names compared (SAM decoder aliases allowed); any failure deletes the copy and throws a plain sentence ("The weights don't match the checksum in the manifest, so the model was not added."). `SubjectSegmenter.segment(_:)`: stretch to `inputSize²`, one prediction, `(1,1,H,W)` or `(1,H,W)` output, sigmoid when the manifest says so, 8-bit at native size; `GuidedMaskRefiner` (CPU box sums, radius 8, ε 1e-3, guide = the analysis render's luminance) only when `refine == .guided`. `AIMaskGenerator.generate(kind:modelVersion:from:)` dispatches `.subject` on `ModelRef(stored:)` → `registry.installed(ref)` → SubjectSegmenter / Vision (`vision.foregroundInstance`) / missing → Vision with `Result.substitutedModel = displayName`. `SegmentationModel` loads through the registry, labels from the model's folder; `SAM2Models.load(entry:)` takes the three packages by role.

**Editor.** `promptSessions[id]`, `promptEncoding[id]`, `promptStatus[id]` replace `sam2Session/sam2Encoding/sam2Status` (reset in `closeImage` and the failed-open path). `promptClick` finds the session by the selected local's stored id; new masks use `defaultSubject()/defaultPrompted()`; `rerunMask(at:with:)` rewrites `modelVersion`, clears the bitmap and regenerates (an ordinary parameter change: undo and history cover it). `regenerateMissingAIMasks` builds one session per distinct prompted id. Survey panes and the second-display Loupe regenerate on open as today through the shared loaded model (Limitations: ~1.5 s per pane for BiRefNet).

**Export reporting.** `regenerateMasks` returns `(count, substituted: [String])`; `Rendered`, `Outcome` and `RenderedImage` carry `maskSubstitutions`; `Rendered.finished` forwards it; `renderForScreen` logs and drops it. `ExportQueue.notes` shows under the failures and in the summary ("· 2 with substituted masks"); `SheetImages` collects `RenderedImage.maskSubstitutions` per photo, and Print and Contact Sheet add a second sentence in the `unrenderedMessage` style ("2 photos used Apple Vision because BiRefNet General is not installed"). A prompted mask whose model is missing falls back to the bundled SAM Small; with none, the local masks nothing and is reported — and reported as such: when nothing stood in, the note reads "… has an empty click-to-select mask because SAM 2.1 Small could not be loaded" (or "… is not installed and no click-to-select model is"), because the default model cannot stand in for itself.

**Settings › AI › Models** (`ModelSettingsView.swift`, in `Preferences.aiTab` above the compute picker). Caption: "Latent never downloads anything. Get… opens a model's page in your browser; convert it with the script named there, then choose Add Model…". A `List` of row views (not a `Table`, which collapses in a grouped `Form` and exposes cells, not rows), each `.accessibilityElement(children: .combine)` labelled by `SpokenText.model(...)` → "BiRefNet Lite, subject, MIT licence, 89 megabytes, bundled, default". Row: name and purpose; For (Subject / Click to select / Classes); Licence ("Research use only" in orange when `commercialUse == false`); size; status (Built in / Bundled / Installed / Not installed); a `Link` on every row ("Source page for BiRefNet Lite, opens in your browser"); actions Use (default marked), Get… (opens `sourceURL`), Remove (installed only, confirms; a removed default falls back, and the caption says so). Footer: Add Model… (NSOpenPanel: folders, `.mlpackage`, `.zip`; progress sheet "Checking BiRefNet General…"; "Added BiRefNet General (446 MB)"), Reveal in Finder. Preferences `latent.subjectModel` (default `birefnet-lite`) and `latent.promptedModel` (`sam2.1-small`) are consulted only for a **new** mask.

**Develop.** Add menu (`LocalAdjustmentsPanel.swift:13`): `Menu("Subject")` listing installed subject entries (default first, checkmarked), divider, "More models…" (`openSettings`); `Menu("Click to Select")` likewise; Select by Class unchanged. Per-mask row: "Subject · BiRefNet Lite" / "SAM 2.1 Large · 3 points · <status>", a `Menu("Model")` of the other installed models of that kind → `rerunMask`; missing model: "BiRefNet General is not installed — shown with Apple Vision instead." with Get… and Add Model… (VoiceOver reads the sentence). Develop › Masks gains New Subject Mask (`.addMask(.subject)`) and New Click to Select (`.addMask(.prompt)`), no keys. Status: "Generating subject mask with BiRefNet Lite…", "Subject mask (BiRefNet Lite): 420 ms on device, 31% of the frame".

**Catalogue rows**: SAM 2.1 Tiny/Base+/Large (Apache-2.0; `convert_sam2.py --size`), BiRefNet General and Portrait (MIT), U²-Net and U²-Net Small (Apache-2.0), MODNet (Apache-2.0, portraits), IS-Net (Apache-2.0 code, DIS5K research-only → `commercialUse: false`). Excluded: RMBG-1.4/2.0, BEN2, ViTMatte. The bundled one of BiRefNet-lite/U²-Net leaves the catalogue.

## 6. Sensor dust

**Analysis.** `DustDetector.analyse`: `pipeline.renderCameraRGB(session, scale: .binned(quads: 1), parameters:)` inside `withTexturePool(.analysis)`, released after readback. That call returns straight after the demosaic/binning seam (`RenderPipeline.swift:503-509`), so the map is **un-denoised** binned camera RGB with white balance; only WB and demosaic of the parameters matter, σ_local (MAD) is the only noise model, and the sensitivity mapping is calibrated on synthetic scenes with realistic ISO noise. Not `.sceneLinear`, which applies the matrix, exposure and locals and would fake dips under a darkening local. Luminance `0.25R + 0.5G + 0.25B` → `log2(max(L, 1e-4))`, converted row by row from the Float16 readback, which is then freed (peak ≈ 72 MB at 24 MP, pinned by a buffer-counting test). `binSpan = 2`; map pixel → normalised `((x + 0.5)·2/rawWidth, (y + 0.5)·2/rawHeight)` normalised by `summary.rawWidth/rawHeight` as `HealStage` does.

**Bands and parameters.** Small 4…8, Medium 6…16, Large 12…40 sensor px (overlapping); `expectedRadius = 0.75 / (N·p)` with `p = 36 mm / max(cropFactor, 1) / rawWidth`, clamped 2…40, nil without aperture or crop factor; narrowing `[max(lo, 0.5r), min(hi, 2.5r)]` clamped to ≥ 2 map px (a 2 px blob need not be found). Sensitivity s: `contrastSigma = 6 − 4s/100`, `minimumContrast = 0.08 − 0.06s/100` stops, `minimumCircularity = 0.65 − 0.15s/100`, `smoothSurround = 2.5 + s/100`, `maximumSurroundGradient = 0.01`. Result: `HealPatch(target, source, radius: (1.5·r_eq·2 + 2)/shortSide, feather: 0.5, mode: .heal)`, best first, cap 200; blobs centred inside an existing dust, blemish or heal target are dropped.

**Source placement** (`DustSourcePlacer`): 8 directions at 2.75r, then 3.5r, 4.5r; reject when the source disc leaves the sensor or `distance(source, other) < 1.5·r_source + r_other` for any detected spot or existing patch target (the heal field's σ = r/2 still leaks from a dip within ~1.5r); among survivors the lowest mean |∇(G_r∗D)| over the disc, ties by the largest margin; no survivor → the spot is dropped. Click-to-add without an analysis uses the gradient-free rule.

**Heal cache** (`ImageSession`): `HealKey { stageKey, aiDenoise, aiDenoiseModel, denoiseLuminance, denoiseColor, dust, blemishes, heals, redEyes }`; `renderStages` builds it after the plan; a hit sets `colourInput` to the cached texture and skips stages 3–5; an entry is stored only when stage 5 ran; `.healed`/`.healedPreview` roles keep a same-size tile from overwriting the preview's entry; `storeHealed` evicts entries pointing at the same texture; the cache is cleared in both `releasePooledTextures` variants and in `setAIDenoised`.

**Visualise Spots** (`Shaders/Dust.metal`, `dustVisualise`, `LazyKernel`, "Dust" in `kernelNames`): log2 luminance of the display texture; σ = max(0.7, radiusSensorPx/binSpan); inner mean = 9×9 taps spaced `max(1, round(σ/4))`, outer mean = 9×9 taps spaced `max(1, round(3σ/4))` (162 reads per pixel, no scratch, the same look at every bin factor); `hp = outer − inner`; `t = 0.005 + 0.15·(1 − threshold)²`; `out = 1 − smoothstep(t, 3t, hp)`. Params `{threshold, radiusSensorPx, binSpan}` from `RenderOutput.spotVisualisation`; roles `.visualised/.visualisedPreview`.

**Panel and tool** (`DustPanel.swift`, `EditorModel+Dust.swift`, `DustOverlay.swift`), a `DisclosureGroup("Sensor Dust")` after Spot Removal. Row: **Find Spots** (ProgressView while `findingDust`; help "Look for sensor dust in this photo on this Mac and heal each spot; replaces the spots found last time"; label "Find dust spots", value "Looking for dust spots"), `Toggle(.button)` "Spots…"/"Spots: on" arming `dustToolActive` (help "Show the spots; click a ring to remove a false one, click the image to add one"), **Clear** ("Clear all dust spots"). **Sensitivity** 0…100 (default 50) and **Spot Size** Small/Medium/Large (default Medium, or the band holding `expectedRadius`): moving either re-detects from the kept analysis without a new render while the tool is armed. **Visualise Spots** toggle with **Contrast** 0…1 (default 0.5). **From dust map…** (the Remove Dust sheet, in-memory path) and **Save as dust map…** (the current list, for this camera). Count line "No dust spots. Find Spots looks for sensor dust." / "37 dust spots · click a ring to remove one, click the image to add one". After detection `status = SpokenText.dustFound(added:detected:)` ("No dust spots found" / "Found 1 dust spot" / "Found 37 dust spots" / "Dust spots found already have patches") and `Announcement.post`. Find Spots **replaces** the list as one history step; `flushPendingSave()` runs first so a preceding slider move is its own step. `dustToolBegan(at:)`: a ring → remove; elsewhere → add a spot of the band's centre radius (cap 200: "At most 200 dust spots per image"). Overlay: thin rings (1 pt white over a 2 pt black halo, accent when selected), label "Dust spots", value `SpokenText.dustSpots(count:selected:)`, hint "Click a ring to remove a false spot, or click the image to add one", adjustable action steps the selection, named action "Delete selected spot"; ⌫ through `.deleteHeal` (`dustToolActive && hasSelectedDust`). Rings and the visualisation follow `renderParameters` (Before shows neither); `visualiseSpots`, `dustToolActive` and `dustAnalysis` reset on image change, `dustAnalysis` also on disarm and at memory warning. Tool exclusivity is reciprocal; `imageToolActive` includes it. Develop menu: `toolToggle("Sensor Dust", .dust)`, no key. **Auto Adjust (⌘U) is unchanged** (it is pressed on every image while culling; a GPU analysis and up to 200 patches there is a change nobody asked for, and the batch job covers many images); the hook, if wanted, is `flushPendingSave()` then `findDustSpots(fromAuto: true)`.

**Dust maps** (`DustMap.swift`): `DustMap { id, camera, sensorSize, created, referenceName, referenceCaptureDate, aperture, options, spots }` with `title` "Nikon D750 · 12 Sep 2026 · 41 spots"; `DustMapStore` at `~/Library/Application Support/latent/dust-maps.json` (atomic, versioned, unreadable reads as empty). Keyed by `ImageRecord.camera` ("Make Model"; for a reference file, `RawSummary.cameraMake` + " " + `cameraModel`); a target whose camera or `rawWidth × rawHeight` differs is skipped with a note. `DustDetector.verify` looks ±r around each map spot for a DoG peak at scale r passing the negative-contrast and circularity tests at the target's threshold; absent spots are skipped; accepted spots take the larger radius; sources are placed per target.

**Photo › Remove Dust…** (`KeyCommand.removeDust`, after Photo Merge): enabled when `editorReady && (mode == .develop ? hasImage : selectionCount >= 1) && !exportQueueRunning && !photoMergeRunning && !fileOperationRunning && !isEditingText` (`photoMergeRunning` covers any holder of the GPU slot). Targets: Library → `batchTargets(onlyPrimary: false)`; Loupe/Compare/Survey → the primary; Develop → in memory on the open image (undoable, no queue; Find spots and Use dust map only). `RemoveDustSheet.swift` (`RemoveDustSheetModel`, testable without the view): "Remove dust from 12 photos"; radio **Find spots in each photo** / **Use dust map:** popup of `maps(forCamera:)` for the selection's cameras (disabled with "No dust map for Nikon D750 yet"; a remembered map that no longer exists falls back to the first, else to Find spots) / **New dust map from reference photo…** with Choose File… (NSOpenPanel, raw types, opened through `RawFile(path:)` on the granted URL) or Use the selected photo; Sensitivity and Spot Size; note "3 of 12 photos are from another camera and will be skipped"; Cancel / **Remove Dust** (disabled while `exportQueue.isGPUBusy`). `DustRemovalPreferences` follows `HDRMergePreferences` (`RemoveDust.method/sensitivity/size/mapID`). `DustRemovalJob: SelectionJob` (§8): `prepare` analyses a reference and saves the map; `process` opens the raw, builds `ExportPlan.parameters(editStackJSON:session:colorSpace: .sRGB)`, analyses, detects or verifies, dedupes against existing dust and heals, and returns the **migrated** stack (`session.stackForThisImage(decoded)` with `modules.dust` set and `frame = activeAreaFrame`; a stored stack with no frame or with readout-frame heals is migrated in the same write, or the next open would shift the dust by the masked border on bordered cameras).

## 7. Touch-up

**Coordinates.** `TouchUpFace.boundingBox` is on the **raw** sensor grid: Find Faces detects on the output-grid analysis render and maps the box's corners back through `RenderPipeline.rawSensorPoint(forOutputPoint:)` (`LensSampling.sourcePoints`, green channel). Regeneration maps the stored box forward with `outputSensorPoint(forRawPoint:)` (Newton on `sourcePoints`, 3 iterations; identity without lens correction), so lens and keystone edits never invalidate stored faces, then enlarges 20 % and seeds Vision. A seed that yields no landmarks keeps the face with an empty mask and the status "Face 2 could not be found again". After Find Faces the editor builds masks through the same seeded refit export uses (one extra ~60 ms call), so every path builds them identically.

**Analysis render** (`TouchUpAnalysis.render`): the image's defaults with as-shot WB, `locals = []`, `redEyes = []`, `touchUp = .neutral`, `dust = []`, and the edit's geometry copied (`lensDistortion/TCA/Vignetting`, `manualDistortion/Vignetting`, `perspective`), `.binned(quads: max(1, longEdge / 4000))` (long edge 2000–4000 px; Vision's 76-point fit needs faces ≥ ~80 px), `.file(.sRGB)`, `.analysis` pool. Analysis pixel → output-grid sensor coordinate is `(x + 0.5)·span`, `span = 2·quads` (a binned render can fall span−1 pixels short of `rawWidth`), never `x/width·rawWidth`. Faces narrower than 64 px are dropped and counted "too small".

**Regions** (`TouchUpRegions.build` → `TouchUpMaskSet`, half sensor resolution, three r8 slices skin/teeth/eyes in one 2D array, faces merged with max): per face, the box widened 25 %, resampled to half res, converted to CIELAB. Skin = `faceContour` closed by an elliptical arc whose apex sits 0.55 × contour height above the temple midpoint along the roll-corrected up axis, ∩ colour gate `1 − smoothstep(8, 16, Δab from the polygon's median (a*, b*)) × (|ΔL*| < 35)`, minus eyes (polygons scaled 1.25×), brows (dilated σ), `outerLips` (dilated σ/2) and two nostril discs (0.05 × face width), closed by 3 px, feathered σ = 0.015 × face width. Teeth = `innerLips` fill ∩ (L* > lip median + 15 ∧ C*ab < 25), eroded and feathered 1 px, empty under 16 px². Eyes = eye polygon with the pupil disc (0.16 × eye width) at 0; sclera 255, iris 128, feather 1 px. `ImageSession.touchUpMaskTexture(enabled:)` composites the enabled faces into a shared-storage texture, rebuilt only when the enabled set changes.

**Kernel** (`Shaders/TouchUp.metal`, `touchUpApply`, encoded by `TouchUpStage.encode`; "TouchUp" in `kernelNames`). Helpers are prefixed twins `touchUpPerceptual/ToLinear/FromLinear` (LocalContrast's are file-local `inline`; `make_app.sh` compiles files separately while the runtime fallback concatenates them, so reusing or redefining the names fails one way or the other). The stage prepares perceptual luma and blurs it at σ_fine = 1.5 px and σ_mid = clamp(0.035 × median enabled face width, 4, 48) sensor px, both ÷ binSpan, with the existing `lcPrepare/lcDownsample/lcBlurH/lcBlurV` pipelines and `wideGaussianWeights`, in its own texture roles. Per pixel: `uv = (tileOrigin + (gid + 0.5)·binSpan)/sensorSize`; sample the three slices; `l = max(perceptual(luma), 1e-3)`; skin `band = clamp(fine − mid, −0.25, 0.25)`, `lOut = l − skin·m_skin·band`; eyes `lOut += 0.4·eyes·m_eyes·clamp(l − mid, −0.2, 0.2)`, `gain = 1 + 0.3·eyes·m_eyes`; `lin *= clamp(pow(lOut/l, 2.2), 0.25, 4)·gain`; teeth `yellow = max(0, 0.5(r+g) − b)`, `lin.b += 0.9·t·yellow`, `lin *= 1 + 0.2t`; overlay (`RenderOutput.touchUpOverlay`) mixes toward the mask-overlay red by 0.4·m_skin. Tiles: `tileViewRegion` and the magnifier region inset by an extra `max(0, blurReach − tileMargin)` when `touchUp.wantsMasks` (`tileMargin` is 128, `blurReach = ceil(3σ_mid) + 2 ≤ 146`); `tileHealedCoverage` unchanged.

**Blemishes** (`BlemishFinder`, MLKit): `BlobDetector` over each enabled face's box in the analysis render with the skin slice as weight; radius 0.4–2.5 % of the face width (≥ 1.5 px), dark or reddish (a* above the skin median by > 6), contrast > 2.5 × MAD, circularity ≥ 0.6, smooth surround; blob radius × the analysis binSpan → sensor px; target mapped output → raw through `rawSensorPoint`; blobs whose raw centre lies inside any existing heal or dust target are rejected (no double healing); `HealPatch(radius: 1.6·r/shortSide, feather: 0.5, mode: .heal)` with `HealPatch.automaticBlemishOffset` (eight directions at 2.5r, inside the face polygon, on skin, avoiding other blobs, highest skin weight); best first, cap 64; a second Find Blemishes replaces the list.

**Copy, paste, presets.** `merged(.touchUp)` copies the sliders and keeps the destination's own faces and blemishes (`t.faces = self.modules.touchup?.faces ?? []`, same for blemishes; `other == nil` still clears); `restricted(to:)` therefore strips them from presets and the clipboard. In Develop, `apply` with a pasted touch-up that wants masks and has no faces runs Find Faces (and Find Blemishes when `blemishRemoval`) at once. In the Library, `applyToSelectionOrEditor` writes the stacks as today, then starts `FaceFindJob` (§8) over the `.selection` or `.primary` targets whose merged module wants masks without faces; Compare's Select pane and Survey panes stay inert until opened in Develop (documented). `Preset.groups` decodes leniently (unknown raw values dropped); a beta preset naming `touchUp` vanishes from the beta's list (forward-compat note).

**Panel** (`TouchUpPanel.swift`, `DisclosureGroup("Touch-up")` after Sensor Dust): **Find Faces** (ProgressView; caption `SpokenText.facesFound(found:tooSmall:)` "No faces found" / "Found 2 faces" / "Found 2 faces, 1 too small to retouch"; label "Find faces"; help "Find faces on this Mac. Nothing is sent anywhere"); one row per face with a 40 pt upright thumbnail (filled by Find Faces and by the open-time regeneration) and `Toggle("Face 1")` numbered left to right; sliders **Skin Smoothing**, **Teeth Whitening**, **Brighten Eyes** 0…100 (disabled with no faces); `Toggle("Remove blemishes")`, **Find Blemishes** with caption "12 blemishes" (`SpokenText.blemishesFound`) and a mini Clear; `Toggle("Show Skin Mask")`; footnote "Find Faces looks for faces on this Mac. Nothing is sent anywhere." Tool `touchUpToolActive` (`toolToggle("Touch-up", .touchUp)`, no key): `TouchUpOverlay` draws the enabled faces' boxes faintly and a ring per blemish; a click on a ring removes it, on skin adds one (0.3 % of the face width); label "Touch-up blemishes", value `SpokenText.blemishes(count:selected:)`, hint "Click a ring to keep that spot", adjustable action, named action "Keep selected spot"; ⌫ via `.deleteHeal`. Status: "Looking for faces…", "Looking for blemishes…", "Memory is low: touch-up will show again when memory recovers".

**Regeneration** (`EditorModel+TouchUp.swift`): on open when `touchUp.wantsMasks` and the session has no masks; after Find Faces; 300 ms after a geometry parameter changes (lens switches, manual distortion, perspective); face toggles only rebuild the texture; when pressure lifts after a critical drop. Detached task, `SendableImage`, `self.session === session` guard.

## 8. Batch jobs: SelectionJobQueue

One queue (`Sources/latent-app/SelectionJobQueue.swift`, the `PhotoMergeQueue` shape) runs a `SelectionJob` over explicit records: `prepare` once (a reference analysis), then per record `Task.checkCancellation`, progress "Photo 3 of 12: DSC_0107.NEF", a detached `.userInitiated` worker holding one `RawFile`/`ImageSession` at a time and pausing between photos while memory pressure is `.critical`; per-image failures become notes ("DSC_0110.NEF couldn't be read: …"). Results are committed once at the end (on cancel, for the photos done) through `library.setEdits(_:expecting:undoName:)` inside `library.perform(title)`: one undo group "Remove Dust (12 Images)" / "Find Faces (12 Images)"; an image whose stored JSON changed meanwhile is skipped and noted. Before the queue reads stored JSON, `ContentView` calls `model.flushPendingSave()` for the open image; after the commit it calls `library.didRestoreImages?(changedIDs, .edits)`, which reloads the editor through the existing `editorFollowUndo` → `load(record)` path (each image gets its own list, so a paste-style `model.apply` cannot serve). `OutputJobs.Kind.dustRemoval` ("Removing dust from \(name)"; quit alert: "removing sensor dust from photos", stops "the dust removal, which keeps the photos already done") and `.findFaces` ("Finding faces in \(name)"; "finding faces for touch-up", "the face search, which keeps the photos already done"). `LibraryPanel.runningJob` gains a third branch (title, "Cancel dust removal"/"Cancel face search", `spokenProgress`, stage line); `mergeNotes` shows the queue's notes; `MainWindowModels.selectionJobs = SelectionJobQueue(gpuSlot: queue)`; `CommandState.photoMergeRunning` already gates on the slot. Summary "Removed dust from 11 photos (412 spots) in 38 s" / "Found faces in 8 photos", announced; failure → `library.lastError`.

## 9. Export, thumbnails, slideshow, print

`ExportWorker.render`, `renderImage` and `renderForScreen` call `TouchUpRegions.regenerate(parameters.touchUp, session:pipeline:gpu:)` after `regenerateMasks` (analysis render, seeded refit, `session.setTouchUpMasks`), so exports, prints, contact sheets and slides carry the masks the editor showed; dust and blemishes are ordinary heal patches. `EditedThumbnailRenderer` (`PipelineThumbnailRenderer`) is unchanged: no MLKit, the touch-up stage is a no-op without masks, dust and blemishes render as patches (sub-pixel at 512 px). `latent-cli` links PixelEngine only, so its exports render touch-up without masks, like model masks today (Limitations).

## 10. Memory pressure

Warning: `ModelRegistry.shared.releaseAll()`; every prompt session is dropped unless the prompt tool is on, when only the selected local's prompted id survives; `dustAnalysis` dropped; pooled textures and both caches go through `releasePooledTextures`. Critical: all prompt sessions; brush rasters; the neural denoise result; the touch-up mask set, planes and texture (`ImageSession.droppedTouchUpMasks` read-once flag; the editor's `touchUpReleasedUnderPressure` triggers regeneration at `.normal`). `releaseAll` never touches `EditorModel.sharedDenoisers`. Imported large models load only when a mask asks; the importer compiles one package at a time; the batch worker holds one session and pauses at critical.

## 11. Tests

- PixelEngine: `DustStackTests`, `TouchUpTests` (neutral encodes nothing, untouched stacks byte-identical, round trip, lenient partial JSON, caps and clamps, `merged` keeping faces, `restricted` dropping them, history labels, `allHealPatches` order, `blurReach`), `ActiveAreaTests` (dust, blemish and face box move like a heal on a bordered camera; `modelVersion` preserved), `HealTests` (planning over the concatenated list; `HealStage.encode` with 200 + 64 + 32 patches, the 233rd changes pixels), `HealCacheTests` (key completeness; preview vs same-size tile; a hit skips the stage), `BlobDetectorTests` (1024×768 sky gradient + noise at three ISO levels + 25 blobs r 3–12 px, 5–25 % attenuation + decoys: precision ≥ 0.9 and recall ≥ 0.8 at 50; recall ≥ 0.95 at 100; 0 blobs on a clean scene at ≤ 70; radii ± 30 %; reddish blobs on skin; timing), `DustDetectorTests` (`expectedRadius` table, band narrowing, placement never overlaps or leaves the sensor over 500 random scenes, `verify` precision), `DustMapTests`, `DustVisualiseTests` (dip < 0.1 and flat > 0.9 at binSpan 1 and 4), `TouchUpKernelTests` (flat skin + 6 px noise with a fixture mask set: luma variance inside skin down > 70 %, outside changed < 1e-3; a yellow patch loses > 50 % of its yellow; sclera brightens more than iris; zero sliders bit-identical), `LensRegionTests` (`outputSensorPoint` inverts `rawSensorPoint` within 0.05 px).
- Golden (`GoldenImageTests`, `check(_:session:)` threaded to `render`): `dust` (12 fixed circles + one overlapping user heal, `detail: ballCentre`), `touch-up` (fixed face ids, `TouchUpMaskSet.fixture` set on the session) and `touch-up-blemishes` (fixed patches). No golden edit uses `.ai` or `.prompted` (grep confirmed), so nothing else changes; Core ML and Vision output is never golden-tested, and detector determinism is tested on synthetic scenes only (no D750 count test: GPU families differ by floating-point noise).
- MLKit: `ModelManifestTests` (fixtures, `ModelRef` legacy and `id@v`, garbage rejected, id pattern, non-http URLs, bundled manifests match their packages by hash), `ModelRegistryTests` (temp directories: ordering, bundled-wins, catalogue merge, status, default fallback, compute rank table), `ModelImporterTests` (a real import of the bundled NAFNet package copied to a temp folder with a generated manifest, on CI; every refusal leaves nothing behind; the zip path, absorbing `ZipSafetyTests`), `CoreMLStoreTests` (key holds id and sha prefix; a replaced package recompiles; stale entries pruned), `SubjectSegmenterTests`, `GuidedMaskRefinerTests`, `AIMaskTests` (skip-if-unbundled: coverage envelope, IoU ≥ 0.99 between runs), `ExportWorkerTests` (`birefnet-lite@1` → 1 mask; `birefnet-general@1` → `["BiRefNet General"]`; legacy literal and `"test"` handled), `FaceLandmarkerTests` (synthetic landmarks always; CC0 portrait tests skipped when absent: each `ImageRotation` maps to the same sensor coordinates within 0.005; seeds reproduce detections), `TouchUpRegionsTests` (synthetic face, hand-written landmarks), `BlemishFinderTests`, `ExportWorkerTouchUpTests` (a linear DNG written at test time from the portrait JPEG with `LinearRawDNGWriter`, so MLKitTests gains a MergeKit dependency; skipped without the asset).
- Catalog: `LibraryUndoTests` for `setEdits` (one group, mismatch skipped, missing image skipped).
- App: `ModelMenuTests`, `DustToolTests`, `TouchUpToolTests`, `RemoveDustSheetTests`, `SelectionJobQueueTests` (fake job, tiny DNGs as `PhotoMergeTests`: one undo group, user heals untouched, per-image failure noted, cancel keeps the done ones, changed-meanwhile and camera mismatch skipped, GPU slot claimed and released, quit wording), `CommandStateTests`, `EditorModelStateTests` (Find Spots after a slider move gives two history steps); each feature's wording tests live in its own file.

## 12. Docs

DESIGN.md: §4a (import path replaces the dormant download paragraph), §5.6 (`dust`, `touchup`, `modelVersion` form and legacy literals, omit-when-empty list, preset forward-compat), §8.1 (stage 5 wording, new 16, renumbering), §8.2 (heal cache; masks as session state), §8.4 (registry, manifest, hash, compute rank, substitution rule, face masks from raw-grid boxes, regeneration), §8.5, §7.2, new §8.7 Sensor dust and §8.8 Touch-up, §11 (SelectionJobQueue), §12, §15, §16. `Sources/MLKit/Resources/Models/README.md`: manifest format and hash, bundled rows, the catalogue table with scripts, how to add a model, "Sensor dust: no model, a classical detector in PixelEngine", "Built-in Vision: faces use `VNDetectFaceLandmarksRequest` revision 3, version `vision.faceLandmarks.3`". Wiki: new `Models.md` (in `_Sidebar.md` and `Home.md`), `Develop.md` (Sensor Dust and Touch-up after Red-Eye; stage text), `Library.md` (Remove Dust under "Applying edits to many images"), `Security-and-Privacy.md` (models imported from disk, hashes checked; the SAM manifest closes the "no script" gap), `Limitations.md` (lines 19 and 73 rewritten: ~287 MB of models; large models need memory; CLI exports and thumbnails without masks; Survey pane cost), `Architecture.md` (MLKit row), `Troubleshooting.md` ("A mask says its model is not installed", "Add Model… refused a package"), `Accessibility.md` (new spoken results); `Keyboard-Shortcuts.md` unchanged. `docs/Retouch.md` = this plan.

## 13. Risks

- BiRefNet conversion fails or is slow or inaccurate on the GPU; the package is a permanent ~90 MB git blob → time-boxed spike with numeric exits on the GPU path, U²-Net fallback, nothing else depends on which wins; converted once, README records the ceiling, LFS considered separately.
- An imported package hangs Core ML's ANE compiler in-process → the rank rule caps imports at cpuAndGPU; compile check off the main actor with a progress sheet.
- Untrusted manifest or package → id pattern, http(s) only, zip-slip guard on a container copy, content hash, feature names, stray files refused; the sandbox is the boundary.
- A sidecar names a model the Mac lacks → visible substitution with Get…/Add Model… on the row and in export notes.
- Large models plus the raw session on 8 GB Macs → load on demand, release at warning, one compile at a time.
- Dust false positives (foliage, stars); faint dust at wide apertures missed → smooth-surround and gradient tests, sensitivity 50, clickable rings, undoable Find Spots; misses accepted, docs say dust shows at f/11 and beyond.
- Heal cache staleness; 296 patches per render (~1,500 dispatches) → key test over every field stages 3–5 read, cleared in `setAIDenoised` and both release paths; the cache makes slider ticks skip stage 5; a batched dust kernel is deferred to v1.x; tile pan reuse degrades with 200 spread spots.
- The camera string conflates two bodies → map rows show date and reference name; a serial key waits for the LibRaw shim.
- Vision landmarks on turned heads, glasses, hair; seeded refit drifting across macOS versions → chroma gate, 64 px minimum, per-face on/off, Show Skin Mask; drift accepted as for every regenerated mask, seeds keep faces from being lost.
- Luma-only smoothing leaves colour blotches; the teeth gate catches a tongue or lip highlight → open item with modest slider wording; effect capped (0.9 yellow, +20 % luma), 1 px erosion.
- Masks lag geometry drags → 300 ms debounce; raw-grid boxes mean nothing is lost.
- Toolchain drift (local Swift 6.2.3, CI Swift 6.1) → no 6.2-only syntax (`nonisolated(nonsending)`, `@concurrent`, `InlineArray`, `Span`); the review builds on the CI toolchain.

## 14. Wave plan and file ownership

Each task runs in its own git worktree and owns the files the wave list names; a shared file has one owner per wave or waits for the lead's merge step. The lead writes the contracts first (Wave 0) so every task compiles against them; stubs return empty results.

**Wave 0 — contracts, spike, assets (≈5 days; lead + a spike agent in parallel).**
- W0-L (lead, ~4 d): contracts A–E as Swift with compiling stubs; the shared-file edits of contract D; `RenderOutput` fields; `rawSensorPoint`/`outputSensorPoint`; `TouchUp.swift`, `TouchUpMasks.swift`, `DustMap.swift` (types + store), stubs for `BlobDetector`, `TouchUpStage`, `FaceLandmarker`, `ModelImporter`, `ModelManifest.swift`, `ModelRegistry.swift` (listing works; loading stubs), empty `Dust.metal` and `TouchUp.metal`, new `TextureRole` and `LazyKernel` cases and `kernelNames` entries; `Library.setEdits`/`batchTargets`; `SelectionJobQueue.swift` (complete); `OutputJobs.Kind` cases; `EditorModel.swift` stored properties for all three features and tool exclusivity, `disarmTools`/`imageToolActive`; `KeyCommand` cases, `CommandState` fields, rules and menu items; `ContentView.perform` arms (stubbed: the switch is exhaustive); the four tile-planning call sites; `Package.swift` (MLKitTests + MergeKit); the data-model tests.
- W0-S (spike agent, ~3 d): `scripts/latent_manifest.py`, `convert_birefnet.py`, `convert_u2net.py`, `requirements.txt`, the winning package, the four bundled `*.model.json`, `ModelCatalog.json`, `fetch_test_assets.sh --portrait` (once the asset is chosen). Go/no-go on the exit criteria before Wave 1.

**Wave 1 — engine (≈4 days, five parallel tasks):** W1-A models-core (registry loading, importer, `CoreMLStore`, segmenter, refiner, SAM2/SegFormer/AIMasks, `ExportWorker*` dispatch and substitutions); W1-B dust-core (`BlobDetector`, `DustDetector`, `DustSourcePlacer`, map store); W1-C pipeline (`RenderPipeline.swift`, `ImageSession.swift`, `Dust.metal`, goldens); W1-D touch-up kernel (`TouchUpStage.swift`, `TouchUp.metal`); W1-E faces (`FaceLandmarker`, `UprightImage`, `RedEyeDetector`, `TouchUpAnalysis`, `TouchUpRegions`, portrait fixture). Lead merge: regenerate the touch-up goldens once W1-D lands; full `swift test`.

**Wave 2 — app (≈5.5 days, three parallel tasks + merge):** W2-M models-app (settings view, preferences, Add menu, `EditorModel+Masks/+Memory/+Opening/+Denoise`, export and page reporting); W2-D dust-app (`EditorModel+Dust`, panel, overlay, sheet, `DustRemovalJob`); W2-T touch-up-app (`EditorModel+TouchUp`, panel, overlay, `FaceFindJob`, `BlemishFinder`, `ExportWorker*` touch-up regeneration). Lead merge (~1.5 d): `ContentView.swift` (routing, state, panel sections, sheet, flush-before-batch, reload-after-commit, Develop in-memory paths), `ImageViewport.swift`, `LibraryPanel.swift`, `LatentApp.swift`, the tool dispatch in `EditorModel+Heal.swift`, the dust and touch-up lines in `EditorModel+Opening/+Memory`, `EditorModel+Clipboard.swift` (paste → Find Faces).

**Wave 3 — docs, scripts, review (≈2 days, parallel):** W3-D docs (§12 and `docs/Retouch.md`); W3-S scripts (`convert_sam2.py`, `convert_modnet.py`, `convert_isnet.py`, manifest emission in the two existing converters, `SEGFORMER_SHA256`); W3-R review (lead: full test run on the CI toolchain, golden audit, `SnapshotHarness` steps `dust`, `touchup`, `models`, bundle size check, merge to main).

Rough total: 16–17 calendar days with up to five agents, ~40 agent-days.

---

# Appendix: contracts

The declarations each wave builds against. Bodies are stubs in Wave 0 and are filled in by the tasks that own the files.

## Sources/MLKit/ModelManifest.swift
Contract A: the per-model manifest, the stored-version reference, and the package content hash.

```swift
import Foundation
import CoreML

/// One `<id>.model.json` beside its package(s); also the row shape of ModelCatalog.json.
public struct ModelManifest: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable { case promptedSegmentation, subjectSegmentation, semanticSegmentation, denoise }
    public enum ComputeUnits: String, Codable, Sendable {
        case cpuOnly, cpuAndGPU, cpuAndNeuralEngine, all
        /// cpuOnly 0, cpuAndGPU 1, cpuAndNeuralEngine 1, all 2.
        public var rank: Int { get }
        public var mlComputeUnits: MLComputeUnits { get }
        public init(_ units: MLComputeUnits)
    }
    public enum Activation: String, Codable, Sendable { case sigmoid, probabilities }
    public enum Refine: String, Codable, Sendable { case none, guided }
    public struct Licence: Codable, Sendable, Equatable {
        public var name: String
        public var url: URL
        public var commercialUse: Bool
    }
    public struct Package: Codable, Sendable, Equatable {
        public var name: String            // "<name>.mlpackage" inside the model's folder
        public var role: String?           // imageEncoder | promptEncoder | maskDecoder for prompted kinds
        /// PackageHash.sha256(ofPackageAt:) of the package; nil only in catalogue rows.
        public var sha256: String?
        public var inputNames: [String]
        public var outputNames: [String]
    }
    public struct Converter: Codable, Sendable, Equatable {
        public var script: String
        public var sourceRevision: String?
        public var coremltools: String?
        public var torch: String?
        public var date: String?
    }

    public static let idPattern = "^[a-z0-9][a-z0-9.-]{0,63}$"

    public var id: String
    public var displayName: String
    public var purpose: String
    public var version: Int
    public var kind: Kind
    public var licence: Licence
    public var sourceURL: URL                 // http(s) only
    public var sizeMB: Int
    public var inputSize: Int                 // square
    public var packages: [Package]
    public var outputActivation: Activation?  // subject kind
    public var refine: Refine?                // subject kind; nil = .none
    public var labelsFile: String?            // semantic kind
    public var computeUnits: ComputeUnits?    // nil = no manifest override
    public var converter: Converter?

    /// What MaskShape stores: "<id>@<version>".
    public var modelVersion: String { "\(id)@\(version)" }
    public var isInstallable: Bool { packages.allSatisfy { $0.sha256 != nil } }
    /// Optional keys lenient; throws ManifestError for a missing required key, an id off `idPattern`, or a non-http(s) URL.
    public init(from decoder: Decoder) throws
    public static func load(from url: URL) throws -> ModelManifest
}

public enum ManifestError: Error, Equatable, CustomStringConvertible {
    case missingKey(String), badID(String), badURL(String)
    public var description: String { get }
}

/// Which model a stored `modelVersion` names.
public struct ModelRef: Hashable, Sendable {
    public var id: String
    public var version: Int
    public init(id: String, version: Int)
    /// Parses "<id>@<version>" and the four legacy literals; nil for anything else.
    public init?(stored: String)
    public var stored: String { "\(id)@\(version)" }
    public static let legacy: [String: ModelRef] = [
        "sam2.1-small.1": ModelRef(id: "sam2.1-small", version: 1),
        "vision.foregroundInstance.1": ModelRef(id: "vision.foregroundInstance", version: 1),
        "segformer-b2-ade20k-512.1": ModelRef(id: "segformer-b2-ade20k-512", version: 1),
        "latent.skyHeuristic.1": ModelRef(id: "latent.skyHeuristic", version: 1)]
}

public enum PackageHash {
    public static let hashedFiles = ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"]
    /// SHA-256 over `hashedFiles` in that order, each as relative-path bytes + 0x00 + file bytes.
    /// Throws `PackageHashError.unexpectedFile` for any other regular file in the package.
    public static func sha256(ofPackageAt url: URL) throws -> String
}
public enum PackageHashError: Error, Equatable { case missingFile(String), unexpectedFile(String) }
```

## Sources/MLKit/ModelRegistry.swift
Contract A: the registry (bundled + catalogue + imported), defaults, compute policy and the loaded-model dictionary.

```swift
import Foundation
import CoreML
import os

public struct ModelEntry: Sendable, Identifiable, Equatable {
    public enum Status: String, Sendable { case builtIn, bundled, installed, notInstalled }
    public var manifest: ModelManifest
    public var status: Status
    /// Folder holding the packages; nil for builtIn and notInstalled.
    public var location: URL?
    public var id: String { manifest.id }
    public var isInstalled: Bool { status != .notInstalled }
    public var modelVersion: String { manifest.modelVersion }
}

/// One loaded model per id, whatever its kind. (AIDenoiser keeps its own loading.)
public enum LoadedModel: Sendable {
    case subject(SubjectSegmenter)
    case prompted(SAM2Models)
    case semantic(SegmentationModel)
}

/// Bundled manifests + ModelCatalog.json + externalModelsDirectory/<id>/; a bundled id shadows an external one,
/// an external id shadows a catalogue one. One OSAllocatedUnfairLock guards the listing cache and the models.
public final class ModelRegistry: @unchecked Sendable {
    public static let shared = ModelRegistry()
    public static let builtInSubjectID = "vision.foregroundInstance"
    public static let subjectPreferenceKey = "latent.subjectModel"     // default "birefnet-lite"
    public static let promptedPreferenceKey = "latent.promptedModel"   // default "sam2.1-small"

    /// Test hook: explicit directories. `shared` uses CoreMLStore's.
    public init(bundled: URL? = CoreMLStore.modelsDirectory,
                external: URL = CoreMLStore.externalModelsDirectory,
                catalogue: URL? = CoreMLStore.catalogueURL,
                defaults: UserDefaults = .standard)

    // Listing (cached; refresh() after import/remove). Order: built-in, bundled, installed, catalogue.
    public func entries(kind: ModelManifest.Kind? = nil) -> [ModelEntry]
    public func entry(id: String) -> ModelEntry?
    /// The installed entry for a stored version, resolved by id only; nil when missing or when `ref` is nil.
    public func installed(_ ref: ModelRef?) -> ModelEntry?
    public func refresh()

    // Defaults for NEW masks: the preferred id if installed, else the bundled one of that kind, else built-in Vision / nil.
    public func defaultSubject() -> ModelEntry
    public func defaultPrompted() -> ModelEntry?

    /// Lowest rank of {preference, manifest.computeUnits ?? .all, entry.status == .bundled ? .all : .cpuAndGPU}.
    public func effectiveComputeUnits(for entry: ModelEntry,
                                      preference: MLComputeUnits = CoreMLStore.defaultComputeUnits) -> MLComputeUnits

    // Loaded models, one per id (load once, shared); released together under memory pressure.
    public func subject(id: String) async -> SubjectSegmenter?
    public func prompted(id: String) async -> SAM2Models?
    public func semantic(id: String) async -> SegmentationModel?
    public func release(id: String)
    public func releaseAll()
}
```

## Sources/MLKit/ModelImporter.swift
Contract A: Add Model… (folder, .mlpackage or .zip) and Remove; absorbs the zip helpers from OptionalModels.swift.

```swift
import Foundation

public enum ModelImportError: Error, Equatable, CustomStringConvertible {
    case noManifest, severalManifests, badManifest(String), badID(String), unknownKind(String)
    case alreadyBuiltIn(String), notInstallable, missingPackage(String), strayFile(String)
    case checksumMismatch(String), featureMismatch(String), semanticWithoutLabels, unsafeArchive
    case unzipFailed(String), compileFailed(String, String)
    /// Plain sentences, e.g. "The weights don't match the checksum in the manifest, so the model was not added."
    public var description: String { get }
}

public enum ModelImporter {
    public struct Progress: Sendable { public var stage: String; public var fraction: Double }
    /// A folder, an .mlpackage (its folder must hold the manifest) or a .zip. Stages, validates, copies to
    /// external/<id>/, compile-checks one package at a time with .cpuAndGPU off the main actor and compares
    /// feature names (SAM decoder aliases allowed); deletes the copy and throws on any failure.
    public static func importModel(from url: URL, into registry: ModelRegistry = .shared,
                                   progress: (@Sendable (Progress) -> Void)? = nil) async throws -> ModelManifest
    /// Deletes external/<id>/ and releases the loaded model.
    public static func remove(id: String, from registry: ModelRegistry = .shared) throws
    /// Moved from ModelDownloader (ZipSafetyTests follow).
    static func entriesAreSafe(_ entries: [String]) -> Bool
    static func listEntries(_ zip: URL) throws -> [String]
    /// Copies `zip` into the container's temporary directory, then zipinfo + ditto into a fresh staging folder there.
    static func stageArchive(_ zip: URL) throws -> URL
    /// The checks without copying, for tests: exactly one *.model.json, id pattern, kind, not bundled/built-in,
    /// every package present with no stray files, hashes, labels for a semantic kind.
    static func validate(folder: URL, registry: ModelRegistry) throws -> ModelManifest
}
```

## Sources/MLKit/CoreMLStore.swift
Contract A: manifest-aware loading with a content-hash cache key, and JSON lookup in an imported model's folder.

```swift
import Foundation
import CoreML

extension CoreMLStore {
    public static var catalogueURL: URL? { modelsDirectory?.appendingPathComponent("ModelCatalog.json") }
    /// Compiles and loads one package of `manifest` from `directory`. Cache key
    /// "<manifest.id>-<package.name>-<sha256.prefix(16)>.mlmodelc"; older "<id>-<name>-*" entries are deleted first.
    public static func load(_ package: ModelManifest.Package, of manifest: ModelManifest, at directory: URL,
                            computeUnits: MLComputeUnits) async throws -> MLModel
    /// JSON beside a model: `directory` first (an imported model's folder), then the bundled Models directory.
    public static func json<T: Decodable>(_ fileName: String, in directory: URL?, as type: T.Type) -> T?
}
```

## Sources/MLKit/SubjectSegmenter.swift
Contract A: one-shot subject models, the guided refiner, and the changed AIMasks/SAM2/ExportWorker signatures the app builds against.

```swift
import Foundation
import CoreGraphics
import CoreML
import PixelEngine

/// A subjectSegmentation model: image in, soft mask out.
public final class SubjectSegmenter: @unchecked Sendable {
    public let entry: ModelEntry
    public static func load(_ entry: ModelEntry, computeUnits: MLComputeUnits) async throws -> SubjectSegmenter
    /// Stretches to inputSize², one prediction, (1,1,H,W) or (1,H,W) output, sigmoid when the manifest says so,
    /// 8-bit at the model's native size; guided refinement when `entry.manifest.refine == .guided`.
    public func segment(_ image: CGImage) throws -> MaskBitmap
}

// Sources/MLKit/GuidedMaskRefiner.swift
public enum GuidedMaskRefiner {
    /// Upsamples `mask` to `guide`'s size with a guided filter on the guide's luminance (CPU, box sums).
    public static func refine(_ mask: MaskBitmap, guide: CGImage, radius: Int = 8, epsilon: Float = 1e-3) -> MaskBitmap
}

// Sources/MLKit/AIMasks.swift (changes)
extension AIMaskGenerator {
    public struct Result: Sendable {
        public let mask: MaskBitmap
        public let seconds: TimeInterval
        /// The display name of the model that ran instead of the stored one, or nil.
        public let substitutedModel: String?
    }
    /// `.subject`: ModelRef(stored:) → registry.installed → SubjectSegmenter / built-in Vision / missing → Vision + substitutedModel.
    public static func generate(_ kind: AIMaskKind, modelVersion: String, from image: CGImage,
                                registry: ModelRegistry = .shared) async throws -> Result
}
extension AIMaskKind {
    /// Registry-driven: subject → defaultSubject().modelVersion; classes → "segformer-b2-ade20k-512@1" or "latent.skyHeuristic@1".
    public var modelVersion: String { get }
}

// Sources/MLKit/SAM2.swift (changes)
extension SAM2Models {
    /// The three packages of a promptedSegmentation manifest, by role.
    public static func load(_ entry: ModelEntry, computeUnits: MLComputeUnits) async throws -> SAM2Models
}

// Sources/MLKit/ExportWorker.swift (changes)
// Rendered, Outcome and RenderedImage gain `public let maskSubstitutions: [String]` (display names; forwarded by
// Rendered.finished; renderForScreen logs and drops it).
// static func regenerateMasks(_ locals: [LocalAdjustment], session: ImageSession, pipeline: RenderPipeline,
//                             gpu: GPUContext) async throws -> (count: Int, substituted: [String])
```

## Sources/MLKit/FaceLandmarker.swift
Contract B: one Vision face-landmark pass shared by touch-up and red-eye; UprightImage moved out of RedEyeDetector.

```swift
import Foundation
import CoreGraphics
import Vision
import PixelEngine

public struct FaceObservation: Sendable, Equatable {
    /// Normalised coordinates of the render's grid, top-left origin: x, y, w, h.
    public var boundingBox: CGRect
    public var roll: Float
    public var yaw: Float
    public var confidence: Float
    public var faceContour, leftEye, rightEye, leftPupil, rightPupil,
               leftEyebrow, rightEyebrow, nose, outerLips, innerLips: [SIMD2<Float>]
}

public enum FaceLandmarker {
    public static let modelVersion = "vision.faceLandmarks.3"
    /// VNDetectFaceLandmarksRequest revision 3, 76 points, on `sensorImage` (an sRGB render of the whole sensor,
    /// unrotated) made upright by `rotation`; results sorted left to right in the upright image.
    public static func detect(in sensorImage: CGImage, rotation: ImageRotation) -> [FaceObservation]
    /// Refits landmarks inside `seeds` (sensor-normalised, top-left origin), each enlarged by `seedMargin` and
    /// converted to Vision's upright bottom-left frame here (inputFaceObservations); nil per seed Vision could not refit.
    public static func refit(in sensorImage: CGImage, rotation: ImageRotation, seeds: [CGRect],
                             seedMargin: CGFloat = 0.2) -> [FaceObservation?]
    /// The Vision pass on an upright image, in upright pixels (top-left origin); RedEyeDetector's input.
    static func upright(in image: CGImage, seeds: [CGRect]?) -> [UprightFace]
}

// Sources/MLKit/UprightImage.swift
enum UprightImage {
    /// Moved from RedEyeDetector.rotated(_:by:).
    static func rotated(_ image: CGImage, by rotation: ImageRotation) -> CGImage?
}
```

## Sources/MLKit/TouchUpRegions.swift
Touch-up analysis render, region masks and blemish finder (MLKit), used by the editor and by ExportWorker.

```swift
import Foundation
import CoreGraphics
import PixelEngine

// Sources/MLKit/TouchUpAnalysis.swift
public enum TouchUpAnalysis {
    public struct Render: @unchecked Sendable {
        public let image: CGImage      // output grid, unrotated, sRGB
        public let span: Int           // sensor px per analysis px (2 × quads); sensor = (x + 0.5) * span
        public let rotation: ImageRotation
    }
    /// Defaults + as-shot WB, no locals/red-eye/dust/touch-up, the edit's geometry copied,
    /// .binned(quads: max(1, longEdge / 4000)), .file(.sRGB), in the .analysis pool (released after).
    public static func render(session: ImageSession, pipeline: RenderPipeline, gpu: GPUContext,
                              parameters: EditParameters, rotation: ImageRotation) throws -> Render
}

public enum TouchUpRegions {
    public struct Found: Sendable {
        public var faces: [TouchUpFace]                 // raw-grid boxes, left to right
        public var tooSmall: Int
        public var masks: TouchUpMaskSet
        public var thumbnails: [UUID: SendableImage]    // 40 pt upright crops
    }
    /// Find Faces: detect, map boxes output → raw (rawSensorPoint), refit from those seeds, build masks.
    public static func find(in render: TouchUpAnalysis.Render, session: ImageSession, pipeline: RenderPipeline,
                            parameters: EditParameters) -> Found
    /// Regeneration: stored raw boxes → output grid (outputSensorPoint) → seeded refit → masks;
    /// `missing` are faces kept with an empty mask because Vision could not refit them.
    public static func build(_ touchUp: TouchUp, from render: TouchUpAnalysis.Render, session: ImageSession,
                             pipeline: RenderPipeline, parameters: EditParameters) -> (masks: TouchUpMaskSet, missing: [UUID])
    /// ExportWorker's entry: render + build + session.setTouchUpMasks; no-op unless touchUp.wantsMasks.
    @discardableResult
    public static func regenerate(_ touchUp: TouchUp, session: ImageSession, pipeline: RenderPipeline, gpu: GPUContext,
                                  parameters: EditParameters, rotation: ImageRotation) throws -> [UUID]
}

// Sources/MLKit/BlemishFinder.swift
public enum BlemishFinder {
    /// BlobDetector over each enabled face's box with the skin slice as weight; raw-grid HealPatches (cap 64),
    /// excluding blobs inside any of `existing` (heals + dust).
    public static func find(in render: TouchUpAnalysis.Render, masks: TouchUpMaskSet, touchUp: TouchUp,
                            existing: [HealPatch], session: ImageSession, pipeline: RenderPipeline,
                            parameters: EditParameters) -> [HealPatch]
}

/// CGImage across a detached task (public form of the app's wrapper).
public struct SendableImage: @unchecked Sendable { public let cgImage: CGImage; public init(cgImage: CGImage) }
```

## Sources/PixelEngine/BlobDetector.swift
Contract C: the classical blob detector shared by dust and blemishes.

```swift
import Foundation
import simd

public enum BlobDetector {
    public enum Polarity: Sendable, Equatable { case dark, reddish }
    public struct Parameters: Sendable, Equatable {
        public var radiusRange: ClosedRange<Float>     // px of the map
        public var polarity: Polarity
        public var contrastSigma: Float                // peak ≥ contrastSigma × σ_local
        public var minimumContrast: Float              // floor, map units (log2 stops, or a*)
        public var minimumCircularity: Float           // 0…1
        public var smoothSurround: Float?              // annulus residual std ≤ this × σ_local; nil = don't require
        public var maximumSurroundGradient: Float?     // mean |∇(G_2r∗D)| over the annulus, map units per px
        public var maximumCount: Int
        public init(radiusRange: ClosedRange<Float>, polarity: Polarity, contrastSigma: Float, minimumContrast: Float,
                    minimumCircularity: Float, smoothSurround: Float?, maximumSurroundGradient: Float?, maximumCount: Int)
    }
    public struct Blob: Sendable, Equatable {
        public var centre: SIMD2<Float>   // map px, pixel centres
        public var radius: Float          // map px (r_eq)
        public var contrast: Float        // map units
        public var score: Float
    }
    public struct Map: Sendable {
        public var values: [Float]        // row-major, width × height
        public var width: Int
        public var height: Int
        /// Optional per-pixel weight 0…1 (a skin mask): a blob whose centre weight < 0.5 is rejected; score ×= weight.
        public var weight: [Float]?
        public init(values: [Float], width: Int, height: Int, weight: [Float]? = nil)
    }
    /// Best first, capped at `p.maximumCount`.
    public static func detect(_ map: Map, _ p: Parameters) -> [Blob]
    /// 1.4826 × MAD of (D − G₁∗D) per `tile`² tile, bilinearly interpolated back to the map.
    public static func localNoise(_ map: Map, tile: Int = 64) -> [Float]
    /// G_{3σ}∗D − G_σ∗D through a pyramid (σ ≤ 4 px per level), upsampled to the map's size.
    public static func differenceOfGaussians(_ map: Map, sigma: Float) -> [Float]
}
```

## Sources/PixelEngine/DustDetector.swift
Dust analysis, detection, map verification and source placement (PixelEngine), used by the editor and the batch job.

```swift
import Foundation
import simd

public enum DustSpotSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large
    /// Sensor px: small 4…8, medium 6…16, large 12…40.
    public var sensorRadiusRange: ClosedRange<Float> { get }
    public var displayName: String { get }   // "Small" / "Medium" / "Large"
}

public enum DustDetector {
    public struct Options: Codable, Equatable, Sendable {
        public var sensitivity: Int      // 0…100, default 50
        public var size: DustSpotSize    // default .medium
        public init(sensitivity: Int = 50, size: DustSpotSize = .medium)
    }
    public struct Analysis: Sendable {
        public let map: [Float]               // log2 luminance of the binned (quads: 1) camera RGB
        public let width: Int
        public let height: Int
        public let binSpan: Float             // 2
        public let sensorSize: SIMD2<Float>   // rawWidth, rawHeight
        public let noise: [Float]             // BlobDetector.localNoise
    }
    /// Only white balance and demosaic matter to the analysis render; everything else set neutral.
    public static func analysisParameters(_ p: EditParameters) -> EditParameters
    /// renderCameraRGB(.binned(quads: 1)) in the .analysis pool, read back and converted row by row.
    public static func analyse(session: ImageSession, pipeline: RenderPipeline, gpu: GPUContext,
                               parameters: EditParameters) throws -> Analysis
    /// 0.75 / (N × pitch), pitch = 36 mm / max(cropFactor, 1) / rawWidth, clamped 2…40 sensor px; nil without aperture or crop factor.
    public static func expectedRadius(aperture: Double, cropFactor: Double, rawWidth: Int) -> Float?
    public static func blobParameters(options: Options, expectedRadius: Float?, binSpan: Float) -> BlobDetector.Parameters
    /// Spots as heal patches (best first, cap HealPatch.maximumDustCount) with sources from DustSourcePlacer,
    /// excluding blobs centred inside any of `existing` (dust, blemishes, heals).
    public static func detect(_ a: Analysis, options: Options, expectedRadius: Float?, existing: [HealPatch]) -> [HealPatch]
    /// Map spots verified in this image (a DoG peak within ±r passing the tests at the target's threshold); absent spots skipped.
    public static func verify(_ spots: [DustMapSpot], in a: Analysis, options: Options, existing: [HealPatch]) -> [HealPatch]
    /// The current list as map spots (Save as dust map…).
    public static func mapSpots(from patches: [HealPatch], analysis: Analysis) -> [DustMapSpot]
}

public enum DustSourcePlacer {
    public struct Spot: Sendable, Equatable { public var centre: SIMD2<Float>; public var radius: Float }   // sensor px
    /// 8 directions at 2.75r, 3.5r, 4.5r; rejects a source leaving the sensor or within 1.5·r_source + r_other of any
    /// spot in `others`; lowest mean gradient over the disc wins (gradient-free when `analysis` is nil); nil = drop the spot.
    public static func place(_ spot: Spot, avoiding others: [Spot], sensorSize: SIMD2<Float>,
                             analysis: DustDetector.Analysis?) -> SIMD2<Float>?
}
```

## Sources/PixelEngine/DustMap.swift
Per-camera dust maps and their store.

```swift
import Foundation
import simd

public struct DustMapSpot: Codable, Equatable, Sendable {
    public var centre: SIMD2<Float>   // active-area normalised
    public var radius: Float          // fraction of the short side
    public var contrast: Float        // stops
}

public struct DustMap: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var camera: String                 // ImageRecord.camera ("Make Model")
    public var sensorSize: SIMD2<Int>         // rawWidth, rawHeight
    public var created: Date
    public var referenceName: String
    public var referenceCaptureDate: Date?
    public var aperture: Double?
    public var options: DustDetector.Options
    public var spots: [DustMapSpot]
    /// "Nikon D750 · 12 Sep 2026 · 41 spots"
    public var title: String { get }
}

public struct DustMapStore: Sendable {
    /// ~/Library/Application Support/latent/dust-maps.json
    public static let defaultURL: URL
    public init(url: URL = DustMapStore.defaultURL)
    public func load() -> [DustMap]                       // unreadable reads as empty
    public func save(_ maps: [DustMap]) throws            // atomic; {"version":1,"maps":[…]}
    public func maps(forCamera camera: String) -> [DustMap]   // newest first
    public func add(_ map: DustMap) throws
    public func delete(id: UUID) throws
}
```

## Sources/PixelEngine/TouchUp.swift
Contract D (touch-up half): the stored module.

```swift
import Foundation
import simd

public struct TouchUpFace: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// Normalised active-area sensor coordinates on the RAW grid: x, y, w, h.
    public var boundingBox: SIMD4<Float>
    public var enabled: Bool
    public init(id: UUID = UUID(), boundingBox: SIMD4<Float>, enabled: Bool = true)
    public init(from decoder: Decoder) throws   // lenient
}

public struct TouchUp: Codable, Equatable, Sendable {
    public var faces: [TouchUpFace] = []        // ≤ maximumFaces, left to right
    public var skinSmoothing: Float = 0         // 0…100
    public var teethWhitening: Float = 0        // 0…100
    public var eyes: Float = 0                  // 0…100
    public var blemishRemoval: Bool = false
    public var blemishes: [HealPatch] = []      // ≤ HealPatch.maximumBlemishCount, raw grid
    public var modelVersion: String = ""        // FaceLandmarker.modelVersion once faces were found
    public static let neutral = TouchUp()
    public static let maximumFaces = 16
    public var isNeutral: Bool { get }
    public var enabledFaceIDs: Set<UUID> { get }
    /// An enabled face and a non-zero skin, teeth or eyes slider.
    public var wantsMasks: Bool { get }
    public var activeBlemishes: [HealPatch] { blemishRemoval ? blemishes : [] }
    /// Sliders clamped 0…100, faces prefix(maximumFaces) with boxes in HealPatch.coordinateRange,
    /// blemishes prefix(maximumBlemishCount).compactMap(\.sanitized).
    public var sanitized: TouchUp { get }
    public init()
    public init(from decoder: Decoder) throws   // every key optional
    public func medianFaceWidthPixels(sensorSize: SIMD2<Float>) -> Float?
    /// clamp(0.035 × faceWidth, 4, 48) sensor px.
    public static func sigmaMid(faceWidth: Float?) -> Float
    /// ceil(3 × sigmaMid) + 2 (≤ 146).
    public static func blurReachPixels(faceWidth: Float?) -> Int
}
```

## Sources/PixelEngine/TouchUpMasks.swift
The region mask set MLKit builds and ImageSession stores; fixture hook for goldens.

```swift
import Foundation
import CoreGraphics
import simd

public struct TouchUpMaskSet: Sendable, Equatable {
    public struct Face: Sendable, Equatable {
        public var id: UUID
        public var origin: SIMD2<Int>            // half-res pixels on the OUTPUT grid
        public var width: Int
        public var height: Int
        public var skin: [UInt8]                 // width × height each
        public var teeth: [UInt8]
        public var eyes: [UInt8]                 // 255 sclera, 128 iris, 0 pupil
    }
    public var faces: [Face]
    public var width: Int                        // ceil(sensor / 2) on each axis
    public var height: Int
    public var modelVersion: String
    public init(faces: [Face], width: Int, height: Int, modelVersion: String)
    /// The enabled faces composited (max on overlap) into three planes of width × height.
    public func composite(enabled: Set<UUID>) -> (skin: [UInt8], teeth: [UInt8], eyes: [UInt8])
    /// A deterministic set for tests and goldens: rectangles in normalised output-grid coordinates.
    public static func fixture(sensorWidth: Int, sensorHeight: Int,
                               faces: [(id: UUID, skin: CGRect, teeth: CGRect?, eyes: [CGRect])]) -> TouchUpMaskSet
}
```

## Sources/PixelEngine/TouchUpStage.swift
The touch-up stage encoder (testable on synthetic textures like HealStage).

```swift
import Foundation
import Metal
import simd

enum TouchUpStage {
    struct Params: Equatable {
        var skin: Float, teeth: Float, eyes: Float        // 0…1 (sliders / 100)
        var sigmaFine: Float, sigmaMid: Float             // render px (sensor px ÷ binSpan)
        var isLinear: Bool, headroom: Float
        var tileOrigin: SIMD2<Float>, binSpan: Float, sensorSize: SIMD2<Float>
        var overlay: Bool
    }
    /// Encodes lcPrepare, the two luma blurs (lcDownsample/lcBlurH/lcBlurV with wideGaussianWeights) into the
    /// touchUp* roles and touchUpApply; `masks` is the session's 3-slice r8Unorm array (skin, teeth, eyes).
    static func encode(input: MTLTexture, output: MTLTexture, masks: MTLTexture, params: Params,
                       session: ImageSession, preview: Bool, gpu: GPUContext, commandBuffer: MTLCommandBuffer) throws
}
```

## Sources/PixelEngine/RenderPipeline.swift
Contract D: EditParameters/RenderOutput additions and the raw↔output geometry helpers.

```swift
import Foundation
import simd

extension EditParameters {
    /// Automatic sensor-dust patches, rendered before touch-up blemishes and `heals`. In init and ==.
    public var dust: [HealPatch] { get set }            // default []
    public var touchUp: TouchUp { get set }             // default .neutral; in ==
    /// Stage 5's list, in order: dust, then active blemishes, then the user's patches.
    public var allHealPatches: [HealPatch] { dust + touchUp.activeBlemishes + heals }
}

public struct SpotVisualisation: Sendable, Equatable {
    public var threshold: Float        // 0…1 (the Contrast slider)
    public var radiusSensorPx: Float
    public init(threshold: Float, radiusSensorPx: Float)
}

extension RenderOutput {
    /// Viewport only; never set for files. Both in ==.
    public var spotVisualisation: SpotVisualisation? { get set }   // default nil
    public var touchUpOverlay: Bool { get set }                    // default false
}

extension RenderPipeline {
    /// Where the corrected (output-grid) sensor point reads from in the raw grid: LensSampling.sourcePoints, green channel.
    public func rawSensorPoint(forOutputPoint p: SIMD2<Float>, session: ImageSession, parameters: EditParameters) -> SIMD2<Float>
    /// The inverse by Newton iteration on sourcePoints (3 steps); identity when no lens correction is wanted.
    public func outputSensorPoint(forRawPoint p: SIMD2<Float>, session: ImageSession, parameters: EditParameters) -> SIMD2<Float>
}
```

## Sources/PixelEngine/EditStack.swift
Contract D: sidecar modules, groups, caps, hashing, migration and history (EditStack, EditModules, Healing, RedEye, ActiveAreaMigration, EditHistory, HealStage).

```swift
// Healing.swift
extension HealPatch: Hashable {}          // synthesised over every stored property
extension HealPatch {
    public static let maximumDustCount = 200
    public static let maximumBlemishCount = 64
}
// RedEye.swift
extension RedEyeSpot: Hashable {}

// EditStack.swift
extension EditStack.Modules {
    /// Automatic sensor-dust patches; absent when there are none.
    public var dust: [HealPatch]? { get set }
    /// Touch-up; absent when neutral.
    public var touchup: TouchUp? { get set }
}
// init(parameters:): modules.dust = p.dust.isEmpty ? nil : p.dust; modules.touchup = p.touchUp.isNeutral ? nil : p.touchUp
// parameters(defaults:): p.dust = (modules.dust ?? []).prefix(HealPatch.maximumDustCount).compactMap(\.sanitized)
//                        p.touchUp = (modules.touchup ?? .neutral).sanitized

// EditModules.swift
public enum EditGroup: String, CaseIterable, Codable, Sendable, Identifiable {
    case whiteBalance, tone, presence, toneCurve, colour, splitToning, detail, lens, locals, crop, heal, dust, touchUp
    // displayName: .dust "Sensor Dust"; .touchUp "Touch-up (skin, teeth, eyes, blemishes)". Neither in lookGroups.
}
// merged(with:groups:): .dust replaces modules.dust; .touchUp takes other's module but keeps self's faces and blemishes
//   (var t = other.modules.touchup; t?.faces = self.modules.touchup?.faces ?? []; t?.blemishes = …; result.modules.touchup = t).
//   Geometry set at the end: [.locals, .crop, .heal, .dust, .touchUp]. presentGroups adds .dust when modules.dust != nil,
//   .touchUp when modules.touchup != nil.
// Preset: init(from:) decodes `groups` leniently, dropping unknown raw values.

// ActiveAreaMigration.swift: geometryGroups inserts .dust when modules.dust != nil and .touchUp when the module has faces or
//   blemishes; migratingGeometry maps dust and blemishes exactly as heals, and each face box as
//   origin = map.point(origin), size = size * map.scale.
// EditHistory.swift: describeChange appends "Sensor Dust" and "Touch-up".
// HealStage.swift: `patches.prefix(HealPatch.maximumCount)` removed (each list is capped on decode).
```

## Sources/PixelEngine/ImageSession.swift
Contract D: heal cache, touch-up mask store, new texture roles and lazy kernels (ImageSession, GPUContext).

```swift
import Metal

extension ImageSession {
    // TextureRole additions:
    //   case healedPreview
    //   case visualised, visualisedPreview
    //   case touchUpPair, touchUpScratch, touchUpFine, touchUpMid, touchUpDownA, touchUpDownB, touchUp, touchUpPreview

    struct HealKey: Hashable {
        let stageKey: StageKey
        let aiDenoise: Float
        let aiDenoiseModel: String?
        let denoiseLuminance: Float
        let denoiseColor: Float
        let dust: [HealPatch]
        let blemishes: [HealPatch]
        let heals: [HealPatch]
        let redEyes: [RedEyeSpot]
    }
    func cachedHealed(for key: HealKey) -> MTLTexture?
    /// Evicts entries pointing at the same texture first. Cleared by releasePooledTextures() (all),
    /// releasePooledTextures(in:) (entries whose texture was released) and setAIDenoised(_:model:).
    func storeHealed(_ texture: MTLTexture, for key: HealKey)

    public var touchUpMasks: TouchUpMaskSet? { get }
    public func setTouchUpMasks(_ set: TouchUpMaskSet?)
    public var hasTouchUpMasks: Bool { get }
    /// r8Unorm type2DArray of 3 slices (skin, teeth, eyes) at the set's size, shared storage; rebuilt when `enabled` changes.
    func touchUpMaskTexture(enabled: Set<UUID>) -> MTLTexture?
    /// True once releaseMemory(.critical) dropped a mask set; cleared by setTouchUpMasks. releaseMemory keeps its Bool result.
    public var droppedTouchUpMasks: Bool { get }
}

// GPUContext.swift
// enum LazyKernel { …; case dustVisualise; case touchUpApply }
// kernelNames += ["Dust", "TouchUp"]   (both .metal files exist from Wave 0)
```

## Sources/Catalog/Library.swift
Contract E: one-undo-group batch write of precomputed edits, and public batch targets.

```swift
import Foundation

extension Library {
    /// The visible selection, or the primary only (metadataTargets made public).
    public func batchTargets(onlyPrimary: Bool) -> [ImageRecord]

    /// Writes each image's new stored edit (nil clears it) only when its current stored JSON equals `expected[id]`
    /// (nil = no edit); others are skipped and named in `TransformOutcome.skipped`, as are images no longer in `images`.
    /// Files ONE Library undo group named `undoName` ("Remove Dust (12 Images)") for the images written. Call inside
    /// `perform` so quitting waits.
    @discardableResult
    public func setEdits(_ edits: [Int64: String?], expecting expected: [Int64: String?],
                         schemaVersion: Int = EditStack.schemaVersion,
                         processVersion: String = EditStack.processVersion,
                         undoName: String) async throws -> TransformOutcome
}
```

## Sources/latent-app/SelectionJobQueue.swift
The one batch-job queue (PhotoMergeQueue shape) that DustRemovalJob and FaceFindJob run on.

```swift
import Foundation
import Catalog
import PixelEngine

struct SelectionJobInput: Sendable {
    let record: ImageRecord
    let fileURL: URL
    /// As read before processing; the commit expects it unchanged.
    let storedJSON: String?
}

struct SelectionJobResult: Sendable {
    /// nil: leave the image alone; .some(nil): clear its edit; .some(json): write it.
    var newJSON: String??
    var count: Int            // spots or faces found, for the summary
    var note: String?         // shown in the panel (orange)
}

protocol SelectionJob: Sendable {
    var title: String { get }                    // "Dust removal" / "Finding faces"
    var outputKind: OutputJobs.Kind { get }      // .dustRemoval / .findFaces
    var undoName: String { get }                 // "Remove Dust" / "Find Faces"
    /// Once before the loop, off the main actor (analyse a reference photo, save a map); throwing aborts the job.
    func prepare(gpu: GPUContext, progress: @Sendable (MergeProgress) -> Void) async throws
    /// One image, off the main actor, one RawFile/ImageSession at a time; throwing skips it with a note.
    func process(_ input: SelectionJobInput, gpu: GPUContext) async throws -> SelectionJobResult
    func summary(changed: Int, counted: Int, skipped: Int, elapsed: TimeInterval) -> String
    func announcement(changed: Int) -> String
}

@MainActor
final class SelectionJobQueue: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var title = ""
    @Published private(set) var progress: MergeProgress?
    @Published private(set) var summary = ""
    @Published private(set) var notes: [String] = []
    let gpuSlot: ExportQueue
    let jobs: OutputJobs
    init(gpuSlot: ExportQueue, jobs: OutputJobs = .shared)
    /// False, doing nothing, when the slot is taken, the folder is gone or `records` is empty. Pauses between photos
    /// at critical memory pressure; commits once at the end (and on cancel, for the photos done) through
    /// library.setEdits inside library.perform(title), then calls library.didRestoreImages?(changedIDs, .edits).
    @discardableResult
    func start(_ job: any SelectionJob, records: [ImageRecord], library: Library, gpu: GPUContext) -> Bool
    func cancel()
    func waitUntilDone() async
}

// OutputJobs.swift
// enum Kind { …; case dustRemoval; case findFaces }
// begin reasons: "Removing dust from \(name)", "Finding faces in \(name)"
// quitAlert: under way "removing sensor dust from photos" / "finding faces for touch-up";
//            stopped "the dust removal, which keeps the photos already done" / "the face search, which keeps the photos already done"
```

## Sources/latent-app/EditorModel.swift
Stored properties the lead adds in Wave 0 so every app task writes only extension files; plus the command and state contracts (BareKeys, AppMenus).

```swift
// EditorModel.swift — added (and sam2Session, sam2Encoding, sam2Status, modelDownloadProgress, modelDownloadStatus,
// highQualityModelInstalled, modelDownloadTask removed)

// Models
var promptSessions: [String: SAM2Session] = [:]                 // by model id
var promptEncoding: [String: Task<SAM2Session?, Never>] = [:]
@Published var promptStatus: [String: String] = [:]

// Sensor dust
@Published var dustToolActive = false      // didSet: turns off heal, red-eye, crop, mask and touch-up tools; clears selectedDustIndex when off
@Published var findingDust = false
@Published var dustSensitivity = 50
@Published var dustSize: DustSpotSize = .medium
@Published var visualiseSpots = false      // didSet { rerender() }
@Published var visualiseThreshold: Float = 0.5   // didSet { if visualiseSpots { rerender() } }
@Published var selectedDustIndex: Int?
var dustAnalysis: DustDetector.Analysis?

// Touch-up
@Published var touchUpToolActive = false   // didSet: same exclusivity; clears selectedBlemishIndex when off
@Published var findingFaces = false
@Published var findingBlemishes = false
@Published var selectedBlemishIndex: Int?
@Published var showSkinMask = false        // didSet { rerender() }
@Published var faceThumbnails: [UUID: CGImage] = [:]
@Published var touchUpStatus = ""
var touchUpMaskTask: Task<Void, Never>?
var touchUpReleasedUnderPressure = false
var touchUpGeometryKey: String?
// The existing didSets on healToolActive, redEyeToolActive, cropToolActive and maskTool also clear dustToolActive and
// touchUpToolActive; disarmTools() clears both; imageToolActive includes both (EditorModel+Heal.swift).

// BareKeys.swift
// enum KeyCommand { …; case dust; case touchUp; case removeDust }
// enum NewMask: Equatable { case linear, radial, brush, subject, prompt }

// AppMenus.swift — CommandState fields and rules
// var dustToolActive = false, hasSelectedDust = false, touchUpToolActive = false, hasSelectedBlemish = false
// .dust, .touchUp:        mode == .develop && hasImage
// .removeDust:            editorReady && (mode == .develop ? hasImage : selectionCount >= 1) && !exportQueueRunning
//                         && !photoMergeRunning && !fileOperationRunning && !isEditingText
// .deleteHeal:            adds || (dustToolActive && hasSelectedDust) || (touchUpToolActive && hasSelectedBlemish)
// .addMask(.subject), .addMask(.prompt): mode == .develop && canAddMask
// Menus: Photo › item("Remove Dust…", .removeDust) after Photo Merge; Develop › toolToggle("Sensor Dust", .dust),
//        toolToggle("Touch-up", .touchUp); Develop › Masks › item("New Subject Mask", .addMask(.subject)),
//        item("New Click to Select", .addMask(.prompt)). No keyboard keys; Shortcuts.page unchanged.
```
