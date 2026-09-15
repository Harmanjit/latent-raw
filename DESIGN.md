# Latent — Design Document

**Status:** Beta. All roadmap phases (§14) are implemented, except where marked dropped or not done. Brought in line with the code on 2026-09-14, after the wave that added the folder sidebar, HDR gain-map export, tone ranges and the Help window. This document began as the pre-code plan; where the code deliberately differs, the text describes the code and a **Decision:** note gives the reason.
**License:** GPLv3 (FOSS).
**Platform:** macOS only, on Apple Silicon. Verified on M1 Pro and M4; the original plan said M3 or newer, but nothing in the code needs M3 features. Must run correctly on both **macOS 15 (Sequoia)** and **macOS 26 (Tahoe)** — that's a hard requirement, not a "latest OS only" target as originally scoped. Metal **3** is the baseline (it's what Sequoia has); Metal 4, which shipped with Tahoe, may only ever be used for optional fast paths gated behind `if #available(macOS 26, *)`, never as a hard dependency; today no Metal-4-only API is used (PHASE0.md §6). See `Sources/PixelEngine/GPUContext.swift` for where that boundary lives in code.

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
- Distribution through the Mac App Store. The GPL is incompatible with Apple's store terms. The plan was notarized builds from GitHub Releases, Sparkle for updates and a Homebrew cask; today the app is built from source and ad hoc signed (§4a). There is no prebuilt download, no updater and no cask.

---

## 2. Efficiency Rules

Every design decision is checked against these rules.

1. **Never do work twice.** Every expensive result, whether a pipeline stage output, a thumbnail or an index entry, is cached and keyed by the inputs that produced it.
2. **Never do work that isn't visible.** Interactive rendering runs at viewport resolution. Full-resolution work happens only for zoomed-in tiles and for export.
3. **Never copy what can be shared.** Buffers live in unified memory and are passed between the CPU, GPU and ANE by reference, as `MTLBuffer`s, IOSurfaces or `CVPixelBuffer`s.
4. **Zero cost when idle.** There is no polling and no continuous display-link loop (the viewport's display link runs only while a frame is waiting to be shown, §8.3), and nothing is written to disk while a slider is being dragged.
5. **Read each file only as much as needed.** Opening a folder compares name, size and modification time before reading anything, and the catalog pass reads EXIF and the embedded preview without unpacking sensor data. (The original rule described the single-pass import, which was dropped; see §6.)
6. **Use the cheapest representation that works.** A thumbnail comes from the embedded JPEG before any raw decode. An edited thumbnail bins the sensor data on the GPU instead of demosaicing (§10).
7. **Background work runs on efficiency cores.** Thumbnail generation runs at `.utility` or `.background` quality-of-service (QoS). Only interactive rendering runs at `.userInteractive`. Decoding the thumbnails the grid is showing is interactive and runs at `.userInitiated` (§10).

---

## 3. Technology Stack

| Layer | Choice | Notes |
|---|---|---|
| Application shell and inspector panels | Swift 6 + SwiftUI | Strict concurrency from day one |
| Heavy views (thumbnail grid, filmstrip, folder sidebar, image viewport) | AppKit (`NSCollectionView`, `NSOutlineView`, a custom `NSView` hosting a `CAMetalLayer`) | Precise control over scrolling and cell reuse at scale |
| Pixel processing | Metal 3 compute kernels written in Metal Shading Language (MSL) | `rgba16Float` intermediates throughout (§7.2); no Metal-4-only API is used |
| RAW unpacking and metadata | LibRaw 0.22.2, pinned by commit in `scripts/build_libraw.sh`, vendored as an XCFramework | Unpacks sensor data only; demosaicing is done by Latent on the GPU. Runs in a sandboxed XPC service in the app bundle (§4a) |
| Algorithm references | darktable and RawTherapee (both GPLv3) | Source for the RCD demosaic port, highlight reconstruction and sigmoid tone mapping |
| Lens corrections | Lensfun XML database (copied at a pinned commit), read by a pure-Swift parser in `LensKit` | The database ships as bundle resources; no Lensfun C library or glib |
| Color management | ColorSync through vImage | ICC transforms and soft-proofing |
| Camera profiles | LibRaw camera matrices | No DCP support yet |
| Metadata and XMP | LibRaw for catalog EXIF; Foundation `XMLDocument` for sidecar reads, a string template for writes. Exports carry the photo's own EXIF, GPS, IPTC and XMP, read with ImageIO inside the decoder service (`SourceMetadata`, §8.5) | Sidecars hold only the properties in §5.5 |
| Catalog database | SQLite via GRDB.swift 6.29.3 (exact version) | One database per catalog folder |
| Checksums | xxHash (XXH64), implemented in Swift | |
| Machine learning | Core ML (GPU by default, §8.4) and the Vision framework | Masking and AI denoise |
| Export | ImageIO (JPEG, HEIC, TIFF, PNG) | SDR main image, with an optional ISO 21496-1 HDR gain map for JPEG and HEIC (§8.5). HEIC encoding uses the hardware HEVC encoder |

**Decision:** the planned LittleCMS, Exiv2, Lensfun C library, Adobe DNG SDK, libjxl and Sparkle were not adopted. System frameworks (ColorSync, vImage, Foundation) and small Swift code cover what Latent actually uses: its own sidecars need no MakerNote or foreign-XMP support, and Lensfun's value is its database, not its library. DNG and JPEG XL export were not built, and there is no updater. LibRaw is the only C/C++ dependency; it sits behind a narrow C shim (`Sources/RawCore/CLibRaw`).

---

## 4. Package Structure

One Swift package (`Package.swift`, tools 6.0, macOS 15). The only external package is GRDB.swift, pinned to an exact version.

| Target | Kind | Responsibility | Depends on |
|---|---|---|---|
| `CLibRaw` | C target | Narrow C shim over LibRaw's C++ API | `vendor/LibRaw.xcframework` (binary target), zlib |
| `RawCore` | Library | LibRaw wrapper, memory-mapped file input, EXIF, embedded-preview extraction, the export metadata reader (`SourceMetadata`), the XPC decoder client and protocol | `CLibRaw` |
| `ColorKit` | Library | Camera matrices, white balance, working-space math | — |
| `LensKit` | Library | Lensfun XML parser and bundled database, lens matching, correction coefficients | `RawCore` |
| `PixelEngine` | Library | Metal pipeline and kernels, stage cache, edit stack, crop, healing, tone ranges, soft proof, export rendering and resampling, gain maps, safe file writes, memory-pressure monitoring; no UI | `RawCore`, `ColorKit`, `LensKit` |
| `Catalog` | Library | Folder catalogs, GRDB schema and migrations, XMP read/write, reconciliation, thumbnails and the thumbnail loader, folder access checks, export naming and batch planning | GRDB, `RawCore` |
| `MLKit` | Library | Core ML model store, shared models released under memory pressure, SAM 2.1 and SegFormer masks, Vision masks, AI denoise, `ExportWorker` | `PixelEngine` |
| `HelpKit` | Library | The Help window's content: the wiki's Markdown (`docs/wiki`) parsed into blocks, links between pages, search | — |
| `latent-rawdecoder` | Executable | The `LatentRawDecoder.xpc` service: decodes a file descriptor with LibRaw (§4a) | `RawCore` |
| `latent-cli` | Executable | Headless rendering and benchmarks | `RawCore`, `PixelEngine`, `Catalog`, `ColorKit` |
| `latent-app` | Executable | SwiftUI and AppKit views, the viewport, the grid, the folder sidebar and filmstrip, menus and the shortcut table, the export queue, the Help window | `RawCore`, `PixelEngine`, `ColorKit`, `Catalog`, `LensKit`, `MLKit`, `HelpKit` |

Test targets: `PixelEngineTests`, `CatalogTests`, `LensKitTests`, `MLKitTests`, `HelpKitTests` and `LatentAppTests` (§12).

`ColorKit`, `LensKit`, `Catalog` and `HelpKit` contain no C code of their own; `LensKit` and `Catalog` link LibRaw transitively through `RawCore`. **Decision:** `ExportWorker` lives in `MLKit`, not `PixelEngine`, because a faithful export must regenerate model masks (§8.4) and only `MLKit` can. The planned `AppUI` library became the `latent-app` executable target.

---

## 4a. Security Architecture

LibRaw parses files Latent did not create, so the design assumes a crafted file can exploit it and limits what that exploit reaches.

| Measure | Detail |
|---|---|
| App Sandbox, hardened runtime | Both the app and the decoder service are signed with `--options runtime` and sandbox entitlements (`scripts/make_app.sh`) |
| App entitlements | `scripts/Latent.entitlements`: sandbox, user-selected files read-write, app-scope security-scoped bookmarks. No `network.client`, so the OS forbids network access |
| Bookmarks | The last folder, the export destination and each favourite folder in the sidebar are kept as security-scoped bookmarks, so they reopen on the next launch without a panel. A favourite grants access to everything inside it. Bookmarks resolve without mounting volumes or showing UI; a favourite whose disk is away shows as not connected |
| Raw decoding out of process | `LatentRawDecoder.xpc` (`scripts/LatentRawDecoder.entitlements`: sandbox only) has no file access and no network. The app opens the file and passes a file descriptor over XPC (`Sources/RawCore/RawDecoderXPC.swift`). The service has two calls. `decode` returns metadata and the embedded preview as `Data`, and the sensor plane as a shared IOSurface. `readMetadata`, used by exports, returns two size-capped binary property lists: ImageIO's property dictionaries with structural tags removed, and the XMP tags as a tree of plain dictionaries. The app rebuilds XMP through ImageIO's tag API and never parses an XMP packet the service produced. A crash invalidates the connection, the app shows an error, and the next call starts a fresh service |
| Help window | Shows the wiki pages copied into the bundle (`Contents/Resources/Help`). Nothing is fetched. Links are bare page names, `Page#anchor`, `http(s)` or `mailto`; web and mail links open in the user's browser or mail app, and anything else (file URLs, paths outside the pages) is refused |
| Signing | Ad hoc (`--sign -`), not notarised: there is no Apple developer account. Gatekeeper warns once on any other Mac |

`swift run` and `swift test` have no bundled service, so they decode in process. `LATENT_RAW_INPROCESS=1` forces in-process decoding only in a debug build: a release bundle can't be told to parse raw files outside the service. `scripts/make_app.sh` always builds release (with `--dev` too), so the switch does nothing in any bundle the script makes. Other debug-only switches, such as the snapshot harness (§12), are compiled only under `#if DEBUG`; a release build neither reads them nor carries the code. `make_app.sh --dev` builds without sandbox entitlements.

**Decision:** decoder isolation must not cost extra copies of the sensor plane. The plane crosses the process boundary as shared memory (§7.1).

A dormant model-download path (`MLKit/OptionalModels.swift`, `EditorModel.downloadHighQualityModel` in `EditorModel+Denoise.swift`) exists but no view calls it; it would need the network entitlement added back.

**Exports and location.** With metadata on (the default), exports carry the photo's own artist and copyright along with the camera tags. Location is a second switch, off by default and in presets saved before it existed: off, `SourceMetadata.locationTags` leaves out the GPS dictionary, IPTC and XMP place names, and the body and lens serial numbers (Exif, ExifAux and `aux:` XMP), since a serial number links a photographer's photos as a position does; artist, copyright and the camera owner's name stay. The export sheet and, for Export Open Image, the left panel carry both switches.

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
- **Optional interoperability.** Planned: a setting, off by default, that also writes a minimal XMP file next to each image, containing only the rating, label and keywords, where Lightroom and darktable look for sidecars. **Not implemented.**

### 5.2 Subfolder modes

Each catalog records a mode for each of its subfolders, set per folder by the user:

| Mode | Behavior |
|---|---|
| `included` | The subfolder's images belong to the parent catalog. Their sidecars and thumbnails are stored under mirrored subpaths inside the parent's `xmp/` and `thumbnails/` folders. |
| `independent` | The subfolder has its own `_latent/` container and is a separate catalog. |
| `ask` | The user is prompted the first time Latent finds the subfolder. |

Each catalog also has a default mode (stored in `settings`, `ask` if unset) that applies to newly discovered subfolders.

The plan was for converting a subfolder between `included` and `independent` to be a single transactional operation: sidecars and thumbnails moved with same-volume renames, database rows moved, old rows deleted in one transaction.

**Known gap:** modes are stored only in the `subfolders` table, not in any sidecar, so rebuilding the database resets them. Setting a mode writes that row and rescans; no sidecars or thumbnails are moved.

**Opening an included subfolder on its own.** A folder that the nearest enclosing catalog already includes opens that enclosing catalog instead (`FolderAccess.owningCatalog`). Giving the subfolder a container of its own would make the parent treat it as independent and drop its images.

### 5.3 Source of truth and redundancy

| Store | Role |
|---|---|
| XMP sidecar | **Authoritative.** Holds the complete edit stack, rating, label, keywords, snapshots and the source checksum. |
| `catalog.sqlite` | **Index and cache.** Makes grid filtering, sorting and search fast. It can be deleted at any time and rebuilt from the sidecars. |

**Damaged database.** When SQLite reports `catalog.sqlite` as corrupt or not a database, `Catalog.open` moves it, with its `-wal` and `-shm` files, to `catalog.damaged-<date>.sqlite` in the same `_latent/` folder (never deleting it), starts a fresh database and reports where the old one went. The next reconcile fills the new database from the sidecars. The app says so in a dialog, because subfolder modes lived only in the damaged file and will be asked again (§5.2). A database that can't be moved aside fails to open as before.

**Write order.** Each edit is committed in two steps:

1. Commit a SQLite transaction.
2. Write the XMP to a temporary file in `xmp/`, then atomically rename it over the old sidecar.

**Debouncing.** No writes happen while a slider is being dragged. An edit is persisted when the slider is released or after about one second of inactivity. Quitting saves a pending edit at once and waits for catalog writes to finish (§11).

**Folder switches.** Before another folder opens, the editor saves its pending edit and closes its image. Every edit, history and snapshot write names the catalog it belongs to, because an image id means a different photo in the next catalog, and an image load that finishes after the switch is dropped.

**Reconciliation when a folder opens.** Latent lists the directory and compares each file's name, size and modification time against the database. It then compares each sidecar's modification time against the value recorded in the database, and re-parses only the sidecars that changed. An unchanged folder opens without decoding a single image.

**Renamed files.** If a file appears under a new name with no sidecar, Latent looks up its xxHash (XXH64) checksum in the database and reattaches the existing sidecar.

**No live watching.** Latent does not use FSEvents or any other file watching on external volumes. Reconciliation runs only when a folder is opened. `Library.refresh` exists, but the app has no Refresh command; opening the folder again re-scans it.

**Network volumes.** SQLite's write-ahead log (WAL) journal mode does not work reliably on SMB or NFS shares. Latent detects the volume type and uses WAL on local and external drives, and the rollback journal on network shares.

### 5.4 Database schema

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
  thumb_key BLOB,                       -- hash of the edit that produced the thumbnail
  user_rotation INTEGER NOT NULL DEFAULT 0  -- migration v2: manual quarter turns clockwise
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

Migrations are in `Sources/Catalog/Schema.swift` (`v1_initial`, `v2_user_rotation`). `user_rotation` is kept apart from `orientation` (what the camera recorded) so re-reading EXIF never clobbers a manual fix. The `lens_overrides` table exists but nothing reads or writes it yet.

No pixel data and no absolute paths are ever stored in the database.

Search across catalogs was planned with SQLite's `ATTACH`; it is not implemented. The app's preferences hold only settings and bookmarks for the last folder, the export folders and the sidebar's favourite folders (§4a); that is not a catalog. The sidebar lists folders with `readdir` and touches no catalog until a folder is clicked.

### 5.5 XMP format

```xml
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:xmp="http://ns.adobe.com/xap/1.0/"
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    xmlns:xmpMM="http://ns.adobe.com/xap/1.0/mm/"
    xmlns:latent="https://github.com/Harmanjit/latent-raw/ns/1.0/"
    xmp:Rating="4"
    xmp:Label="Green"
    xmpMM:PreservedFileName="DSC_0001.NEF"
    latent:SchemaVersion="1"
    latent:ProcessVersion="1.0"
    latent:SourceHash="xxh64:9f2c4b..."
    latent:Flag="1"
    latent:Rotation="0">
   <dc:subject><rdf:Bag><rdf:li>Yosemite</rdf:li></rdf:Bag></dc:subject>
   <latent:EditStack><![CDATA[ { ...edit JSON... } ]]></latent:EditStack>
   <latent:Snapshots><![CDATA[ [ ... ] ]]></latent:Snapshots>
   <latent:History><![CDATA[ [ ... ] ]]></latent:History>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
```

`latent:Flag` is -1 rejected, 0 none, 1 picked. `latent:Rotation` is the manual quarter turns clockwise (the `user_rotation` column). `latent:Snapshots` and `latent:History` are JSON, omitted when empty. Readers match properties by local name, so sidecars written before the rename with the `rawhead:` prefix still load.

The namespace URI never needs to resolve to a real page, but once released it must never change. Standard XMP properties are used wherever they exist.

### 5.6 Edit stack JSON

```json
{
  "schema": 1,
  "process": "1.0",
  "modules": {
    "whitebalance": { "mode": "custom", "temperature": 5200, "tint": 4 },
    "exposure":     { "ev": 0.7 },
    "tone":         { "method": "sigmoid", "contrast": 1.4, "grey": 0.18 },
    "highlights":   { "strength": 1.0, "threshold": 0.95 },
    "demosaic":     { "method": "rcd" },
    "denoise":      { "luminance": 0.2, "color": 0.3 },
    "sharpen":      { "amount": 0.5, "radius": 1.0, "threshold": 0.02 },
    "lens":         { "distortion": true, "tca": true, "vignetting": true,
                      "manualDistortion": 0, "manualVignetting": 0,
                      "profile": "Nikon AF-S Nikkor 50mm f/1.4G",
                      "lensfunDb": "2026-09-11" },
    "toneranges":   { "highlights": -0.3, "shadows": 0.4, "whites": 0, "blacks": 0 },
    "curve":        { "points": [[0, 0], [0.5, 0.55], [1, 1]],
                      "red": [[0, 0], [0.5, 0.52], [1, 1]] },
    "hsl":          { "hue": [0,0,0,0,0,0,0,0], "saturation": [0,0,0,0,0,0,0,0], "luminance": [0,0,0,0,0,0,0,0] },
    "splittoning":  { "shadowHue": 220, "shadowSaturation": 0.1,
                      "highlightHue": 40, "highlightSaturation": 0.1, "balance": 0 },
    "vibrance":     { "amount": 0.2 },
    "presence":     { "texture": 0.1, "clarity": 0.2, "dehaze": 0 },
    "defringe":     { "purple": 0.5, "green": 0 },
    "perspective":  { "vertical": 0.1, "horizontal": 0 },
    "aidenoise":    { "strength": 0.6, "model": "nafnet-sidd-w32" },
    "locals":       [ ... ],
    "heal":         [ ... ],
    "crop":         { "cx": 0.5, "cy": 0.5, "w": 0.9, "h": 0.9, "angle": 1.5 }
  }
}
```

The structure is `EditStack` in `Sources/PixelEngine/EditStack.swift`. Every module key is optional: an old sidecar lacking a key gets that module's default, and a key this build does not know is ignored. There is no `enabled` flag; a module at its neutral value is the off state. `locals`, `heal`, `presence`, `vibrance`, `defringe`, `perspective`, `aidenoise`, `toneranges` and `crop` are omitted when neutral; the rest are always written. Inside `curve`, `points` is the master curve and the optional `red`, `green` and `blue` point lists are left out while straight. Rotation is not in the stack (it is catalog metadata, §5.5), nor is the output color space (an export choice). Model masks store their kind or clicks plus a model version, never pixels (§8.4).

**Decision:** modules are keyed by name with their parameters directly inside, rather than the planned `enabled` flags, `rawprepare` and `masks` keys and a top-level `crop`. Neutral values already mean "off", and a flat module map keeps additions purely additive.

**Process version.** Every edit records the pipeline version it was created with (`1.0`). The intent is that when algorithms improve, existing edits keep rendering the same way until the user explicitly upgrades them. Only one process version exists so far, and there is no pinning or upgrade flow yet. That has already cost something: in September 2026 spot healing changed from one rim ratio to a ratio field (§8.1), still under `1.0`, so existing heal patches now render differently from when they were made (§15).

**Frozen lens profiles.** Each edit records which lens profile and Lensfun database version (the bundled copy's date) supplied its corrections. Only the bundled database is loaded, so the recorded version is provenance, not yet a selector.

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
2. LibRaw unpacks the sensor data into its own allocation.
3. LibRaw's plane is copied once into an IOSurface (`Sources/RawCore/SensorPlane.swift`), and LibRaw is closed straight away, freeing its own allocation.
4. `GPUContext.makeSharedBuffer(wrapping:)` wraps the surface's pages as a shared-storage `MTLBuffer` with `makeBuffer(bytesNoCopy:)`. The GPU kernels read the very pages LibRaw's output was copied into.

The path is the same wherever decoding runs:

| Build | Path | Copies of the sensor plane |
|---|---|---|
| App bundle | In `LatentRawDecoder.xpc` (§4a): LibRaw's allocation → IOSurface in the service → XPC passes the surface by reference → the app wraps it as the `MTLBuffer` | One |
| `swift run`, `swift test` | In process: LibRaw's allocation → IOSurface → `MTLBuffer` | One |

An IOSurface is page-aligned, a whole number of pages, and transferable over XPC as a mach port rather than bytes, which is what both halves need. The app checks the service's claimed sample count against the surface's real size before reading.

**Decision (September 2026):** replaced the earlier bundle path (LibRaw → `Data` → XPC → host buffer → `MTLBuffer`, with the host buffer held for the whole session). Measured on the D750 sample through the sandboxed service: peak resident memory 321 MB → 223 MB, open time unchanged (about 235 ms, dominated by LibRaw), output byte-identical. `SensorPlaneTests` asserts that the session's `MTLBuffer` is the plane's own memory.

### 7.2 Storage-mode policy

Buffers are assigned a Metal storage mode depending on which processors touch them:

| Buffer | Storage mode | Reason |
|---|---|---|
| Raw sensor input | Shared | Written by the CPU, read by the GPU |
| Demosaiced image and pipeline intermediates | Private, `rgba16Float` | GPU-only |
| Histogram and scope results | Shared | Small, and read back by the CPU |
| Export readback | Shared | Read by ImageIO |
| Thumbnails, previews and ML inputs | `CGImage` and Core ML buffers | Built from a readback; the planned IOSurface sharing was not built |

**Precision.** Image intermediates, scene-linear stages included, are `rgba16Float`; single-channel scratch textures are `r16Float` or `rg16Float`. The one exception is the white-balanced CFA plane that feeds demosaic, which is `r32Float` because half precision flips RCD's directional decisions. **Decision:** this replaces the planned FP32-for-scene-linear rule; only demosaic showed a precision problem.

**Memory reuse.** `ImageSession.texture(width:height:pixelFormat:role:)` keeps one pooled private texture per role (CFA, camera RGB, RCD scratch, denoised, healed, lens-corrected, display, presence, sharpened, and preview variants) and hands it back whenever size, format and role match. A second render with the same key overwrites the first.

**Memory pressure.** `MemoryPressureMonitor` passes the system's warning and critical levels to the editor (`EditorModel+Memory.swift`). A warning drops the session's pooled textures and demosaic cache, the shared Core ML models (`SharedModel`, which reload from their compiled copies on disk), and the SAM 2 image encoding unless click-to-select is in use. Critical also drops the encoding regardless, the brush mask rasters and the AI denoise result, which runs again (about 11 s) once pressure returns to normal. The layers on screen keep their own textures, so the picture doesn't change until the user acts. A pane that isn't on screen (Compare's Select pane outside Compare) closes its image instead. The thumbnail loader halves its memory cache on a warning and empties it on critical (§10). On Macs with 8 GB or less (`MemoryPolicy`), Compare's Select pane closes its image as soon as Compare is left.

**Decision:** no `MTLHeap` aliasing and no `MTLResidencySet`. Phase 0 deferred residency sets until they are wanted (PHASE0.md §6), and the per-role pool already reuses memory across renders, so heap aliasing was not adopted.

**On-chip memory.** The planned use of threadgroup memory for neighborhood kernels was not generally adopted; threadgroup memory is used by the histogram kernel. Stages run as separate kernels within one command buffer per render (§8.1).

---

## 8. Processing Pipeline

### 8.1 Fixed module order

The modules always run in this order (`RenderPipeline.renderStages`). Every stage of one render is encoded into a single command buffer and submitted once.

In camera space:

1. **Black level and white balance,** in one kernel, producing the CFA plane.
2. **Demosaic:** RCD, or bilinear. Binned previews replace steps 1 and 2 with one fused kernel that bins Bayer quads straight from the sensor buffer, with no demosaic. This output is cached (§8.2).
3. **AI denoise blend:** the session's cached full-frame NAFNet result, re-binned and re-white-balanced to match the render, blended by strength (§8.4).
4. **Classic denoise** (luminance and color).
5. **Spot heal,** patches applied in order, each reading the image as the earlier ones left it (`Heal.metal`). Clone copies the source. Heal multiplies the source by a ratio field: the target's surroundings over the source's, each a Gaussian blur (sigma half the radius) that masks out the patch and renormalises, computed on a coarse grid of up to a quarter sigma per cell. Tone and colour then match along the whole edge and follow gradients across the patch.
6. **Lens corrections:** distortion, TCA, vignetting, manual sliders and perspective.

Then the `colorAndTone` kernel (`Shaders/ColorPipeline.metal`), per pixel:

7. **Highlight reconstruction,** in camera space where clip levels are meaningful.
8. **Camera matrix** to linear Rec.2020.
9. **Exposure,** then **Highlights, Shadows, Whites and Blacks** (`ToneRanges.swift`): a per-pixel exposure gain looked up from a table by the pixel's luminance on the sigmoid's log scale, t = contrast × log2(Y / mid grey). Global and hue-preserving, with slopes limited so no tone overtakes a brighter one; mid grey is outside every band. Skipped when all four are zero, and in analysis renders.
10. **Local adjustments with masks,** in scene-linear. Range masks evaluate the pixel before any local changes it.
11. **Sigmoid tone map,** scene-referred to display-referred, up to the render headroom: 1 for files and soft proofing, 4 for a gain map's HDR rendition (§8.5), and for the viewport the screen's potential headroom, capped at 4 (§8.3).
12. **Grading:** tone curve (master, then red, green and blue), HSL, vibrance, split toning, in a perceptual domain scaled by the headroom.
13. **Soft proof** (optional; with gamut warning).
14. **Output transform and encode:** working space to output space, then the sRGB curve for files, or linear extended range for the EDR viewport.

Display-referred, after `colorAndTone`:

15. **Presence:** texture, clarity, dehaze and defringe.
16. **Sharpening.**

**Geometry.** Crop, straighten and rotation are not pipeline stages. They are applied as a sampling map from `CropFrame` (`Crop.swift`) when the result is presented (`Presenter`) or exported (`Exporter`).

**Decision:** the order differs from the plan. Highlight reconstruction moved after demosaic but stays before the matrix; denoise, heal and lens corrections run in camera space before color so they see sensor-like data; local adjustments act in scene-linear before the tone map; flat-field correction, AMaZE and DCP profiles were not built. Precision is covered in §7.2.

### 8.2 Caching and resolution

**Stage cache.** Only the demosaic output (camera RGB) is cached, per `ImageSession`, keyed by the white balance multipliers, the demosaic method and the region or bin factor (`ImageSession.StageKey`). Exposure, tone, grading and detail edits hit the cache; white balance and zoom changes miss. Everything after demosaic re-runs on every render, in the one command buffer. The cache lives in GPU memory only and is never written to disk. The AI denoise result is held separately per session (§8.4); critical memory pressure can drop it (§7.2).

**Decision:** the planned per-stage cache keyed by all upstream parameters was not built. Demosaic is the expensive stage; the rest re-render a fit-to-window preview in a few milliseconds.

**Viewport-resolution rendering.** Fit-to-window editing renders a binned preview: Bayer quads binned by the largest factor that keeps the image at least as large as the viewport (`RenderScale.fitting` → `.binned`), with no demosaic. If no binning fits, the whole frame renders at full resolution.

**Zooming in.** When the user zooms to 100%, only the visible tiles are rendered at full resolution.

**Full-resolution rendering.** Full-resolution renders happen only for export, or asynchronously when the viewport needs them.

### 8.3 Display

The viewport is a `CAMetalLayer` with the `rgba16Float` pixel format and extended linear Display P3 (`MetalImageView.swift`).

**Headroom.** The pipeline renders to the screen's *potential* EDR headroom, capped at 4× SDR white (`DisplayHeadroom.renderCeiling`), which doesn't move with the brightness setting. Each present rolls highlights off to the headroom the screen shows at that moment (the present kernel's `toneMapToHeadroom`), so a brightness change costs a present, not a render. Moving to a screen with a different potential headroom re-renders only if that changes the capped ceiling. With HDR display off, while soft proofing, or on an SDR screen, the render uses headroom 1.

**EDR policy.** `wantsExtendedDynamicRangeContent` is on only while the image on screen was rendered with headroom above 1 and the screen can show some of it. EDR raises the backlight and costs power, so it stays off otherwise.

**Presenting.** The view redraws only in response to user input, a finished render or a screen change, never continuously. Presents go through an `NSView` display link that runs only while a frame is pending, so several requests in one refresh interval draw once. A frame identical to the one on screen (same render generation, transform, crop, surround, drawable size and headroom) is skipped.

**Scopes.** The histogram, waveform and vectorscope are computed on the GPU using per-threadgroup atomic histograms that are then reduced into one result. The histogram also counts luminance (drawn as an outline), pixels above SDR white (shown while the viewport renders with headroom) and shadow clipping per channel. Scope measurements run at most once per 100 ms while a slider is dragged, with a trailing update.

### 8.4 Masking

**Parametric masks.** Brush, linear gradient, radial gradient and luminance or color range masks are stored as parameters and rasterized on the GPU when needed.

**AI masks.** Model masks run through Core ML (`MLKit`):

- **Click-to-select:** SAM 2.1 small (image encoder, prompt encoder, mask decoder, FP16). The clicks are stored; about 40 ms per click.
- **Class masks:** SegFormer-B2 fine-tuned on ADE20K (sky, people and other classes). Without the model, sky falls back to a heuristic and people to Vision.
- **Subject:** the Vision framework's foreground-instance request.

Model masks are stored as parameters (kind or clicks, plus model version) and regenerated from a small render of the image when needed, then cached in memory; mask pixels are never stored. Export regenerates them the same way (`ExportWorker`).

**Compute units.** Core ML models load with `.cpuAndGPU` by default. The Neural Engine is opt-in (a Settings choice, or `LATENT_ML_COMPUTE=all`) because on macOS 15.7 the ANE compiler hangs at model load for SAM 2 and SegFormer (`CoreMLStore.swift`). **Decision:** a hang is not worth a few tens of milliseconds; the GPU is fast enough.

**AI denoise.** Shipped, not deferred to v1.x. NAFNet trained on SIDD, width 32, bundled as Core ML, runs once per image on the full frame in 256×256 overlapping tiles, on the GPU by default. The result is cached in the session as camera RGB and blended into every render by a strength slider (§8.1 step 3). The edit stores the strength and model name. A width-64 model exists as an optional download that is not exposed (§4a). Critical memory pressure drops the cached result, and it runs again when pressure returns to normal (§7.2).

### 8.5 Export

Exports go through `ExportWorker` (`MLKit`), whether they come from the export queue or from Export Open Image in the left panel, so the two write identical files. Per image:

1. Open the raw, rebuild the edit over the image's defaults (`ExportPlan`), regenerate model masks and, if the edit uses it, run AI denoise.
2. Render the SDR image. A resized export renders binned towards the target size (`ExportPlan.scale`); the exporter then rotates, crops and shrinks to the exact size on the GPU with a Lanczos 3 filter evaluated in linear light (`ExportResampler`), and quantises to 8 or 16 bits. A full-size export skips the resample pass.
3. **Gain map** (JPEG and HEIC, off by default, `GainMap.swift`). After the SDR pixels and the gain map's half-size linear base, the same edit renders again with headroom 4, reusing the pooled textures; a kernel computes the per-channel gain in stops over a fixed range derived from the tone curve, and the map goes to ImageIO as ISO 21496-1 auxiliary data. The main image is byte for byte the SDR export.
4. **Metadata** (on by default, location off; both switches in the export sheet and, remembered, in the left panel for Export Open Image). The photo's own EXIF, GPS, IPTC, ExifAux and XMP are read in the decoder service (§4a). Removed: storage tags (compression, CFA pattern, orientation, pixel size, colour space, subject area and location, focal-plane resolution, AF areas), makers' private blocks, the source's document and instance IDs, and the `crs`, `hdrgm` and `HDRGainMap` namespaces. Summary fields from LibRaw fill gaps. Latent's keywords are added to the file's own; its rating replaces the file's when above 0. Software is Latent, orientation 1, Exif ColorSpace 1 for sRGB and 0xFFFF otherwise. No embedded thumbnail. Without location, the tags in `SourceMetadata.locationTags` (GPS, place names, body and lens serial numbers) are removed from the dictionaries and the XMP. With metadata off, the file carries no camera, date, location, keywords or rating. The fallback capture date is formatted in the Gregorian calendar with a POSIX locale.
5. **Writing** (`SafeFileWriter`). The file is written under a hidden temporary name in the destination folder, flushed, then moved into place; a replaced file keeps its creation date, permissions and Finder tags. A crash, full disk, encoder error or cancelled export leaves no partial file and never costs the file that was there. Where the sandbox grants only the one file (a Save panel), the temporary file goes in the system's item-replacement folder on the same volume. A write that may not replace (a new name under Add a number or Skip, or a Save panel name that was free) is moved into place with `renamex_np(RENAME_EXCL)`, so a file that appeared during the render is kept and the queue settles the name again.

**Naming.** The queue plans every file name for the whole batch before writing anything (`ExportBatchPlanner`), so the sheet's preview and warnings match what gets written. Images whose template gives the same name are always numbered; names already in the destination follow the collision policy (add a number, replace, skip); an unknown token in the template disables Export. Each planned name is checked against the disk again just before its file is written.

---

## 9. Camera and Lens Support

### 9.1 Cameras

| Camera | Format | Notes |
|---|---|---|
| Nikon D750 | NEF, 14-bit lossless or 12-bit | Mature LibRaw support |
| Sony A7 III (ILCE-7M3) | ARW, uncompressed or lossy-compressed | Lens-correction data is embedded in each file. Pixel Shift is deferred to v1.x |
| Canon EOS DSLR (model not specified) | CR2 and CR3 | Both formats are supported through LibRaw, so the exact model does not matter |

**Tested:** only the Nikon D750 has sample files in the test suite (`TestAssets/`). The Sony and Canon rows are LibRaw-supported but unverified in Latent.

**Sensor support:**

- **Renders:** Bayer CFAs only. Anything else throws `unsupportedCFAForV1`.
- **Not built:** monochrome sensors, linear DNG, and the planned CPU fallback for other formats. They open for metadata and thumbnails from the embedded preview but do not render.
- **v1.x:** X-Trans. No current body in use has an X-Trans sensor.

### 9.2 Lens correction sources

Latent picks a correction source separately for each correction type (distortion, chromatic aberration, vignetting), in this order:

1. A **Lensfun** profile for that correction type.
2. Correction data **embedded by the camera** in the raw file (Sony ARW).
3. **Manual** sliders, which can be saved as a per-lens preset.

The chosen source is recorded in the edit stack. When Nikon lens IDs are ambiguous for third-party lenses, the user's manual choice is remembered in the `lens_overrides` table.

**Status:** only sources 1 and 3 exist. `LensKit` matches a Lensfun profile from the lens identity (including MakerNotes names); otherwise manual distortion and vignetting sliders apply. Embedded ARW correction data, per-lens presets and `lens_overrides` are not implemented.

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

**Edited images.** Latent does a full LibRaw unpack of the raw file, then runs the edit pipeline with GPU binning (`RenderScale.binned`) at just under 512 px, so no demosaic runs (`EditedThumbnailRenderer`). The unpack (~200 ms) dominates the cost. This runs in the background after the edit settles, never while a slider is being dragged. AI denoise is not applied to thumbnails.

**Decision:** GPU binning instead of LibRaw's half-size mode. The binning kernel already exists for previews, and using the real pipeline keeps thumbnails consistent with the editor.

**Staleness.** The `thumb_key` column stores the hash of the edit that produced each thumbnail. A thumbnail is regenerated only when its key no longer matches the current edit.

**Larger previews.** Previews bigger than a thumbnail come from the embedded JPEG when needed and are never stored.

**Display** (`ThumbnailLoader`, used by the grid and the filmstrip). The HEIC files in `_latent/thumbnails/` are the disk tier; in front of them sits a byte-capped least-recently-used memory cache of 256 MB, less on Macs with under 8 GB (physical memory / 32, at least 64 MB). Requests run newest first, so the row the user stopped scrolling on decodes before the rows that flew past, and a request cancelled before its decode starts (the cell scrolled away) costs nothing. Decodes use all but two cores at `.userInitiated`. Cells that need 256 pixels or fewer ask for a 256 px decode of the one 512 px file, a quarter of the memory; a cached larger decode also serves a smaller request. Each thumbnail is drawn off the main thread, turned by the user's rotation, straight into the display's colour space and pixel format, so Core Animation has nothing to convert on the main thread. Under memory pressure the cache halves (warning) or empties (critical). The grid redraws only cells whose image or badges changed.

---

## 11. Concurrency

| Work | Quality of service (QoS) | Runs on |
|---|---|---|
| Viewport render, slider response | `.userInteractive` | Performance cores and GPU |
| Opening a folder, reconciliation | `.userInitiated` | Performance cores |
| Export | `.userInitiated` | GPU and media engines |
| AI mask generation, SAM 2 session setup | `.userInitiated` | GPU |
| Decoding visible thumbnails for the grid and filmstrip | `.userInitiated`, newest request first | Performance cores (all but two) |
| Thumbnail generation | `.utility` / `.background` | Efficiency cores |
| Sidecar writes | `.utility`, debounced | — |

The planned "Import" row is gone with import (§6).

The pipeline uses Swift structured concurrency throughout. Each catalog is an actor that owns its database connection.

**Launch.** The GPU context (device, command queue, shader library) is shared across the process and built off the main thread, so the window appears at once and an editor model may briefly report not ready. A bundle built by `make_app.sh` loads precompiled shaders when the Metal toolchain was installed; otherwise the shader sources compile at first launch (about 0.4 s).

**Catalog writes.** Ratings, keywords, saved edits, history, snapshots, batch paste and opening a folder go through `Library.perform`, which counts running operations. In the grid, rating, flag and rotation apply to every selected image the filter shows (a filter that hides selected images deselects them), each with its own row update and sidecar write, and rotation adds to the angle stored at the time of the write; a failure on one image doesn't stop the rest. In Loupe, Compare and Develop they apply to the image shown only, and so do pasted settings and presets; Compare's Select image is never written. Keywords apply to the lead image only.

**Quitting.** `applicationShouldTerminate` saves a pending edit at once, then waits up to 10 s for catalog writes to finish. If an export is running it first asks whether to stop after the image being written and quit, or keep exporting and not quit; stopping waits up to 60 s for that file, and a stopped export does not bring Finder forward. Export Open Image asks the same way (finish and quit, or keep working) and is waited for as long. A wait that runs out is logged and quitting goes ahead, first removing the temporary file of any write not yet committed (`SafeFileWriter.abandonPendingWrites`).

---

## 12. Testing

**Golden images.** `GoldenImageTests` renders a public-domain Nikon D750 raw (raw.pixls.us, CC0, fetched and checksum-verified by `scripts/fetch_test_assets.sh`) with fifteen fixed edits, one per area of the pipeline: as shot, exposure and tone, white balance, colour grading, tone ranges, channel curves, presence, detail, bilinear demosaic, geometry, heal and clone, the heal's ratio field, local adjustments, Display P3 output and 8-bit export. Each edit is saved to edit-stack JSON and goes through `ExportPlan`, the same code `ExportWorker` calls to rebuild the parameters, choose the render scale and the rotation; the exporter's GPU passes then rotate, crop, resize (the linear-light Lanczos 3 resample, §8.5) and quantise. Only ImageIO's file encode is left out. The result is compared, pixels and colour space, with 16-bit PNG references in `Tests/PixelEngineTests/Golden`: a 320-pixel overview of the frame, plus a 192-pixel full-resolution window of the in-focus detail where the edit is about fine detail.

A render fails if its mean absolute difference exceeds 0.0005 of full scale or its 99.9th-percentile pixel difference exceeds 0.005. Renders on one Mac are bit-identical, so the limits only absorb floating-point differences between GPU families. Three tests keep the harness honest: renders repeat exactly whatever was rendered in between (the stage cache and texture pool), the PNG references are lossless, and a 1/50 EV exposure change fails. When tuning the limits, a vibrance made 5% stronger inside the shader passed at 4x these limits and fails at them. On failure the render and an 8x difference image are written to `.build/golden-failures/`, which CI uploads as an artifact. An intended change of look is recorded with `LATENT_UPDATE_GOLDEN=1 swift test --filter GoldenImageTests`, and the new references are committed with the change that explains them.

**Not covered:** AI noise reduction (Core ML output differs between compute units, and a full run takes minutes), on-screen EDR presentation and gain maps. `GainMapTests` checks the map's gain range and that JPEG and HEIC maps rebuild the HDR render, and `ExportWorkerGainMapTests` (which needs a private sample, so it skips in CI) that an export writes a readable map; no reference image pins a map's pixels.

**Unit tests.** Six test targets, 327 XCTest tests and 13 Swift Testing tests (`swift test list`, September 2026). Besides the engine, catalog, lens and ML tests, `HelpKitTests` (Swift Testing) loads the real `docs/wiki`: every page parses, the pages follow `_Sidebar.md`, and every link between pages names a page and heading that exist. `LatentAppTests` tests the app target's own logic through `@testable import latent_app`: the key and menu tables have no clashing shortcuts, command enabling, tool-size steps, VoiceOver wording and the Reduce Motion and Increase Contrast rules, and `ShortcutsPageTests` fails when `docs/wiki/Keyboard-Shortcuts.md` differs from what `Sources/latent-app/Shortcuts.swift` generates (`LATENT_WRITE_SHORTCUTS_PAGE=1 swift test --filter ShortcutsPageTests` rewrites it).

**Snapshot harness.** Debug builds carry `SnapshotHarness`, which walks the app through its main states (library, loupe, develop, crop, heal, compare, export sheet, settings) and saves a PNG of the window at each, then quits, so developers and agents can see the UI without screen-recording permission. It is switched on by `LATENT_SNAPSHOT_DIR` and configured by the other `LATENT_SNAPSHOT_*` variables documented in `SnapshotHarness.swift`; release builds neither read them nor contain the code. It is a looking aid, not a test: nothing compares its pictures.

**Camera sample files.** The planned matrix was D750 (14- and 12-bit NEF), A7 III (uncompressed and compressed ARW), Canon CR2 and CR3, one monochrome file and one linear DNG. **Actual:** only Nikon D750 NEFs, in `TestAssets/`, which is not in the repository. Tests that need a sample skip without it.

**Profiling.** Timings are measured with `latent-cli --repeat` (PHASE0.md §5). A Metal System Trace pass has not been done.

**Continuous integration.** `.github/workflows/ci.yml` runs `swift build` and `swift test` on GitHub's hosted `macos-15` runner. **Decision:** no self-hosted runner. The hosted runners are Apple Silicon with Metal, so GPU tests run there; tests that need the sample raw skip themselves.

---

## 13. Phase 0 Spike (2–3 weeks)

**Status: done.** Results are recorded in `PHASE0.md`: one copy kept (task 2, option c); correctness checked by eye against a Photoshop export of a D750 NEF, with the RawTherapee comparison and A7 III render still owed; full-frame 24 MP RCD plus color measured ~46 ms on M4, over the 30 ms target, which was accepted because the viewport renders binned previews (~3 ms) and tiles (~9 ms) rather than the full frame; LibRaw unpack (~210–250 ms) dominates file-open time; no Metal-4-only API used. The text below is the original plan.

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

| Phase | Scope | Exit criteria | Status |
|---|---|---|---|
| 0. Spike | See §13 | See §13 | **Done** (§13) |
| 1. Core pipeline | Highlight reconstruction, sigmoid tone mapping, stage cache, viewport-resolution rendering, tiled zoom, GPU scopes | Slider-to-screen latency under 16 ms at fit-to-window | **Done.** Stage cache is demosaic-only (§8.2) |
| 2. Catalogs | Folder catalogs, schema, XMP read/write, reconciliation, subfolder modes, grid view, ratings, flags and keywords | Scrolling a 20,000-image folder stays smooth; the catalog rebuilds from sidecars alone | **Done.** Subfolder modes are not in sidecars (§5.2). Later: a favourites sidebar with folder trees, a filmstrip, a thumbnail size slider and a cancellable thumbnail loader (§10), and automatic rebuilding of a damaged database (§5.3) |
| 3. Import | Card import (§6) | — | **Dropped (September 2026).** Users copy files into a folder themselves; opening that folder in Latent creates its catalog in place |
| 4. Pro pipeline | Lens corrections (Lensfun, embedded data, manual), denoise, sharpening, color grading, process versions | All current lenses are corrected automatically | **Done**, except embedded ARW corrections (§9.2) and a process-version upgrade flow (§5.6) |
| 5. Local edits | Parametric masks; AI masks from Vision and Core ML | AI mask generated in under 1 second | **Done.** Plus spot healing |
| 6. Output | Export queue, ICC soft-proofing, HDR gain-map export, DNG export | Batch export keeps the GPU busy without stalling the UI | **Done** for export queue, soft-proofing and HDR gain-map export (September 2026, §8.5). **Not done:** DNG export |
| 7. Polish | Presets, copy/paste settings, snapshots, history, keyboard workflow | Beta release | **Done.** Later: every command in the menu bar from one shortcut table, typed slider values, an in-app Help window built from the wiki, and a VoiceOver, Reduce Motion and Increase Contrast pass |
| v1.x | X-Trans support, ML denoising, Pixel Shift, cross-catalog search UI | — | ML denoising **shipped** (§8.4). The rest not started |

---

## 15. Risks

| Risk | Mitigation |
|---|---|
| Demosaic and color quality falls short | Port proven GPLv3 algorithms and gate every change on golden-image tests. RCD is ported, and golden-image tests pin the output of every stage except AI noise reduction (§12) |
| LibRaw updates break decoding for a camera | **In place:** LibRaw 0.22.2 is pinned by commit and the build refuses a moved tag. **Open:** CI has no per-camera matrix; only the D750 is tested (§12) |
| A crafted raw file exploits LibRaw | **In place:** decoding runs in a sandboxed XPC service with no file or network access (§4a) |
| The SQLite database and XMP sidecars drift apart | Sidecars are authoritative, writes are atomic, and the database can always be rebuilt; a database SQLite reports as damaged is set aside and rebuilt automatically (§5.3). **Exception:** subfolder modes live only in the database (§5.2) |
| Metal 3/4 API boundary assumed wrong | **Resolved:** checked in Phase 0 (task 6); no Metal-4-only API is used |
| Network volumes corrupt the database | **In place:** the volume type is detected and journal mode switched accordingly |
| Algorithm changes alter old edits | Process versioning, plus recording the Lensfun database version in each edit. **Open:** versions are recorded but not yet used to pin rendering (§5.6). **Happened:** the September 2026 ratio-field heal changed how existing heal patches render (clone keeps its maths, but patches now apply in order, each seeing the ones before), with the process version still `1.0`; the golden references were regenerated for it. Resized exports also changed slightly with the Lanczos 3 resample (§8.5) |
| An edit is lost on quit, or saved to the wrong photo | **In place:** quitting saves the pending edit and waits for catalog writes and the export file being written (§11); every save names its catalog, and the editor closes its image before another folder opens (§5.3) |
| Exports leak location | **In place:** location (GPS, place names, body and lens serial numbers) is a separate switch, off by default and in older presets, in the export sheet and for Export Open Image; a second switch strips all metadata (§8.5, §4a). **Open:** camera metadata, artist and copyright are on by default |
| Memory runs short on small Macs | **In place:** rebuildable caches are released under memory pressure, and on 8 GB Macs Compare's Select pane closes its image when Compare is left (§7.2) |

---

## 16. Open Items

- **Namespace owner.** **Resolved** 2026-09-13: `https://github.com/Harmanjit/latent-raw/ns/1.0/` (`XMPSidecar.namespaceURI`).
- **Name availability.** **Resolved**, checked 2026-09-13: no "Latent" trademark in US or EU for software. A mobile app called "Latente" exists, so the public repo is `latent-raw` and the app is described as "Latent, a catalog management and RAW editor for macOS" to keep the two apart.
- **Tokina vignetting.** Open. Validate the borrowed Canon EF vignetting profile against real shots from the Nikon F version.
- **RawTherapee color comparison and A7 III render.** Open, carried over from PHASE0.md §4.
