# Latent — Design Document

**Status:** Planning, v0.1. No code has been written yet.
**License:** GPLv3 (FOSS).
**Platform:** macOS only, on Apple Silicon M3 or newer. Must run correctly on both **macOS 15 (Sequoia)** and **macOS 26 (Tahoe)** — that's a hard requirement, not a "latest OS only" target as originally scoped. Metal **3** is the baseline (it's what Sequoia has); Metal 4, which shipped with Tahoe, is used only for optional fast paths gated behind `if #available(macOS 26, *)`, never as a hard dependency. See `Sources/PixelEngine/GPUContext.swift` for where that boundary lives in code.

---

## 1. Overview

Latent is a native macOS RAW photo manager and non-destructive editor, in the same family as Adobe Lightroom, darktable and RawTherapee. It is designed from the ground up for Apple Silicon's system-on-chip (SoC) architecture. The CPU, GPU, Neural Engine (ANE) and media engines share one pool of unified memory, and Latent is built so that image data is allocated once and processed in place by whichever processor suits each task. Nothing is copied between separate device memories.

### Goals

Latent aims to be fast and energy-efficient: every step should use the minimum compute it needs. Editing is strictly non-destructive, and original files are never modified. Catalogs are portable and live inside each photo folder, so there is no master catalog. Color quality should match or exceed that of the established FOSS editors.

### Non-goals

The following are explicitly out of scope:

- Compatibility with Lightroom's edit parameters.
- An iPad or iOS version.
- Cross-platform support.
- Monitoring external volumes for changes.
- A single, global master catalog.
- Distribution through the Mac App Store. The GPL is incompatible with Apple's store terms, so distribution uses notarized builds from GitHub Releases, Sparkle for updates and a Homebrew cask.

---

## 2. Efficiency Rules

Every design decision is checked against these rules.

1. **Never do work twice.** Every expensive result, whether a pipeline stage output, a thumbnail or an index entry, is cached and keyed by the inputs that produced it.
2. **Never do work that isn't visible.** Interactive rendering runs at viewport resolution. Full-resolution work happens only for zoomed-in tiles and for export.
3. **Never copy what can be shared.** Buffers live in unified memory and are passed between the CPU, GPU and ANE by reference, as `MTLBuffer`s, IOSurfaces or `CVPixelBuffer`s.
4. **Zero cost when idle.** There is no polling and no continuous display-link loop, and nothing is written to disk while a slider is being dragged.
5. **Read each source file once.** Import copies the file, computes its checksum, parses EXIF and extracts the embedded preview in a single pass.
6. **Use the cheapest representation that works.** A thumbnail comes from the embedded JPEG before any raw decode. A raw decode for thumbnails uses half-size mode before any demosaic.
7. **Background work runs on efficiency cores.** Import and thumbnail generation run at `.utility` or `.background` quality-of-service (QoS). Only interactive rendering runs at `.userInteractive`.

---

## 3. Technology Stack

| Layer | Choice | Notes |
|---|---|---|
| Application shell and inspector panels | Swift 6 + SwiftUI | Strict concurrency from day one |
| Heavy views (thumbnail grid, image viewport) | AppKit (`NSCollectionView`, a custom `NSView` hosting a `CAMetalLayer`) | Precise control over scrolling and cell reuse at scale |
| Pixel processing | Metal 3 compute kernels written in Metal Shading Language (MSL), with select Metal 4 fast paths on Tahoe | FP32 for scene-linear stages, FP16 for display-referred stages |
| RAW unpacking and metadata | LibRaw (LGPL/CDDL) | Unpacks sensor data only; demosaicing is done by Latent on the GPU |
| Algorithm references | darktable and RawTherapee (both GPLv3) | Source for porting the RCD, AMaZE and Markesteijn demosaicers, highlight reconstruction and sigmoid tone mapping |
| Lens corrections | Lensfun (LGPL) | Supplemented by the lens-correction data Sony embeds in ARW files |
| Color management | LittleCMS 2 + ColorSync | ICC transforms, soft-proofing and display profiles |
| Camera profiles | LibRaw matrices + Adobe DNG SDK | Users can load their own DCP profiles |
| Metadata and XMP | Exiv2 (GPL) | Full XMP read/write support, including camera MakerNotes |
| Catalog database | SQLite via GRDB.swift | One database per catalog folder |
| Checksums | xxHash (XXH64) | Computed while copying, at essentially no extra cost |
| Machine learning | Core ML on the ANE, the Vision framework, and Metal 4 in-shader inference where available (Tahoe only; Core ML otherwise) | Masking, and later ML denoising |
| Export | ImageIO (JPEG, HEIC, TIFF, PNG), libjxl (optional), DNG SDK | HEIC encoding uses the hardware HEVC encoder |
| Updates | Sparkle | Signed and notarized builds |

C and C++ code is confined to thin wrappers around LibRaw, Lensfun, LittleCMS, Exiv2 and the DNG SDK.

---

## 4. Package Structure

| Package | Responsibility | Depends on |
|---|---|---|
| `RawCore` | LibRaw wrapper, memory-mapped file input, EXIF, embedded-preview extraction | LibRaw |
| `PixelEngine` | Metal pipeline, kernels, stage cache, heaps and residency; has no UI dependencies | Metal, `ColorKit` |
| `ColorKit` | ICC and ColorSync handling, camera matrices, working-space math | LittleCMS |
| `LensKit` | Lensfun lookup, embedded-correction parsing, lens-identity overrides | Lensfun |
| `Catalog` | Folder catalogs, GRDB schema and migrations, XMP read/write, import, reconciliation | GRDB, Exiv2 |
| `MLKit` | Vision requests, Core ML models, in-shader ML kernels | Core ML, Vision |
| `AppUI` | SwiftUI and AppKit views, the viewport, the grid | All of the above |
| `latent-cli` | Headless rendering, golden-image tests, benchmarks | `PixelEngine`, `RawCore` |

---

## 5. Storage Architecture

### 5.1 Folder catalogs

Every photo folder is its own catalog. A visible `_latent/` container inside the folder holds that catalog's data.

```
Yosemite 2026/
├── DSC_0001.NEF
├── DSC00042.ARW
├── Day 2/                        ← "included" subfolder (belongs to the parent catalog)
│   └── DSC_0107.NEF
├── Astro/                        ← "independent" subfolder (has its own catalog)
│   ├── DSC_0300.NEF
│   └── _latent/
│       ├── catalog.sqlite
│       ├── .metadata_never_index
│       ├── xmp/
│       └── thumbnails/
└── _latent/
    ├── catalog.sqlite
    ├── .metadata_never_index      ← stops Spotlight indexing the container
    ├── xmp/
    │   ├── DSC_0001.NEF.xmp
    │   ├── DSC00042.ARW.xmp
    │   └── Day 2/
    │       └── DSC_0107.NEF.xmp
    └── thumbnails/                ← excluded from Time Machine backups
        ├── DSC_0001.NEF.heic
        ├── DSC00042.ARW.heic
        └── Day 2/
            └── DSC_0107.NEF.heic
```

The rules are as follows:

- **Paths.** The database stores only paths relative to the catalog root, never absolute ones. A catalog folder can therefore be moved, renamed, copied or backed up freely.
- **Sidecar naming.** Sidecars and thumbnails are named with the full original filename, for example `DSC_0001.NEF.xmp`. This keeps RAW+JPEG pairs that share a base name from colliding.
- **The container is a boundary.** A catalog never reaches into a subfolder that has its own `_latent/` container. The same logic applies to nested git repositories.
- **Backups and indexing.** `thumbnails/` is marked with `isExcludedFromBackup` because thumbnails can be regenerated. `xmp/` and `catalog.sqlite` are always backed up. Spotlight never indexes the container, but photos and sidecars outside it are indexed normally.
- **Optional interoperability.** A setting, off by default, also writes a minimal XMP file next to each image, containing only the rating, label and keywords. Lightroom and darktable look for sidecars in that location.

### 5.2 Subfolder modes

Each catalog records a mode for each of its subfolders, set per folder by the user:

| Mode | Behavior |
|---|---|
| `included` | The subfolder's images belong to the parent catalog. Their sidecars and thumbnails are stored under mirrored subpaths inside the parent's `xmp/` and `thumbnails/` folders. |
| `independent` | The subfolder has its own `_latent/` container and is a separate catalog. |
| `ask` | The user is prompted the first time Latent finds the subfolder. |

Each catalog also has a default mode that applies to newly discovered subfolders. Converting a subfolder between `included` and `independent` is a single transactional operation: sidecars and thumbnails are moved with same-volume renames (no data is copied), the matching database rows are moved, and the old rows are deleted in one transaction. If the operation fails midway, the sidecars remain intact and the database can be rebuilt from them.

### 5.3 Source of truth and redundancy

| Store | Role |
|---|---|
| XMP sidecar | **Authoritative.** Holds the complete edit stack, rating, label, keywords, snapshots and the source checksum. |
| `catalog.sqlite` | **Index and cache.** Makes grid filtering, sorting and search fast. It can be deleted at any time and rebuilt from the sidecars. |

**Write order.** Each edit is committed in two steps:

1. Commit a SQLite transaction.
2. Write the XMP to a temporary file in `xmp/`, then atomically rename it over the old sidecar.

**Debouncing.** No writes happen while a slider is being dragged. An edit is persisted when the slider is released or after about one second of inactivity.

**Reconciliation when a folder opens.** Latent lists the directory and compares each file's name, size and modification time against the database. It then compares each sidecar's modification time against the value recorded in the database, and re-parses only the sidecars that changed. An unchanged folder opens without decoding a single image.

**Renamed files.** If a file appears under a new name with no sidecar, Latent looks up its xxHash (XXH64) checksum in the database and reattaches the existing sidecar.

**No live watching.** Latent does not use FSEvents or any other file watching on external volumes. Reconciliation runs only when a folder is opened or when the user clicks Refresh.

**Network volumes.** SQLite's write-ahead log (WAL) journal mode does not work reliably on SMB or NFS shares. Latent detects the volume type and uses WAL on local and external drives, and the rollback journal on network shares.

### 5.4 Database schema (initial)

```sql
CREATE TABLE images (
  id INTEGER PRIMARY KEY,
  rel_path TEXT NOT NULL UNIQUE,        -- relative to the catalog root
  preserved_name TEXT,                  -- original filename if renamed on import
  size INTEGER NOT NULL, mtime INTEGER NOT NULL,
  xxhash BLOB NOT NULL,
  capture_time INTEGER, camera TEXT, lens TEXT, lens_id TEXT,
  iso INTEGER, shutter REAL, aperture REAL, focal REAL,
  width INTEGER, height INTEGER, orientation INTEGER,
  rating INTEGER DEFAULT 0, label TEXT, flag INTEGER DEFAULT 0,
  sidecar_mtime INTEGER,
  thumb_key BLOB                        -- hash of the edit that produced the thumbnail
);
CREATE TABLE edits      (image_id INTEGER PRIMARY KEY REFERENCES images ON DELETE CASCADE,
                         schema_version INTEGER, process_version TEXT,
                         params_json TEXT NOT NULL, updated_at INTEGER);
CREATE TABLE history    (image_id INTEGER REFERENCES images ON DELETE CASCADE,
                         step INTEGER, params_json TEXT, created_at INTEGER,
                         PRIMARY KEY (image_id, step));
CREATE TABLE snapshots  (image_id INTEGER REFERENCES images ON DELETE CASCADE,
                         name TEXT, params_json TEXT, PRIMARY KEY (image_id, name));
CREATE TABLE keywords   (id INTEGER PRIMARY KEY, name TEXT NOT NULL,
                         parent_id INTEGER REFERENCES keywords);
CREATE TABLE image_keywords (image_id INTEGER, keyword_id INTEGER,
                         PRIMARY KEY (image_id, keyword_id));
CREATE TABLE subfolders (rel_path TEXT PRIMARY KEY,
                         mode TEXT CHECK (mode IN ('included','independent','ask')));
CREATE TABLE lens_overrides (camera TEXT, lens_id TEXT, lensfun_model TEXT,
                         PRIMARY KEY (camera, lens_id));
CREATE TABLE settings   (key TEXT PRIMARY KEY, value TEXT);
```

No pixel data and no absolute paths are ever stored in the database.

To search across catalogs, Latent uses SQLite's `ATTACH` to query several catalog databases at once; it opens them in batches when there are many. The app itself stores only a list of recently opened folders in its preferences; that list is not a catalog.

### 5.5 XMP format

```xml
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:xmp="http://ns.adobe.com/xap/1.0/"
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    xmlns:xmpMM="http://ns.adobe.com/xap/1.0/mm/"
    xmlns:latent="https://github.com/OWNER/latent/ns/1.0/"
    xmp:Rating="4"
    xmp:Label="Green"
    xmpMM:PreservedFileName="DSC_0001.NEF"
    latent:SchemaVersion="1"
    latent:ProcessVersion="1.0"
    latent:SourceHash="xxh64:9f2c4b...">
   <dc:subject><rdf:Bag><rdf:li>Yosemite</rdf:li></rdf:Bag></dc:subject>
   <latent:EditStack><![CDATA[ { ...edit JSON... } ]]></latent:EditStack>
   <latent:History><![CDATA[ [ ... ] ]]></latent:History>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
```

The namespace URI never needs to resolve to a real page, but once released it must never change. Standard XMP properties are used wherever they exist.

### 5.6 Edit stack JSON

```json
{
  "schema": 1,
  "process": "1.0",
  "modules": {
    "rawprepare":  { "enabled": true },
    "highlights":  { "enabled": true, "method": "inpaint", "threshold": 1.0 },
    "whitebalance":{ "enabled": true, "mode": "camera" },
    "demosaic":    { "enabled": true, "method": "rcd" },
    "exposure":    { "enabled": true, "ev": 0.7 },
    "lens":        { "enabled": true,
                     "distortion": {"source": "lensfun"},
                     "tca":        {"source": "lensfun"},
                     "vignetting": {"source": "embedded"},
                     "profile": "Sony FE 24-70mm f/2.8 GM II",
                     "lensfunDb": "2026-08-15" },
    "tone":        { "enabled": true, "method": "sigmoid", "contrast": 1.4 },
    "masks":       [ ]
  },
  "crop": { "x": 0.0, "y": 0.0, "w": 1.0, "h": 1.0, "angle": 0.0 }
}
```

**Process version.** Every edit records the pipeline version it was created with. When algorithms improve in a later release, existing edits keep rendering the same way until the user explicitly upgrades them. This is what makes edits reproducible over time.

**Frozen lens profiles.** Each edit records which Lensfun database version supplied its profile, so a later database update cannot silently change an edited photo.

---

## 6. Import

> **Status: not planned.** This section describes the card-import flow as originally designed. It was dropped in September 2026: Latent's user copies files into a folder by other means and opens the folder, which creates the catalog in place (§5). Reconciliation (§5.3) handles duplicates-by-hash and renames well enough for that workflow. Kept for reference in case import is wanted later.

Every import copies files into **one destination folder** that the user chooses, with the last-used folder offered as the default. If that folder already has a `_latent/` container, the imported images join the existing catalog; otherwise a new catalog is created.

Import is designed as a single streaming pass, so each source file is read exactly once. That one pass performs four jobs at the same time:

- It writes the copy to the destination folder.
- It computes the file's xxHash (XXH64) checksum.
- It parses the EXIF data needed for the catalog.
- It extracts the camera's embedded JPEG preview, which becomes the initial thumbnail.

After the copy finishes, Latent reads the destination file back and checks its checksum to confirm the copy is intact. An optional second destination receives a backup copy during the same pass; that costs an extra write, but no extra read.

**Sources are never modified.** Latent never deletes or alters files on the source, and memory cards should be formatted in the camera.

**Handling duplicate filenames:**

| Situation | Action |
|---|---|
| The name exists and the checksum matches | Skip the file as a duplicate |
| The name exists but the checksum differs | Save the file with a suffix, for example `DSC_0001-2.NEF`, and record the original name in `xmpMM:PreservedFileName` |
| An optional rename template is set (off by default) | Rename files on import, for example `{date}_{camera}_{counter}` |

Filename collisions are a real risk here, because each camera's file counter eventually wraps back to 0001.

**Read-only sources** such as memory cards and locked folders are always handled through import. Latent never tries to create a catalog in place on them.

---

## 7. RAW Ingest and the Memory Model

### 7.1 From file to GPU

1. Latent memory-maps the raw file read-only and passes it to LibRaw with `open_buffer`. The kernel loads only the pages that are actually read.
2. LibRaw unpacks the sensor data. The goal is for it to unpack directly into a page-aligned, shared-storage `MTLBuffer`. How to achieve this is decided in Phase 0 (see §13).
3. The GPU kernels read that buffer directly. No upload or staging copy is needed.

### 7.2 Storage-mode policy

Buffers are assigned a Metal storage mode depending on which processors touch them:

| Buffer | Storage mode | Reason |
|---|---|---|
| Raw sensor input | Shared | Written by the CPU (LibRaw), read by the GPU |
| Demosaiced image and pipeline intermediates | Private | GPU-only; private storage gets lossless framebuffer compression, which saves memory bandwidth |
| Histogram and scope results | Shared | Small, and read back by the CPU |
| Export readback | Shared | Read by ImageIO |
| Thumbnails, previews and ML inputs | IOSurface-backed | Shared by Core ML, Vision, Metal and ImageIO without copies |

**Memory reuse.** Intermediate buffers are allocated from an `MTLHeap` with aliasing: stages whose lifetimes don't overlap reuse the same memory.

**Residency.** The active image's working set is kept resident in GPU memory using `MTLResidencySet` where the runtime OS supports it, falling back to Metal 3's `useResource`/`useHeap` calls on Sequoia if `MTLResidencySet` turns out to be Tahoe-only — confirm which is the case in Phase 0, since the exact OS cutoff for this API needs checking against current documentation rather than assumed.

**On-chip memory.** Neighborhood kernels such as demosaicing, sharpening and local contrast stage their tiles in threadgroup memory. The M3's Dynamic Caching makes it practical to fuse several stages into a single kernel.

---

## 8. Processing Pipeline

### 8.1 Fixed module order

The modules always run in this order:

1. **Raw prepare:** black and white levels, then flat-field correction.
2. **Highlight reconstruction.**
3. **White balance.**
4. **Demosaic:** RCD by default, with AMaZE-style as an option and bilinear for fast previews.
5. **Camera matrix or DCP profile,** converting into the linear Rec.2020 working space.
6. **Exposure.**
7. **Lens corrections:** distortion, chromatic aberration (TCA) and vignetting.
8. **Denoise:** classic GPU methods in v1, with ML denoising added later.
9. **Tone mapping:** sigmoid, scene-referred to display-referred.
10. **Local adjustments with masks.**
11. **Color grading.**
12. **Sharpening.**
13. **Output transform:** to the display (Extended Dynamic Range, EDR) or to the export color space.

Stages 1 through 7 compute in FP32. Stages from tone mapping onward use FP16 wherever precision testing confirms it is adequate.

### 8.2 Caching and resolution

**Stage cache.** Each stage's output is keyed by a hash of every parameter upstream of it, together with the source checksum. When a parameter changes, only the stages downstream of it re-run. These caches live in RAM only and are never written to disk.

**Viewport-resolution rendering.** Interactive editing processes a downscaled linear image that matches the viewport size. A 24 MP image shown on a 5K display is processed at roughly 14 MP when zoomed to fit.

**Zooming in.** When the user zooms to 100%, only the visible tiles are rendered at full resolution.

**Full-resolution rendering.** Full-resolution renders happen only for export, or asynchronously when the viewport needs them.

### 8.3 Display

The viewport is a `CAMetalLayer` configured with `wantsExtendedDynamicRangeContent`, the `rgba16Float` pixel format and extended linear Display P3. It redraws only in response to user input or when a render finishes, never continuously.

The histogram, waveform and vectorscope are computed on the GPU using per-threadgroup atomic histograms that are then reduced into one result.

### 8.4 Masking

**Parametric masks.** Brush, linear gradient, radial gradient and luminance or color range masks are stored as parameters and rasterized on the GPU when needed.

**AI masks.** Subject and person masks come from the Vision framework. Sky masks come from a custom Core ML model running on the ANE. AI masks are cached as IOSurfaces and can be regenerated from their inputs.

---

## 9. Camera and Lens Support

### 9.1 Cameras

| Camera | Format | Notes |
|---|---|---|
| Nikon D750 | NEF, 14-bit lossless or 12-bit | Mature LibRaw support |
| Sony A7 III (ILCE-7M3) | ARW, uncompressed or lossy-compressed | Lens-correction data is embedded in each file. Pixel Shift is deferred to v1.x |
| Canon EOS DSLR (model not specified) | CR2 and CR3 | Both formats are supported through LibRaw, so the exact model does not matter |

**Tiered sensor support:**

- **v1, full-quality GPU path:** Bayer sensors, monochrome sensors and linear DNG.
- **v1.x:** X-Trans. No current body in use has an X-Trans sensor.
- **Fallback:** every other format LibRaw supports still opens, using LibRaw's slower CPU processing.

### 9.2 Lens correction sources

Latent picks a correction source separately for each correction type (distortion, chromatic aberration, vignetting), in this order:

1. A **Lensfun** profile for that correction type.
2. Correction data **embedded by the camera** in the raw file (Sony ARW).
3. **Manual** sliders, which can be saved as a per-lens preset.

The chosen source is recorded in the edit stack. When Nikon lens IDs are ambiguous for third-party lenses, the user's manual choice is remembered in the `lens_overrides` table.

Coverage of the current lenses in the Lensfun database, checked in September 2026:

| Lens | Distortion | TCA | Vignetting | Gap filled by |
|---|---|---|---|---|
| Nikon AF-S 20mm f/1.8G ED | ✓ | ✓ | ✓ | — |
| Nikon AF-S 50mm f/1.4G | ✓ | ✓ | ✓ | — |
| Tokina 100mm f/2.8 Macro (Nikon F) | ✓ | ✓ | ✗ | Canon EF version's vignetting profile (validate), or manual |
| Nikon AF-S 200-500mm f/5.6E VR | ✓ | ✓ | ✓ | — |
| Sony FE 20-70mm F4 G | ✓ | ✓ | ✓ | — |
| Sony FE 24-70mm F2.8 GM II | ✓ | ✓ | ✗ | Embedded ARW correction data |
| Tamron 28-75mm F2.8 G2 (A063) | ✓ | ✗ | ✓ | Embedded ARW correction data |
| Sony FE 200-600mm G OSS | ✓ | ✓ | ✓ | — |
| Canon (generic lenses) | — | — | — | Manual sliders and per-lens presets |

---

## 10. Thumbnails

**Size and format.** Each image has one thumbnail, about 512 px on the long edge, encoded as HEIC with the hardware HEVC encoder.

**Unedited images.** The thumbnail is the camera's embedded JPEG preview, downscaled. No raw decoding is involved.

**Edited images.** Latent decodes the raw file in LibRaw's half-size mode, which reads each 2×2 Bayer block as one pixel so no demosaicing is needed, and runs the edit pipeline at thumbnail resolution. This runs at `.background` QoS after the edit is saved, never while a slider is being dragged.

**Staleness.** The `thumb_key` column stores the hash of the edit that produced each thumbnail. A thumbnail is regenerated only when its key no longer matches the current edit.

**Larger previews.** Previews bigger than a thumbnail come from the embedded JPEG when needed and are never stored.

---

## 11. Concurrency

| Work | Quality of service (QoS) | Runs on |
|---|---|---|
| Viewport render, slider response | `.userInteractive` | Performance cores and GPU |
| Opening a folder, reconciliation | `.userInitiated` | Performance cores |
| Export | `.userInitiated` (user can lower it) | GPU and media engines |
| Import, thumbnail generation | `.utility` / `.background` | Efficiency cores |
| Sidecar writes | `.utility`, debounced | — |

The pipeline uses Swift structured concurrency throughout. Each catalog is an actor that owns its database connection.

---

## 12. Testing

**Golden images.** Every kernel has a golden-image test. `latent-cli` renders a file with a given edit JSON and compares the result against a stored reference image, within a small numeric tolerance.

**Camera sample files.** The test matrix includes, at minimum:

- Nikon D750: 14-bit lossless NEF and 12-bit NEF.
- Sony A7 III: uncompressed ARW and compressed ARW.
- Canon: one CR2 file and one CR3 file.
- One monochrome file and one linear DNG.

These come from raw.pixls.us and from the user's own photos.

**Profiling.** Performance is measured with Instruments, using Metal System Trace, the Allocations instrument and the energy log.

**Continuous integration.** GitHub-hosted macOS runners have limited GPU access, so GPU tests run on a self-hosted Apple Silicon Mac. CPU-only tests run on GitHub's hosted runners.

---

## 13. Phase 0 Spike (2–3 weeks)

**Goal:** prove the riskiest assumptions before any UI work begins: the zero-copy ingest path, GPU demosaicing, color correctness and EDR display.

### Tasks

1. **Repository setup.** Create the GPLv3 repository with Swift packages as laid out in §4. Build LibRaw from source as an arm64-only XCFramework, compiled with OpenMP disabled; Latent handles parallelism itself.
2. **Zero-copy ingest.** Memory-map the file, call `open_buffer`, and unpack. Evaluate three ways to get LibRaw's output into GPU-visible memory:
   - **(a)** Wrap LibRaw's own allocation with `makeBuffer(bytesNoCopy:)`. This works if the allocation happens to be page-aligned with a length that is a multiple of the page size.
   - **(b)** Maintain a small LibRaw patch that makes it allocate its raw buffer through Latent's page-aligned allocator.
   - **(c)** Accept a single copy. At unified-memory bandwidth, copying roughly 48 MB takes a few milliseconds.

   Measure all three. Choose (c) unless the copy measurably matters, since it avoids carrying a patch on LibRaw.
3. **First kernels:**
   - Black/white levels and white balance, in one fused kernel.
   - Bilinear demosaic, as the correctness baseline.
   - An RCD demosaic ported from RawTherapee.
   - Camera matrix conversion to linear Rec.2020, and exposure.
   - A basic display transform.
4. **Viewport.** Build a minimal AppKit window with a `CAMetalLayer` configured for EDR, with pan and zoom, redrawing only when something changes.
5. **Verification:**
   - Render D750 and A7 III files and compare them against RawTherapee using a neutral profile.
   - Use Instruments to confirm the number of copies and the end-to-end timing.
6. **Check Metal 3 vs. Metal 4 API boundaries.** Confirm, against current Apple documentation, exactly which APIs (residency sets, tensors, in-shader ML) are Metal 3.x (available on Sequoia) versus Metal-4-only (Tahoe-only), since the dual-OS requirement (§1) depends on getting this boundary right rather than assumed.

### Exit criteria

Phase 0 is complete when all of the following hold:

- D750 and A7 III files render with correct colors, matching RawTherapee's neutral output within tolerance.
- The path from memory-mapped file to GPU involves at most one copy, measured in Instruments.
- Initial timing targets on an M3 are met for 24 MP images; these targets will be revised after the first measurements:
  - GPU time for the full-resolution RCD demosaic plus color stages: under 30 ms.
  - Time from opening a file to seeing it on screen: under 300 ms.
- An idle window uses about 0% CPU and GPU.

---

## 14. Roadmap

| Phase | Scope | Exit criteria |
|---|---|---|
| 0. Spike | See §13 | See §13 |
| 1. Core pipeline | Highlight reconstruction, sigmoid tone mapping, stage cache, viewport-resolution rendering, tiled zoom, GPU scopes | Slider-to-screen latency under 16 ms at fit-to-window |
| 2. Catalogs | Folder catalogs, schema, XMP read/write, reconciliation, subfolder modes, grid view, ratings, flags and keywords | Scrolling a 20,000-image folder stays smooth; the catalog rebuilds from sidecars alone |
| 3. Import | **Dropped (September 2026).** Users copy files into a folder themselves; opening that folder in Latent creates its catalog in place. §6 is kept for reference only. | — |
| 4. Pro pipeline | Lens corrections (Lensfun, embedded data, manual), denoise, sharpening, color grading, process versions | All current lenses are corrected automatically |
| 5. Local edits | Parametric masks; AI masks from Vision and Core ML | AI mask generated in under 1 second |
| 6. Output | Export queue, ICC soft-proofing, HDR gain-map export, DNG export | Batch export keeps the GPU busy without stalling the UI |
| 7. Polish | Presets, copy/paste settings, snapshots, history, keyboard workflow | Beta release |
| v1.x | X-Trans support, ML denoising, Pixel Shift, cross-catalog search UI | — |

---

## 15. Risks

| Risk | Mitigation |
|---|---|
| Demosaic and color quality falls short | Port proven GPLv3 algorithms and gate every change on golden-image tests |
| LibRaw updates break decoding for a camera | Pin the LibRaw version and run the per-camera test matrix in CI |
| The SQLite database and XMP sidecars drift apart | Sidecars are authoritative, writes are atomic, and the database can always be rebuilt |
| Metal 3/4 API boundary assumed wrong | Keep Metal code inside `PixelEngine`; verify the Sequoia/Tahoe API boundary in Phase 0 (task 6); gate anything Tahoe-only behind `#available` |
| Network volumes corrupt the database | Detect the volume type and switch journal mode accordingly |
| Algorithm changes alter old edits | Process versioning, plus freezing the Lensfun database version in each edit |

---

## 16. Open Items

- **Namespace owner.** Decide the GitHub owner used in the `latent:` namespace URI. It must be fixed before the first public release.
- **Name availability.** Confirm "Latent" is available as a GitHub name and isn't used by an existing photo app.
- **Tokina vignetting.** Validate the borrowed Canon EF vignetting profile against real shots from the Nikon F version.
