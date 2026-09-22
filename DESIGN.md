# Latent — Design Document

**Status:** Beta; version 0.9 is the review build. All roadmap phases (§14) are implemented, except where marked dropped or not done. Brought in line with the code on 2026-09-21, after sensor dust removal, portrait touch-up and the subject-selection model registry (`docs/Retouch.md`; §8.4, §8.7, §8.8), and on 2026-09-15 after Photo Merge (§8.6: HDR, Panorama and the experimental HDR Panorama) and cutting the sensor plane to the camera's active area (§7.1). The second wave of 2026-09-14 added Survey, full-screen and second-display viewing, trackpad gestures and the magnifier, Custom sort and Finder tags, moving, copying and renaming images, undo in the Library, red-eye removal and brush healing, the export watermark, size estimate and quality comparison, Print and contact sheets, the slideshow and Edit in External Editor; the first wave that day added the folder sidebar, HDR gain-map export, tone ranges and the Help window. Several Library and viewer features of September 2026 (among them the grid's thumbnail loader, moving and renaming files, Library undo, red-eye, the page layout behind Print and contact sheets, the slideshow and the viewer's trackpad input) were ported from [minivu](https://github.com/Harmanjit/minivu), the same author's image viewer in the style of FastStone Image Viewer, also GPLv3; source comments that mention minivu refer to it. This document began as the pre-code plan; where the code deliberately differs, the text describes the code and a **Decision:** note gives the reason.
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
- Distribution through the Mac App Store. The GPL is incompatible with Apple's store terms. The plan was notarized builds from GitHub Releases, Sparkle for updates and a Homebrew cask; today the app is ad hoc signed and not notarised (§4a), built from source or downloaded from GitHub Releases. There is no updater and no cask.

---

## 2. Efficiency Rules

Every design decision is checked against these rules.

1. **Never do work twice.** Every expensive result, whether a pipeline stage output, a thumbnail or an index entry, is cached and keyed by the inputs that produced it.
2. **Never do work that isn't visible.** Interactive rendering runs at viewport resolution. Full-resolution work happens only for zoomed-in tiles and for export.
3. **Never copy what can be shared.** Buffers live in unified memory and are passed between the CPU, GPU and ANE by reference, as `MTLBuffer`s, IOSurfaces or `CVPixelBuffer`s.
4. **Zero cost when idle.** There is no polling and no continuous display-link loop (the viewport's display link runs only while a frame is waiting to be shown, the second display's stays paused the same way, and the slideshow's runs only during a transition, §8.3), and nothing is written to disk while a slider is being dragged. The magnifier renders nothing while the mouse is still or up.
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
| Machine learning | Core ML (GPU by default, §8.4) and the Vision framework | Masking, AI denoise, face landmarks for red-eye and touch-up. Sensor dust uses no model (§8.7) |
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
| `PixelEngine` | Library | Metal pipeline and kernels, stage cache, edit stack, crop, healing (circles and brush strokes), red-eye, tone ranges, soft proof, export rendering and resampling, the export watermark, gain maps, page layout and drawing for Print and contact sheets, slideshow transitions, the rules for mouse and trackpad input on the image (`ViewerInteraction`), safe file writes, memory-pressure monitoring; no UI | `RawCore`, `ColorKit`, `LensKit` |
| `Catalog` | Library | Folder catalogs, GRDB schema and migrations, XMP read/write, reconciliation, thumbnails and the thumbnail loader, filtering and sorting (Custom order, Finder tags), moving, copying and renaming images with their sidecars (`ImageTransfer`), undo for library actions, folder history, Survey's panes, folder access checks, export naming, batch planning and size estimates | GRDB, `RawCore` |
| `MLKit` | Library | The model registry, manifests and importer (§8.4), the compile cache, SAM 2.1, SegFormer, BiRefNet and other subject models, Vision masks, AI denoise, one Vision face-landmark pass shared by red-eye, touch-up regions and the blemish finder (§8.8), `ExportWorker` (files, and pixels for pages and slides) | `PixelEngine` |
| `HelpKit` | Library | The Help window's content: the wiki's Markdown (`docs/wiki`) parsed into blocks, links between pages, search | — |
| `MergeKit` | Library | Photo Merge without UI: frame alignment (phase correlation and ECC), deghosting, the HDR merge, panorama geometry and stitching, HDR Panorama, the LinearRaw DNG writer and the `latent:Merge` recipe (§8.6); its Metal kernels are in `PixelEngine`'s `Shaders/Merge*.metal` | `PixelEngine`, `RawCore`, `ColorKit` |
| `latent-rawdecoder` | Executable | The `LatentRawDecoder.xpc` service: decodes a file descriptor with LibRaw (§4a) | `RawCore` |
| `latent-cli` | Executable | Headless rendering and benchmarks, `catalog` (reconcile a folder and list its catalog), and the merge commands (`merge-hdr`, `pano-layout`, `merge-pano`, `merge-hdrpano`) | `RawCore`, `PixelEngine`, `Catalog`, `ColorKit`, `MergeKit` |
| `latent-app` | Executable | SwiftUI and AppKit views, the viewport and magnifier, the grid, the folder sidebar and filmstrip, Survey, full-screen image and the second display's Loupe, menus and the shortcut table, the export queue and sheet, Print and Contact Sheet, the slideshow, Edit in External Editor, the Help window, Photo Merge's dialogs and jobs | `RawCore`, `PixelEngine`, `ColorKit`, `Catalog`, `LensKit`, `MLKit`, `HelpKit`, `MergeKit` |

Test targets: `PixelEngineTests`, `CatalogTests`, `LensKitTests`, `MLKitTests`, `MergeKitTests`, `HelpKitTests` and `LatentAppTests` (§12).

`ColorKit`, `LensKit`, `Catalog`, `MergeKit` and `HelpKit` contain no C code of their own; `LensKit`, `Catalog` and `MergeKit` link LibRaw transitively through `RawCore`. **Decision:** `ExportWorker` lives in `MLKit`, not `PixelEngine`, because a faithful export must regenerate model masks (§8.4) and only `MLKit` can. The planned `AppUI` library became the `latent-app` executable target.

---

## 4a. Security Architecture

LibRaw parses files Latent did not create, so the design assumes a crafted file can exploit it and limits what that exploit reaches.

| Measure | Detail |
|---|---|
| App Sandbox, hardened runtime | Both the app and the decoder service are signed with `--options runtime` and sandbox entitlements (`scripts/make_app.sh`) |
| App entitlements | `scripts/Latent.entitlements`: sandbox, user-selected files read-write, app-scope security-scoped bookmarks, and `com.apple.security.print`, without which the sandbox refuses print jobs; it reaches the printing system only, with no network or file access. No `network.client`, so the OS forbids network access |
| Bookmarks | The last folder, the export destination, each favourite folder in the sidebar, the last five Move/Copy to Folder destinations (`latent.recentTransferDestinations`), the external editor's folder, each application added as an external editor, and each slideshow song are kept as security-scoped bookmarks, so they work on the next launch without a panel. A favourite grants access to everything inside it. Bookmarks resolve without mounting volumes or showing UI; a favourite whose disk is away shows as not connected, and a recent destination that is gone drops out of the menu |
| Raw decoding out of process | `LatentRawDecoder.xpc` (`scripts/LatentRawDecoder.entitlements`: sandbox only) has no file access and no network. The app opens the file and passes a file descriptor over XPC (`Sources/RawCore/RawDecoderXPC.swift`). The service has two calls. `decode` returns metadata and the embedded preview as `Data`, and the sensor plane as a shared IOSurface. `readMetadata`, used by exports, returns two size-capped binary property lists: ImageIO's property dictionaries with structural tags removed, and the XMP tags as a tree of plain dictionaries. The app rebuilds XMP through ImageIO's tag API and never parses an XMP packet the service produced. A crash invalidates the connection, the app shows an error, and the next call starts a fresh service |
| Help window | Shows the wiki pages copied into the bundle (`Contents/Resources/Help`). Nothing is fetched. Links are bare page names, `Page#anchor`, `http(s)` or `mailto`; web and mail links open in the user's browser or mail app, and anything else (file URLs, paths outside the pages) is refused |
| Signing | Ad hoc (`--sign -`), not notarised: there is no Apple developer account. Gatekeeper warns once on any other Mac |

`swift run` and `swift test` have no bundled service, so they decode in process. `LATENT_RAW_INPROCESS=1` forces in-process decoding only in a debug build: a release bundle can't be told to parse raw files outside the service. `scripts/make_app.sh` always builds release (with `--dev` too), so the switch does nothing in any bundle the script makes. Other debug-only switches, such as the snapshot harness (§12), are compiled only under `#if DEBUG`; a release build neither reads them nor carries the code. `make_app.sh --dev` builds without sandbox entitlements.

**Decision:** decoder isolation must not cost extra copies of the sensor plane. The plane crosses the process boundary as shared memory (§7.1).

**File operations under the sandbox.** Move to Folder, Copy to Folder, Rename and drops on sidebar folders write only where the sandbox already lets the app: inside the open folder or a favourite, a folder chosen in the Choose Folder… panel (which is what grants it), or a remembered destination's bookmark. They never overwrite (§5.7), and undoing a copy moves the copy to the Trash rather than deleting it. Dragging thumbnails out hands the other app file URLs of the originals; Finder copies them, and nothing leaves its catalog by a drag. Finder tags are read from each file's `com.apple.metadata:_kMDItemUserTags` attribute and never written. Edit in External Editor writes its TIFF into the external editor's folder (or the default export folder, or a folder chosen once in a panel) and asks Launch Services to open it in the chosen application; the application is located through its bookmark, its path or its bundle identifier. None of this needed a new entitlement.

**Models from disk.** Nothing downloads a model; the dormant download path of the first beta build is gone. Settings › AI › Models offers Get…, which opens a model's source page in the browser, and Add Model…, which imports a folder, `.mlpackage` or `.zip` the user converted with a script in `scripts/`. `ModelImporter` (§8.4) copies a zip into the container's temporary directory first (the open-panel grant belongs to the app process, not to a spawned `ditto`), lists it with `zipinfo`, refuses entries that reach outside their folder, then validates the folder: exactly one `<id>.model.json`, the id pattern `^[a-z0-9][a-z0-9.-]{0,63}$`, http(s) URLs only, a kind this build knows, not the id of a bundled or built-in model, every named package present and no stray file, each package holding only Core ML's three files with contents matching the manifest's SHA-256, a labels file for a class model; then a compile check of each package, one at a time with `.cpuAndGPU` off the main actor, with feature names compared against the manifest. Any failure deletes the copy and throws one plain sentence. The hash catches corruption and keys the compile cache; it is not a signature, since the manifest arrives from the same untrusted folder as the packages. The sandbox is the boundary: a model is data Core ML runs inside the app's own sandbox, and an imported model is held to the GPU whatever the compute preference says, because an untried graph can hang the ANE compiler in-process.

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
    ├── custom-order.json          ← the Custom sort's arrangement, once one is made
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
- **Custom order.** The Custom sort's arrangement is a list of catalog-relative paths in `_latent/custom-order.json`, written atomically once per drop (`CustomOrder`). It is not in `catalog.sqlite`, which can be set aside and rebuilt (§5.3), and not in each sidecar, since one drag moves every image after the drop point and rewriting hundreds of sidecars for one gesture is the opposite of cheap. Paths rather than ids, because ids restart with a rebuilt catalog. Images the list doesn't name (new files) follow the arrangement by name; images the filter hides keep their places. A rename that reconcile detects moves the path in the list, and so does a rename or move within the catalog made in Latent (`Catalog.placeTransfer`), whose row already has the new path when reconcile runs.
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

**Finder tags.** Each reconcile reads every listed file's Finder tag attribute with the listing it already makes (one `getxattr` for an untagged file) and caches it in `images.finder_tags`; only rows whose tags changed are written, since tagging in Finder moves no modification time. The attribute is never written. A rebuilt database loses nothing, because the file itself is the source.

**No live watching.** Latent does not use FSEvents or any other file watching on external volumes. Reconciliation runs only when a folder is opened, and after a move, copy or rename made in Latent (`Library.refresh`). The app has no Refresh command; opening the folder again re-scans it, which is also when a Finder tag changed outside Latent shows.

**Network volumes.** SQLite's write-ahead log (WAL) journal mode does not work reliably on SMB or NFS shares. Latent detects the volume type and uses WAL on local and external drives, and the rollback journal on network shares.

### 5.4 Database schema

```sql
CREATE TABLE images (
  id INTEGER PRIMARY KEY,
  rel_path TEXT NOT NULL UNIQUE,        -- relative to the catalog root
  preserved_name TEXT,                  -- original filename, recorded when Rename, Move or Copy first gives the file a new name (§5.7)
  size INTEGER NOT NULL, mtime INTEGER NOT NULL,
  xxhash BLOB NOT NULL,
  capture_time INTEGER, camera TEXT, lens TEXT, lens_id TEXT,
  iso INTEGER, shutter REAL, aperture REAL, focal REAL,
  width INTEGER, height INTEGER, orientation INTEGER,
  rating INTEGER DEFAULT 0, label TEXT, flag INTEGER DEFAULT 0,
  sidecar_mtime INTEGER,
  thumb_key BLOB,                       -- hash of the edit that produced the thumbnail
  user_rotation INTEGER NOT NULL DEFAULT 0, -- migration v2: manual quarter turns clockwise
  finder_tags TEXT,                     -- migration v3: the file's Finder tags as last read, "6Red\n0Work"
  merge_json TEXT                       -- migration v4: latent:Merge recipe of a Photo Merge result, else NULL
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

Migrations are in `Sources/Catalog/Schema.swift` (`v1_initial`, `v2_user_rotation`, `v3_finder_tags`, `v4_merge_recipe`). `user_rotation` is kept apart from `orientation` (what the camera recorded) so re-reading EXIF never clobbers a manual fix. `finder_tags` is a cache of the file's own attribute (§5.3): one line per tag, Finder's colour digit then the name, a plain string because the filter reads it for every row. The `lens_overrides` table exists but nothing reads or writes it yet.

No pixel data and no absolute paths are ever stored in the database.

Search across catalogs was planned with SQLite's `ATTACH`; it is not implemented. The app's preferences hold settings (among them the grid's sort and each sort key's direction, app-wide as Finder keeps its view options, the print layout, the contact sheet and slideshow settings) and the bookmarks listed in §4a; that is not a catalog. The sidebar lists folders with `readdir` and touches no catalog until a folder is clicked.

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
   <latent:Merge><![CDATA[ { ...merge recipe JSON... } ]]></latent:Merge>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
```

`latent:Flag` is -1 rejected, 0 none, 1 picked. `latent:Rotation` is the manual quarter turns clockwise (the `user_rotation` column). `latent:Snapshots` and `latent:History` are JSON, omitted when empty. `latent:Merge` is the recipe of a Photo Merge result (`docs/PhotoMerge.md`), omitted for every other photo; the catalog mirrors it in `images.merge_json`, because every sidecar write renders the whole file from the database. JSON containing `]]>` is written as two adjacent CDATA sections (`]]]]><![CDATA[>`), which readers join back. Readers match properties by local name, so sidecars written before the rename with the `rawhead:` prefix still load.

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
    "heal":         [ { "id": "…", "target": [0.41, 0.52], "source": [0.43, 0.52],
                        "radius": 0.004, "feather": 0.35, "mode": "heal",
                        "stroke": [[0, 0], [0.006, -0.001], [0.013, -0.004]] } ],
    "redeye":       [ { "id": "…", "centre": [0.62, 0.31], "radius": 0.006, "strength": 1 } ],
    "dust":         [ { "id": "…", "target": [0.412, 0.087], "source": [0.418, 0.087],
                        "radius": 0.0021, "feather": 0.5, "mode": "heal" } ],
    "touchup":      { "faces": [ { "id": "…", "boundingBox": [0.41, 0.18, 0.12, 0.17], "enabled": true } ],
                      "skinSmoothing": 45, "teethWhitening": 30, "eyes": 20, "blemishRemoval": true,
                      "blemishes": [ { "id": "…", "target": [0.452, 0.271], "source": [0.458, 0.269],
                                       "radius": 0.0018, "feather": 0.5, "mode": "heal" } ],
                      "modelVersion": "vision.faceLandmarks.3" },
    "crop":         { "cx": 0.5, "cy": 0.5, "w": 0.9, "h": 0.9, "angle": 1.5 }
  }
}
```

The structure is `EditStack` in `Sources/PixelEngine/EditStack.swift`. Every module key is optional: an old sidecar lacking a key gets that module's default, and a key this build does not know is ignored. There is no `enabled` flag; a module at its neutral value is the off state. `locals`, `heal`, `redeye`, `dust`, `touchup`, `presence`, `vibrance`, `defringe`, `perspective`, `aidenoise`, `toneranges` and `crop` are omitted when neutral; the rest are always written, so a sidecar untouched by the new modules stays byte-identical and the 0.9.0 beta ignores what it does not know. `dust` is a list of heal patches Find Spots or a dust map placed (cap 200, `HealPatch.maximumDustCount`), and `touchup` holds the faces Find Faces found (`boundingBox` on the **raw** sensor grid, so lens and keystone edits never invalidate them; cap 16, `TouchUp.maximumFaces`), the three sliders in 0…100, the blemish switch, the blemish patches (cap 64) and the Vision version that found the faces; it decodes leniently, every key optional, sliders clamped and lists cut and sanitised. A mask's `modelVersion` is now the manifest's `<id>@<version>` (`birefnet-lite@1`, `sam2.1-large@1`); the four legacy literals (`sam2.1-small.1`, `vision.foregroundInstance.1`, `segformer-b2-ade20k-512.1`, `latent.skyHeuristic.1`) are parsed and never rewritten on load, and a string that cannot be parsed counts as a missing model (§8.4). `Preset.groups` decodes leniently, dropping raw values it does not know, so a preset that names `touchUp` simply vanishes from the beta's list. A heal patch's `stroke` is a brush stroke's path as offsets from `target`, in normalized sensor coordinates, at most 256 points; it is absent for a circle, so circles encode as they did before strokes. A red-eye spot's `centre` is normalized sensor coordinates and its `radius` a fraction of the sensor's short side; spots decode leniently, a missing key taking its default. Inside `curve`, `points` is the master curve and the optional `red`, `green` and `blue` point lists are left out while straight. Rotation is not in the stack (it is catalog metadata, §5.5), nor is the output color space (an export choice). Model masks store their kind or clicks plus a model version, never pixels (§8.4). Normalized sensor coordinates measure the camera's active area (§7.1); the top-level `frame: "active-area"` says so, and is written only when the stack has crop, mask, heal or red-eye geometry. Stacks from before September 2026 lack it: their geometry measured the whole sensor readout, border included, and is converted to the same pixels on the active area when the image is opened, exported or thumbnailed (`EditStack.migratingGeometry`), which changes nothing for cameras without a border.

**Decision:** modules are keyed by name with their parameters directly inside, rather than the planned `enabled` flags, `rawprepare` and `masks` keys and a top-level `crop`. Neutral values already mean "off", and a flat module map keeps additions purely additive.

**Process version.** Every edit records the pipeline version it was created with (`1.0`). The intent is that when algorithms improve, existing edits keep rendering the same way until the user explicitly upgrades them. Only one process version exists so far, and there is no pinning or upgrade flow yet. That has already cost something: in September 2026 spot healing changed from one rim ratio to a ratio field (§8.1), still under `1.0`, so existing heal patches now render differently from when they were made (§15).

**Frozen lens profiles.** Each edit records which lens profile and Lensfun database version (the bundled copy's date) supplied its corrections. Only the bundled database is loaded, so the recorded version is provenance, not yet a selector.

### 5.7 Moving, copying and renaming images

Move to Folder, Copy to Folder, drops on sidebar folders and Rename go through `ImageTransfer` (`Catalog`), queued one operation after another by `LibraryFileOperations`, with each image's work off the main thread. An image takes its sidecar, thumbnail and catalog row with it, so ratings, flags, keywords, edits, snapshots and history travel. The rules the code follows:

- **Which catalog.** A folder's files belong to the nearest catalog that would index them: its own `_latent/`, an enclosing catalog that includes it (§5.2), or, failing both, the catalog the folder will have once opened. A folder with no catalog gets a `_latent/` only when an image brings a sidecar. A folder inside the open catalog that is `ask`, by its mode or the default (one just made with New Folder in the panel, say), is asked about before images go in, as §5.2 promises, rather than decided by whether they bring sidecars; one that is `independent` becomes a catalog of its own. A destination catalog still in an old `_rawhead/` has it renamed `_latent/` before a sidecar goes in.
- **Only the open catalog's database is written,** through its actor, with each image's sidecar, thumbnail and row changed in one actor step, so a rating given meanwhile can't land between them. Any other catalog catches up on its next reconcile from states reconcile already understands: a sidecar waiting beside a new file is applied to it, a file gone takes its row with it, and within one catalog a moved file is recognised by its hash.
- **Order.** A copy, or a move to another volume, first makes a whole copy under a hidden `.latent-transfer-*` name in the destination (a clone on APFS). The sidecar is written before the file arrives, and the original goes last, once its copy is whole and the new sidecar is written. An image moves completely or is left where it was. Quitting waits up to a minute for the image under way, then removes a hidden copy still unplaced (`ImageTransfer.abandonTemporaryCopies`), and that image stays where it was.
- **Nothing is overwritten.** Renames and the final placement of copies use `renamex_np(RENAME_EXCL)`. A name taken by a file, by a sidecar a file left behind, or by a row whose file has gone gets a number ("DSC_0107 2.NEF"), and the image's old name is kept as `xmpMM:PreservedFileName`. A rename that only changes letter case goes through a hidden temporary name.
- **What the image carries.** The open catalog's row is the truth, unless the sidecar's modification time shows it was changed outside Latent since the row read it; then the sidecar file itself is carried, for reconcile to read.
- **Nothing the user made is deleted.** Undoing a copy puts the copy and its sidecar in the Trash, and only if the copy is still the file that was made. Apart from the original of a move to another volume, once its copy is in place, the only files removed are regenerable thumbnails, Latent's own temporary copies, and a moved image's old sidecar, whose contents are already in the new one.
- **Stopping.** Stop in the status bar, or quitting, stops after the image under way (§11).
- **Undo.** Each operation registers its opposite on the Library's undo manager with what was actually done, read when the undo runs, so an undo waits for the move it reverses. These actions are kept by file URL, so they survive opening another folder. They are marked as changing files (`UndoManager.UserInfoKey.changesFiles`), so Undo and Redo refuse them while the export queue runs.

Rename, Move and Copy work in the Library grid only, and not while the export queue runs, a print renders or a contact sheet is written (`OutputJobs`), since each reads the files; drops on sidebar folders follow the same rule. After an operation the Library re-reads the open folder (§5.3) and selects images that came back into it.

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
3. The camera's active area of LibRaw's plane is copied once into an IOSurface (`Sources/RawCore/SensorPlane.swift`), and LibRaw is closed straight away, freeing its own allocation. LibRaw unpacks the whole sensor readout, which on many cameras includes optically masked columns and rows (100–250 columns on the left of a Canon file) or padding without image data; only the `width x height` rectangle at (`left_margin`, `top_margin`) is picture, and LibRaw's CFA pattern counts from its corner. Cutting it out here means every render, mask, lens centre and export size works in the picture alone (`SensorActiveArea`). The Nikon D750 has no border, so its renders are unchanged.
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

**Memory reuse.** `ImageSession.texture(width:height:pixelFormat:role:)` keeps one pooled private texture per role (CFA, camera RGB, RCD scratch, denoised, healed, lens-corrected, display, presence, sharpened, and preview variants) and hands it back whenever size, format and role match. A second render with the same key overwrites the first. The session keeps separate pools (`ImageSession.TexturePool`) for the view (preview, tile, scopes, exports), the magnifier, and one-off analysis renders such as red-eye detection and model input, so a render in one never overwrites a texture another has on screen, and each can be released on its own: the magnifier keeps only its latest tile size's textures and frees them when the loupe goes, and an analysis render frees its own as soon as its pixels are read back.

**Memory pressure.** `MemoryPressureMonitor` passes the system's warning and critical levels to the editor (`EditorModel+Memory.swift`). A warning drops the session's pooled textures, demosaic cache and heal cache, every model the registry has loaded (`ModelRegistry.releaseAll`; they reload from their compiled copies on disk; the denoisers keep their own `SharedModel` loading), the dust analysis Find Spots kept for re-detection, and every prompted-mask session and image encoding unless the prompt tool is armed, when only the selected mask's model keeps its encoding. Critical also drops the encodings regardless, the brush mask rasters, the touch-up mask set, planes and texture (rebuilt when pressure returns to normal, §8.8) and the AI denoise result, which runs again (about 11 s) once pressure returns to normal. The layers on screen keep their own textures, so the picture doesn't change until the user acts. A pane that isn't on screen (Compare's Select pane outside Compare, Survey's panes outside Survey) closes its image instead. The thumbnail loader halves its memory cache on a warning and empties it on critical (§10). On Macs with 8 GB or less (`MemoryPolicy`), Compare's Select pane closes its image as soon as Compare is left.

**Survey.** Each of Survey's two to four panes is a view-only editor model with a full image session, sensor plane and all; a pane never writes to the catalog and doesn't measure scopes. On Macs with 8 GB or less a pane releases its pooled textures after each render (keeping the sensor plane and the layers on screen), every pane closes its image when Survey is left, and the editor's own catalog image closes while Survey shows. With more memory, panes that are no longer on screen keep their images but release their pooled textures, so returning to Survey is instant, and close under memory pressure like Compare's Select pane. Panes whose edits have AI denoise on run it one pane at a time, the focused pane first, and only while Survey shows; a run under way when Survey is left stops and starts again on return.

**Second display.** The Loupe on a second display draws the editor's own preview: no second decode or render. The preview's bin factor is the finer of the two views' needs, and it is rendered to the brighter display's headroom (§8.3).

**Decision:** no `MTLHeap` aliasing and no `MTLResidencySet`. Phase 0 deferred residency sets until they are wanted (PHASE0.md §6), and the per-role pool already reuses memory across renders, so heap aliasing was not adopted.

**On-chip memory.** The planned use of threadgroup memory for neighborhood kernels was not generally adopted; threadgroup memory is used by the histogram kernel. Stages run as separate kernels within one command buffer per render (§8.1).

---

## 8. Processing Pipeline

### 8.1 Fixed module order

The modules always run in this order (`RenderPipeline.renderStages`). Every stage of one render is encoded into a single command buffer and submitted once.

In camera space:

1. **Black level and white balance,** in one kernel, producing the CFA plane.
2. **Demosaic:** RCD, or bilinear. RCD's neighbourhood reads past the frame edge mirror back about the edge photosite, which keeps each read on the colour it expects, so the outermost pixels are demosaiced like the rest and the interior is untouched (`DemosaicBorderTests`); clamping them used to leave one channel of the edge pixel at half its value, which perspective and lens correction stretched into coloured wedges. Binned previews replace steps 1 and 2 with one fused kernel that bins Bayer quads straight from the sensor buffer, with no demosaic. This output is cached (§8.2).
3. **AI denoise blend:** the session's cached full-frame NAFNet result, re-binned and re-white-balanced to match the render, blended by strength (§8.4).
4. **Classic denoise** (luminance and color).
5. **Spot heal,** patches applied in order, each reading the image as the earlier ones left it (`Heal.metal`). The list is `EditParameters.allHealPatches`: the dust spots (§8.7), then the touch-up blemishes (§8.8), then the user's own patches, so a user patch over a dust spot reads the dust-healed image; each list is capped on decode (200, 64 and 32), and `HealStage.encode` takes the concatenation whole. Stages 3–5 are skipped on a heal-cache hit (§8.2). Clone copies the source. Heal multiplies the source by a ratio field: the target's surroundings over the source's, each a Gaussian blur (sigma half the radius) that masks out the patch and renormalises, computed on a coarse grid of up to a quarter sigma per cell. Tone and colour then match along the whole edge and follow gradients across the patch. A brush stroke is one patch: its path is cut into short pieces (`HealPatch.strokeSegments`), each healed in its own pass from the same source offset, masked by distance to the whole path, with each pixel written by its nearest piece so no seam shows between pieces. Every piece reads the image as it was before the stroke, as a circle does, so pieces don't depend on each other and a tile grows only by the pieces near the view (`HealPatch.regionIncludingSources`), not by the stroke's bounding box. Heal and red-eye geometry loaded from a sidecar is clamped to within a frame of the sensor, with strokes cut to 256 points, before anything renders it.
6. **Red-eye** (`RedEye.metal`), on the heal stage's working texture after the patches. Inside each circle, pixels that are flash red become a dark neutral; redness is judged in linear Display P3 (the camera values converted through the camera matrix for the test only), so the iris, the catchlight and skin inside a generous circle keep their colour. The thresholds mirror `RedEyeTuning` in `RedEye.swift`, which the Auto button's detector (`MLKit/RedEyeDetector`, Vision face landmarks on a render of about 1600 px) uses to propose a circle only where a pupil really is red.
7. **Lens corrections:** distortion, TCA, vignetting, manual sliders and perspective.

Then the `colorAndTone` kernel (`Shaders/ColorPipeline.metal`), per pixel:

8. **Highlight reconstruction,** in camera space where clip levels are meaningful.
9. **Camera matrix** to linear Rec.2020.
10. **Exposure,** then **Highlights, Shadows, Whites and Blacks** (`ToneRanges.swift`): a per-pixel exposure gain looked up from a table by the pixel's luminance on the sigmoid's log scale, t = contrast × log2(Y / mid grey). Global and hue-preserving, with slopes limited so no tone overtakes a brighter one; mid grey is outside every band. Skipped when all four are zero, and in analysis renders.
11. **Local adjustments with masks,** in scene-linear. Range masks evaluate the pixel before any local changes it.
12. **Sigmoid tone map,** scene-referred to display-referred, up to the render headroom: 1 for files and soft proofing, 4 for a gain map's HDR rendition (§8.5), and for the viewport the screen's potential headroom, capped at 4 (§8.3).
13. **Grading:** tone curve (master, then red, green and blue), HSL, vibrance, split toning, in a perceptual domain scaled by the headroom.
14. **Soft proof** (optional; with gamut warning).
15. **Output transform and encode:** working space to output space, then the sRGB curve for files, or linear extended range for the EDR viewport.

Display-referred, after `colorAndTone`:

16. **Touch-up** (`Shaders/TouchUp.metal`, `TouchUpStage.encode`): skin smoothing, teeth whitening and brighter eyes through the session's three-slice mask texture, run only when `parameters.touchUp.wantsMasks` and the session holds masks (§8.8); a no-op otherwise, so thumbnails and `latent-cli`, which build no masks, render the rest unchanged.
17. **Presence:** texture, clarity, dehaze and defringe.
18. **Sharpening.**

A display-only pass after 18, `dustVisualise` (`Shaders/Dust.metal`), replaces the viewport's picture with a high-pass view while Visualise Spots is on (`RenderOutput.spotVisualisation`); like the mask overlay it never reaches an export.

**Geometry.** Crop, straighten and rotation are not pipeline stages. They are applied as a sampling map from `CropFrame` (`Crop.swift`) when the result is presented (`Presenter`) or exported (`Exporter`).

**Decision:** the order differs from the plan. Highlight reconstruction moved after demosaic but stays before the matrix; denoise, heal, red-eye and lens corrections run in camera space before color so they see sensor-like data; local adjustments act in scene-linear before the tone map; flat-field correction, AMaZE and DCP profiles were not built. Precision is covered in §7.2.

### 8.2 Caching and resolution

**Stage cache.** Only the demosaic output (camera RGB) is cached, per `ImageSession`, keyed by the white balance multipliers, the demosaic method and the region or bin factor (`ImageSession.StageKey`). Exposure, tone, grading and detail edits hit the cache; white balance and zoom changes miss. Everything after demosaic re-runs on every render, in the one command buffer. The cache lives in GPU memory only and is never written to disk. The AI denoise result is held separately per session (§8.4); critical memory pressure can drop it (§7.2).

**Heal cache.** Since sensor dust, one more stage output is cached: the healed texture after stage 5. `ImageSession.HealKey` holds everything stages 3–5 read (the stage key, the AI denoise strength and model, the classic denoise amounts, the dust, blemish and heal lists and the red-eye spots); `renderStages` builds it after the plan, and on a hit sets the colour input to the cached texture and skips the three stages, so a slider tick after a Find Spots with 200 patches (some 1,500 dispatches) costs nothing there. An entry is stored only when stage 5 ran; the `.healed` and `.healedPreview` roles keep a same-size tile from overwriting the preview's entry; the cache is cleared with the pooled textures, and in `setAIDenoised`. `HealCacheTests` checks the key covers every field.

**Session state that is not in the edit.** Model masks (§8.4), the touch-up mask set (§8.8), the AI denoise result and the dust analysis Find Spots keeps for re-detection live on the `ImageSession` or the editor, rebuilt from the image when needed and never stored.

**Decision:** the planned per-stage cache keyed by all upstream parameters was not built. Demosaic is the expensive stage; the rest re-render a fit-to-window preview in a few milliseconds. The heal cache is the one exception, because automatic heal lists made stage 5 expensive.

**Viewport-resolution rendering.** Fit-to-window editing renders a binned preview: Bayer quads binned by the largest factor that keeps the image at least as large as the viewport (`RenderScale.fitting` → `.binned`), with no demosaic. If no binning fits, the whole frame renders at full resolution.

**Zooming in.** When the user zooms to 100%, only the visible tiles are rendered at full resolution.

**Full-resolution rendering.** Full-resolution renders happen only for export, or asynchronously when the viewport needs them.

### 8.3 Display

The viewport is a `CAMetalLayer` with the `rgba16Float` pixel format and extended linear Display P3 (`MetalImageView.swift`).

**Headroom.** The pipeline renders to the screen's *potential* EDR headroom, capped at 4× SDR white (`DisplayHeadroom.renderCeiling`), which doesn't move with the brightness setting. Each present rolls highlights off to the headroom the screen shows at that moment (the present kernel's `toneMapToHeadroom`), so a brightness change costs a present, not a render. Moving to a screen with a different potential headroom re-renders only if that changes the capped ceiling. With HDR display off, while soft proofing, or on an SDR screen, the render uses headroom 1.

**EDR policy.** `wantsExtendedDynamicRangeContent` is on only while the image on screen was rendered with headroom above 1 and the screen can show some of it. EDR raises the backlight and costs power, so it stays off otherwise.

**Presenting.** The view redraws only in response to user input, a finished render or a screen change, never continuously. Presents go through an `NSView` display link that runs only while a frame is pending, so several requests in one refresh interval draw once. A frame identical to the one on screen (same render generation, transform, crop, surround, drawable size and headroom) is skipped.

**Input.** What mouse, trackpad and wheel events mean is decided in `ViewerInteraction` (`PixelEngine`), plain values tested without a window. At fit in Loupe and Develop a two-finger sideways swipe steps one image, however long the swipe, and its momentum does nothing; no swipe steps in Compare or while a crop, spot or mask tool is on. Zoomed in, two-finger scrolling pans. Pinch, or scrolling with ⌥ or ⌘, zooms about the pointer and stops when the fingers lift. A two-finger double-tap toggles fit and 100% at the pointer, as a double-click does. With Settings › Library › Arrow keys pan a zoomed-in image on (off by default), the arrow keys in Loupe and Develop pan an image zoomed past fit by an eighth of the view; at fit ← and → still step, and Previous and Next in the menus always step.

**Square pixels.** The present kernel samples full-resolution layers bilinearly, which keeps window resizes and mid-gesture upscales smooth, and switches to nearest-neighbour past 200% (`ViewerInteraction.samplesNearest`), so demosaic, sharpening and noise-reduction artefacts can be judged pixel by pixel.

**Magnifier.** On a fitted image in Loupe, Compare or Develop with no tool on, a mouse press held still for a quarter of a second, or dragged, shows a round loupe at one image pixel per point about the pointer until the button is released. The present kernel draws it as a third layer: inside the circle the same composite runs at the loupe's zoom, from a small full-resolution tile of the area under the pointer where one covers it, and softly from the base preview meanwhile. The tile (the loupe's area plus a margin of 96 sensor pixels) is rendered only when the pointer leaves the one on hand, at most once per 33 ms, and keeps its size as the pointer moves, so its pooled textures (in a pool of its own) are reused; when keystone or a heal in view changes the size, the previous size's textures are released. Anything that renders the view again, a neural denoise result or a regenerated mask included, renders the loupe again too. Nothing renders while the mouse is still or up. Edits and before/after show in the loupe while it is held.

**Full-screen image** (View > Full-Screen Image, F) uses the system's full screen with the image alone, in Loupe (entered from the grid, Compare or Survey) or Develop; going to the grid, Compare or Survey leaves it. The mode follows the window's own full screen, from its notifications: because AppKit ignores a request to toggle while the window animates in and abandons one while it animates out, F pressed during either animation takes effect once it ends; leaving full screen by the green button or ⌃⌘F brings the panels back as the window starts out; a window already full screen when F is pressed stays so after; and should the window drop an animation unannounced, the mode goes off with it. The pointer at the left edge brings in the library panel, at the right Develop's adjustments (Develop only), at the bottom the filmstrip, one at a time, each closed when the pointer leaves it; the top edge is left to the menu bar. The image and the panels are laid out up to the top of the window, ignoring the strip the window's toolbar goes on reserving there when SwiftUI hides it (which showed as an empty grey bar above the image); the system already places a full-screen window below a notched display's camera housing. Develop's adjustments stay built off screen once shown, so the panel keeps its scroll position; the other panels go when they close, taking their thumbnail loads with them.

**Second display** (View > Show Loupe on Second Display, with two or more displays). Another display shows the lead image at fit with the Loupe caption, clear of that display's menu bar and Dock. It is view-only (zoom, pan and tools stay in the main window) and mirrors the editor: what Develop, Loupe or Compare's Candidate shows, Before/After and the mask overlay included; in Survey it draws the focused pane; in the grid it loads the selection once the selection has settled for 150 ms, and again after an undo or a move closed it. It draws the editor's preview (§7.2), rendered to the brighter display's potential headroom, so an SDR main screen next to an XDR shows the HDR render with its highlights fitted to SDR, as an XDR at low brightness does. It closes when its display is unplugged or the main window closes.

**Slideshow.** The slideshow's `CAMetalLayer` uses the viewport's pixel format and colour space with EDR off. Slides are SDR renders (§8.5), and its display link runs only while a transition animates.

**Scopes.** The histogram, waveform and vectorscope are computed on the GPU using per-threadgroup atomic histograms that are then reduced into one result. The histogram also counts luminance (drawn as an outline), pixels above SDR white (shown while the viewport renders with headroom) and shadow clipping per channel. Scope measurements run at most once per 100 ms while a slider is dragged, with a trailing update.

### 8.4 Masking

**Parametric masks.** Brush, linear gradient, radial gradient and luminance or color range masks are stored as parameters and rasterized on the GPU when needed.

**AI masks.** Model masks run through Core ML (`MLKit`):

- **Subject:** one prediction, no clicks. BiRefNet general-lite (`birefnet-lite`, bundled, 1024², sigmoid inside the graph, `SubjectSegmenter`) is the default: 468 ms per mask on an M4's GPU, IoU 0.997 against PyTorch. Apple Vision's foreground-instance request is the built-in alternative and the stand-in when the edit's model is missing. Other subject models (BiRefNet General and Portrait, U²-Net, MODNet, IS-Net) can be added from disk; a manifest's `refine: guided` runs `GuidedMaskRefiner` (CPU box sums, radius 8, guide = the analysis render's luminance) on the model's output.
- **Click-to-select:** SAM 2.1 small (image encoder, prompt encoder, mask decoder, FP16), bundled; Tiny, Base+ and Large can be added. The clicks are stored; about 40 ms per click. The editor keeps one prompt session per model id in use.
- **Class masks:** SegFormer-B2 fine-tuned on ADE20K (sky, people and other classes). Without the model, sky falls back to a heuristic and people to Vision.

Model masks are stored as parameters (kind or clicks, plus model version) and regenerated from a small render of the image when needed, then cached in memory; mask pixels are never stored. Export regenerates them the same way (`ExportWorker`).

**Registry.** `ModelRegistry` (`MLKit`, a `final class: @unchecked Sendable` with one `OSAllocatedUnfairLock` over its listing cache and loaded-model dictionary) lists every model the app knows: the built-in Apple Vision row, the bundled manifests and `ModelCatalog.json` in `Sources/MLKit/Resources/Models/`, and the folders under `externalModelsDirectory/<id>/`. Each model has one `<id>.model.json` (`ModelManifest`, Codable) naming its display name, purpose, kind (`subjectSegmentation`, `promptedSegmentation`, `semanticSegmentation`, `denoise`), licence (with `commercialUse`), source page, size, input size and packages; `packages[].sha256` hashes the package contents (`Manifest.json`, `model.mlmodel`, `weight.bin`, in that order, each as relative path, `0x00`, bytes), computed identically by `scripts/latent_manifest.py` and `PackageHash.sha256(ofPackageAt:)`; catalogue rows carry `sha256: nil`, which the importer refuses. `CoreMLStore` compiles each package once into `mlmodels/` under Application Support, keyed `"<id>-<package>-<sha16>.mlmodelc"`, deleting older entries for the same package. Loading goes through `registry.load(...)` so a model is loaded once and shared; `releaseAll` drops them under memory pressure (§7.2). The denoisers keep their own loading and their picker stays hidden.

**Resolution and substitution.** A mask names its model by id and version (`ModelRef`); resolution is by id only, so a different installed version runs. A model this Mac lacks, or a `modelVersion` that cannot be parsed, is substituted by the kind's default (Apple Vision for subject, the bundled SAM Small for prompted, the bundled SegFormer or its heuristic for classes) and reported: the mask's row says "BiRefNet General is not installed — shown with Apple Vision instead." with Get… and Add Model…; `ExportWorker.regenerateMasks` returns the substitutions, the export queue's notes count photos "with substituted masks", and Print and Contact Sheet add a sentence. A prompted mask with no click-to-select model installed at all masks nothing and says so. `AppPreferences.subjectModel` and `promptedModel` (`latent.subjectModel`, `latent.promptedModel`) are consulted only for a **new** mask; the Add menu lists the installed models of each kind, and a mask row's Model menu reruns it with another (`rerunMask`, an ordinary parameter change under undo and history).

**Compute units.** Rank `cpuOnly` 0, `cpuAndGPU` 1, `cpuAndNeuralEngine` 1, `all` 2; a model loads with the lowest rank of the user's preference, the manifest's `computeUnits` (a ceiling; absent means none) and, for an imported model, `cpuAndGPU`. Core ML models therefore load with `.cpuAndGPU` by default. The Neural Engine is opt-in (a Settings choice, or `LATENT_ML_COMPUTE=all`) because on macOS 15.7 the ANE compiler hangs at model load for SAM 2 and SegFormer (`CoreMLStore.swift`), and BiRefNet's manifest pins `cpuAndGPU` because the ANE compiler spends 103 s on its graph and every prediction then fails. **Decision:** a hang is not worth a few tens of milliseconds; the GPU is fast enough.

**AI denoise.** Shipped, not deferred to v1.x. NAFNet trained on SIDD, width 32, bundled as Core ML, runs once per image on the full frame in 256×256 overlapping tiles, on the GPU by default. The camera RGB is gamma-encoded for the network and lifted onto a pedestal, [0, 1] mapped to [0.15, 1] and back: the published weights diverge, in float32 as well as on the GPU, on smooth tiles whose encoded mean is below about 0.07 and turn them into bright blocks, and above that the network is stable and close to shift-equivariant. A tile whose output still drifts from its input by more than 0.05, in encoded units averaged over 16×16 blocks, is replaced by the input (`AIDenoiser.diverged`); denoising moves local means by well under 0.02. `AIDenoiseTests` checks smooth shadows and the sample frame for broken tiles, and the frame edges of a perspective-corrected edit for colour. The result is cached in the session as camera RGB and blended into every render by a strength slider (§8.1 step 3). The edit stores the strength and model name. A width-64 model can be built by the conversion script but is not offered; the download path that once fetched it is gone (§4a). Critical memory pressure drops the cached result, and it runs again when pressure returns to normal (§7.2).

### 8.5 Export

Exports go through `ExportWorker` (`MLKit`), whether they come from the export queue, from Export Open Image in the left panel, or from Edit in External Editor, so all three write identical files for the same settings. Per image:

1. Open the raw, rebuild the edit over the image's defaults (`ExportPlan`), regenerate model masks (recording any substituted model, §8.4) and the touch-up regions (`TouchUpRegions.regenerate`: the analysis render and the seeded landmark refit of §8.8, so exports, prints, contact sheets and slides carry the masks the editor showed) and, if the edit uses it, run AI denoise. Dust spots and blemishes are ordinary heal patches and need nothing; `EditedThumbnailRenderer` and `latent-cli` link no MLKit, so they render the touch-up stage as a no-op and model masks as absent.
2. Render the SDR image. A resized export renders binned towards the target size (`ExportPlan.scale`), measured on the cropped image so a crop still reaches the size asked for; the exporter then rotates, crops and shrinks to the exact size on the GPU with a Lanczos 3 filter evaluated in linear light (`ExportResampler`), and quantises to 8 or 16 bits. A full-size export skips the resample pass.
3. **Watermark** (off by default, `ExportWatermark.swift`). One line of text is stamped into a corner after the resize and before the encode, into the file's own pixels, so its size is a share of the output's short edge (1–20%) at any export size. `{year}` becomes the capture year (Gregorian calendar) and `{name}` the original file name. Only the text's bounding box is rasterised, with Core Text on the CPU, and blended into the bytes the encoder is about to read: no extra copy of the picture. The colour is picked as sRGB and converted to the output space. With a gain map, the map is neutralised under the text, so the text isn't brightened on an HDR screen. It is an export setting, never part of an edit.
4. **Gain map** (JPEG and HEIC, off by default, `GainMap.swift`). After the SDR pixels and the gain map's half-size linear base, the same edit renders again with headroom 4, reusing the pooled textures; a kernel computes the per-channel gain in stops over a fixed range derived from the tone curve, and the map goes to ImageIO as ISO 21496-1 auxiliary data. The main image is byte for byte the SDR export.
5. **Metadata** (on by default, location off; both switches in the export sheet and, remembered, in the left panel for Export Open Image). The photo's own EXIF, GPS, IPTC, ExifAux and XMP are read in the decoder service (§4a). Removed: storage tags (compression, CFA pattern, orientation, pixel size, colour space, subject area and location, focal-plane resolution, AF areas), makers' private blocks, the source's document and instance IDs, and the `crs`, `hdrgm` and `HDRGainMap` namespaces. Summary fields from LibRaw fill gaps. Latent's keywords are added to the file's own; its rating replaces the file's when above 0. Software is Latent, orientation 1, Exif ColorSpace 1 for sRGB and 0xFFFF otherwise. No embedded thumbnail. Without location, the tags in `SourceMetadata.locationTags` (GPS, place names, body and lens serial numbers) are removed from the dictionaries and the XMP. With metadata off, the file carries no camera, date, location, keywords or rating. The fallback capture date is formatted in the Gregorian calendar with a POSIX locale.
6. **Writing** (`SafeFileWriter`). The file is written under a hidden temporary name in the destination folder, flushed, then moved into place; a replaced file keeps its creation date, permissions and Finder tags. A crash, full disk, encoder error or cancelled export leaves no partial file and never costs the file that was there. Where the sandbox grants only the one file (a Save panel), the temporary file goes in the system's item-replacement folder on the same volume. A write that may not replace (a new name under Add a number or Skip, or a Save panel name that was free) is moved into place with `renamex_np(RENAME_EXCL)`, so a file that appeared during the render is kept and the queue settles the name again.

**Other callers.** `Exporter.encodableImage` does everything short of the encode (rotation, crop, resize, quantisation, watermark, gain map) and `Exporter.encode` encodes to memory with the same encoder and properties as a file, so a byte count is the file's size. The export sheet renders the first selected image once (`ExportPreviewRenderer`, re-rendered only when a setting that changes the rendered pixels does: the render is made without the watermark and with metadata on, and `ExportWorker.Rendered.finished` stamps a copy and sets the metadata for the sheet's settings; a new render waits for the one before to stop, which is cancelled only when nothing waits on it, and the export queue waits for the sheet's render to stop) and encodes it for the **size estimate**, scaled by each other image's output pixel count (`ExportSizeEstimate`), exact for one image and approximate for a batch, and for the **quality comparison** window, which encodes tiles cut on a 64-pixel grid (`QualityComparePlan`) at two to four JPEG or HEIC qualities; JPEG tiles match the file's blocks exactly, and HEIC tile edges can differ slightly because HEVC's prediction reads neighbouring blocks. The sizes shown are whole-file encodes. `ExportWorker.renderImage` runs the steps up to the pixels and returns a `CGImage` without metadata, for Print (16-bit Display P3 at the printer's resolution, capped at 360 dpi, AI denoise included, converted into the Soft Proof ICC profile when soft proofing is on with one and that is chosen; photos that couldn't be rendered are named once the job is done) and Contact Sheet (cells rendered at their size, AI denoise only for cells 1600 px or larger). `ExportWorker.renderForScreen` shares the plan, mask regeneration and exporter resize for the slideshow, but renders into a GPU-private 8-bit texture sized by `SlideshowGeometry.renderPlan` (the crop-aware render size), SDR in Display P3, without AI denoise or metadata. Edit in External Editor writes a 16-bit Display P3 TIFF at full size with Export Open Image's metadata and location switches, named `<name>-Edit.tif` and numbered rather than replacing anything (`replacesExisting: false`).

**Staying awake.** While the export queue, Export Open Image, Edit in External Editor, a print, a contact sheet, a Photo Merge or AI noise reduction runs, `ExportActivity` holds off idle system sleep (`idleSystemSleepDisabled`); the display may still sleep. A playing slideshow holds off display sleep instead, and lets go while paused.

**Naming.** The queue plans every file name for the whole batch before writing anything (`ExportBatchPlanner`), so the sheet's preview and warnings match what gets written. Images whose template gives the same name are always numbered; names already in the destination follow the collision policy (add a number, replace, skip); an unknown token in the template disables Export. Each planned name is checked against the disk again just before its file is written.

### 8.6 Photo Merge

Photo › Photo Merge writes one float16 LinearRaw DNG beside a reference photo, from two or more selected photos. `docs/PhotoMerge.md` is the plan and the algorithm, and the user guide is `docs/wiki/Photo-Merge.md`. There are three merges, all of them shipped: **HDR…** (⌃H) and **HDR Merge Without Dialog** (⌃⇧H), **Panorama…** (⌃M), and **HDR Panorama… (Experimental)** (⌃⇧M). HDR aligns and deghosts; the tripod-only limit of the first plan was lifted by Auto Align (phase 6a of `docs/PhotoMerge.md` §8).

**The engines** all live in `MergeKit`, which has no UI, and the app knows each only through a protocol — `HDRMerging`, `PanoramaMerging`, `HDRPanoramaMerging` (`MergeKit/*/…MergeAPI.swift`) — created in one place (`PhotoMergeEngine`), so every dialog and job is tested against a fake engine.

- **HDR** (`MergeKit/HDR`). Demosaic each frame, warp it onto the reference (`MergeKit/Align`: phase correlation then ECC, not Vision — §0 of the plan says why), weight it by exposure, distance from clipping and the ghost mask (`MergeKit/Deghost`), and resolve the sums. `lensApplied` is false and the lens identity is kept, so Develop corrects the result once. Frame limit `memoryPolicy.isConstrained ? 5 : 9`.
- **Panorama** (`MergeKit/Pano`). Prep bakes the lens correction in; the geometry registers pairs, bundle-adjusts the cameras with a shared focal length, projects, solves gains and finds the Auto Crop rectangle; the stitcher warps and multi-band-blends into the canvas tile by tile. `lensApplied` is true and the lens tags are dropped. It accepts linear DNGs as well as Bayer raws, which is what makes HDR Panorama possible.
- **HDR Panorama** (`MergeKit/HDRPano`, experimental). Composes the other two and adds no pixel code: group the selection into positions, merge each to a temporary DNG, stitch those. `docs/PhotoMerge.md` §0 records why it stays marked experimental.
- **Dialogs** (`HDRMergeSheetModel`, `PanoramaMergeSheetModel`, `HDRPanoramaMergeSheetModel`). The engine's `analyse` runs as the dialog opens; the photos are listed with what the analysis found (HDR: brightest first, EV against the reference; Panorama: capture order, where each points, its gain, and which are left out), with the output size, the estimated file size, the planned name and the warnings in plain words. An error replaces the list. Each always says that edits on the source photos aren't used. HDR previews the merge itself on cached reduced frames and lets the reference be picked for that merge only; Panorama previews the real stitch of reduced frames; HDR Panorama has no preview, because an honest one would have to merge every position first.
- **Options.** HDR: Auto Align, Deghost (and Show Deghost Overlay, deliberately not remembered) and Auto Settings. Panorama: Projection, Auto Crop and Auto Settings. HDR Panorama: both sets. All are remembered in `PhotoMergePreferences`, under separate keys per kind.
- **Never refuse a panorama for its size** (Harman's rule). `PanoramaOutputSizer` works out the largest size this Mac could then *edit*, from the GPU's maximum texture side and 40% of its recommended working set at 112 bytes per edited pixel; the dialog states what would have been made and what will be, and the Merge button won't fire until that is agreed. The agreement is asked again whenever the size changes and is never remembered.
- **Job** (`PhotoMergeQueue`, `PhotoMergeJob`). One file serves all three kinds: only the engine, the words and the suffix (`-HDR`, `-Pano`, `-HDRPano`) differ. It takes the export queue's one GPU job slot (`ExportQueue.claimSlot`): a merge doesn't start during an export and Export waits for a merge. It registers with `OutputJobs` (keep-awake activity, file commands refused, quitting asks and cancels) and publishes the engine's progress to the left panel's Export section, where it can be cancelled.
- **Commit** (`docs/PhotoMerge.md` §5). The name is `<reference base>-HDR.dng`, then `-HDR-2`… (the panorama's reference is the first photo the stitch actually joined), free only when no file, sidecar or row holds it (`MergeNaming`, the same test `writeMergeSidecar` makes; §5.7's rule that a sidecar left behind holds its name). The engine calls back with the stored recipe once the pixels are merged, and the job writes the result's sidecar (`Library.writeMergeRecipe`, sources as paths relative to the result's folder with the catalog's hash and capture time) before the DNG exists. A merge that throws or is cancelled after that takes the sidecar back (`Library.discardMergeRecipe`), and a DNG the engine left anyway goes to the Trash. A name taken at the last moment (`SafeFileWriter.DestinationExists`) discards the sidecar beside the other file, which isn't the merge, plans the next name and merges again, up to three times, as exports do. On success the Library refreshes (reconcile gives the new row the waiting sidecar's recipe), the result is selected, a filter hiding it is cleared, and VoiceOver announces it; failures go to the status bar. Auto Crop and Auto Settings are stored through `Library.saveEditStack` as the result's **first edit**, one step, so a single Undo in Develop returns the merge exactly as it came out; a first edit that fails is reported without losing the merge.

---

### 8.7 Sensor dust

Dust on the sensor makes faint round shadows at the same places in every photo, clearest at small apertures. `docs/Retouch.md` §6 is the plan; this is what runs.

**Analysis** (`DustDetector.analyse`, `PixelEngine`): `renderCameraRGB(.binned(quads: 1))` in the `.analysis` texture pool, which returns at the demosaic seam, so the map is **un-denoised** binned camera RGB with white balance only (not `.sceneLinear`, whose exposure and locals would fake dips under a darkening mask); luminance `0.25R + 0.5G + 0.25B` as log2, converted row by row from the Float16 readback, which is then freed (about 72 MB peak at 24 MP). `binSpan = 2`; a map pixel maps to normalised sensor coordinates as `HealStage` does.

**Detection** (`BlobDetector`, Swift and Accelerate, no Metal): noise as 1.4826 × MAD per 64² tile of a high-pass, interpolated between tiles; difference-of-Gaussians at three scales on a downsampled pyramid (a direct σ = 60 px blur on a 6 MP map would take seconds); 3×3 and across-scale maxima above `max(minimumContrast, contrastSigma·σ_local)`; a region by flood fill; kept when its equivalent radius is in band, it is round enough, its centre sits below the surrounding annulus, the annulus is smooth and its gradient small; merged when closer than 1.5(r₁ + r₂); capped at 200, best first. The bands are Small 4–8, Medium 6–16 and Large 12–40 sensor pixels; the photo's aperture and crop factor predict a radius (`expectedRadius = 0.75 / (N·pitch)`) that narrows the band. Sensitivity 0…100 maps onto the contrast, circularity and surround thresholds. Each blob becomes a `HealPatch` in `.heal` mode with feather 0.5 and a source placed by `DustSourcePlacer`: eight directions at 2.75r, then 3.5r and 4.5r, rejecting sources that leave the sensor or overlap another spot or patch, taking the smoothest survivor; a spot with no source is dropped. Blobs centred inside an existing dust, blemish or heal target are dropped too.

**Editor** (`EditorModel+Dust.swift`, `DustPanel.swift`, `DustOverlay.swift`): Find Spots **replaces** the dust list as one history step (a preceding slider move is flushed first); Sensitivity and Spot Size re-detect from the kept analysis without a new render while the tool is armed; the tool shows rings to remove a false spot or add one by hand (the band's centre radius, source by the gradient-free rule); Visualise Spots is the display pass of §8.1; Save as dust map… and From dust map… go through `DustMapStore`. Auto Adjust (⌘U) does not run Find Spots: it is pressed on every image while culling, and a GPU analysis plus up to 200 patches there is a change nobody asked for. The analysis is dropped when the image changes, the tool is disarmed, or memory pressure is reported.

**Dust maps** (`DustMap.swift`): `{ id, camera, sensorSize, created, referenceName, referenceCaptureDate, aperture, options, spots }`, titled "Nikon D750 · 12 Sep 2026 · 41 spots", stored atomically and versioned in `~/Library/Application Support/latent/dust-maps.json` (an unreadable file reads as empty). Keyed by the camera string `ImageRecord.camera` ("Make Model"), so a target from another camera or sensor size is skipped with a note; two bodies of one model share a map (a serial key waits for the LibRaw shim). `DustDetector.verify` looks ±r around each map spot for a peak passing the contrast and circularity tests at the target's threshold, skips absent spots, keeps the larger radius, and places sources per target.

**Photo › Remove Dust…** (`RemoveDustSheet.swift`, `DustRemovalJob.swift`, §11): enabled when the editor is ready, there is an image or a selection, no export, merge or file operation runs and no text is being edited. Targets: the Library selection; in Loupe, Compare and Survey the primary; in Develop the open image in memory (undoable, no queue; Find spots and Use dust map only). `RemoveDustSheetModel` is testable without the view: Find spots in each photo / Use dust map (the maps for the selection's cameras, newest first; a remembered map that no longer exists falls back) / New dust map from reference photo… (Choose File…, opened through `RawFile(path:)` on the granted URL, or Use the selected photo); Sensitivity and Spot Size; a note counting photos from another camera; Remove Dust disabled while the GPU slot is busy. Options are remembered in `DustRemovalPreferences` (`RemoveDust.method/sensitivity/size/mapID`). The job's `prepare` analyses the reference and saves the map; `process` opens the raw, rebuilds the parameters through `ExportPlan`, analyses, detects or verifies, dedupes against existing dust and heals, and returns the **migrated** stack (`session.stackForThisImage`, with `frame = activeAreaFrame`), so a stored stack with readout-frame heals is migrated in the same write rather than shifting the dust by the masked border on bordered cameras.

### 8.8 Touch-up

Per-face skin smoothing, teeth whitening, brighter eyes and blemish removal. `docs/Retouch.md` §7 is the plan.

**Faces** come from `FaceLandmarker` (`MLKit`): one `VNDetectFaceLandmarksRequest` (revision 3, 76 points) on the upright image, returning observations in the render grid's normalised coordinates, left to right; `RedEyeDetector.eyeCandidates` is a consumer. `TouchUpFace.boundingBox` is on the **raw** sensor grid: Find Faces detects on the output-grid analysis render and maps the box's corners back through `RenderPipeline.rawSensorPoint(forOutputPoint:)` (the lens sampling's source points); regeneration maps the stored box forward with `outputSensorPoint(forRawPoint:)` (Newton on the same map; identity without lens correction), enlarges it 20 % and seeds Vision's refit, so lens and keystone edits never invalidate stored faces. A seed that yields no landmarks keeps the face with an empty mask and the status "Face 2 could not be found again". Faces narrower than 64 px are dropped and counted "too small".

**Analysis render** (`TouchUpAnalysis.render`): the image's defaults with as-shot white balance, no locals, red-eyes, touch-up or dust, and the edit's geometry copied (lens switches, manual distortion and vignetting, perspective), binned to a long edge of 2000–4000 px (Vision's fit needs faces of about 80 px), sRGB, in the `.analysis` pool. An analysis pixel maps to the output grid as `(x + 0.5)·span`, never `x/width·rawWidth`, since a binned render can fall a few pixels short of the raw width.

**Regions** (`TouchUpRegions.build` → `TouchUpMaskSet`): half sensor resolution, three r8 slices, skin, teeth and eyes, in one array, faces merged with max. Skin is the face contour closed over the forehead by an elliptical arc, gated by a CIELAB colour test around the polygon's median skin colour, minus the eyes, brows, outer lips and nostrils, feathered by the face width. Teeth are the inner-lip fill where L* is well above the lips' and chroma low, eroded and feathered 1 px. Eyes are the eye polygon with the pupil at 0, sclera 255 and iris 128. `ImageSession.touchUpMaskTexture(enabled:)` composites the enabled faces into one shared-storage texture, rebuilt only when the enabled set changes; a face switch therefore rebuilds a texture, not the regions.

**Kernel** (`TouchUp.metal`, `touchUpApply`, stage 16 of §8.1): the stage prepares perceptual luma blurred at σ 1.5 px and at σ = 0.035 × the median enabled face width (clamped 4…48 sensor px), both scaled by the bin span, with the local-contrast blur pipelines in roles of its own (its helper functions are prefixed twins of LocalContrast's, because `make_app.sh` compiles shader files separately while the runtime fallback concatenates them). Per pixel it samples the three slices by output position, like local masks: skin subtracts a clamped fine-minus-mid band scaled by the slider; eyes lift the local contrast and gain inside the sclera and iris; teeth take out the yellow (`max(0, 0.5(r+g) − b)`) and lift the luma a little; the luma ratio is applied to the linear pixel clamped to 0.25…4. The Show Skin Mask overlay (`RenderOutput.touchUpOverlay`) tints by the skin slice. Tiles and the magnifier region are inset by the blur's reach beyond the tile margin when the touch-up wants masks.

**Blemishes** (`BlemishFinder`, `MLKit`): `BlobDetector` over each enabled face's box in the analysis render with the skin slice as weight; radius 0.4–2.5 % of the face width, dark or reddish (a* above the skin median), contrast above 2.5 × MAD, round, smooth surround; the centre mapped output → raw; blobs inside an existing heal or dust target rejected; `HealPatch(radius: 1.6r, feather: 0.5, mode: .heal)` with a source found by `HealPatch.automaticBlemishOffset` (eight directions at 2.5r, inside the face, on skin, avoiding other blobs); best first, cap 64; a second Find Blemishes replaces the list.

**Editor** (`EditorModel+TouchUp.swift`, `TouchUpPanel.swift`, `TouchUpOverlay.swift`): Find Faces is one history step and builds the masks through the same seeded refit export uses, so every path builds them identically, plus a 40 pt thumbnail per face. Regeneration runs on open when `touchUp.wantsMasks` and the session has no masks, after Find Faces, 300 ms after a geometry parameter changes, and when pressure lifts after a critical drop; a detached task guarded by `self.session === session`. The tool draws the enabled faces' boxes faintly and a ring per blemish (click a ring to keep that spot, click skin to add one). Status: "Looking for faces…", "Looking for blemishes…", "Memory is low: touch-up will show again when memory recovers".

**Copy, paste, presets.** `merged(.touchUp)` copies the sliders and the blemish switch and keeps the destination's own faces and blemishes; `restricted(to:)` strips them from presets and the clipboard. In Develop, applying a touch-up that wants masks and has no faces runs Find Faces (and Find Blemishes when the switch is on) at once; Compare's Select pane and Survey's focused pane, which never save, do the same on screen. In the Library, `applyToSelectionOrEditor` writes the stacks, then starts `FaceFindJob` (§11) over the targets whose merged module wants faces, one undo group "Find Faces (12 Images)".

## 9. Camera and Lens Support

### 9.1 Cameras

| Camera | Format | Notes |
|---|---|---|
| Nikon D750 | NEF, 14-bit lossless or 12-bit | Mature LibRaw support |
| Sony A7 III (ILCE-7M3) | ARW, uncompressed or lossy-compressed | Lens-correction data is embedded in each file. Pixel Shift is deferred to v1.x |
| Canon EOS DSLR (model not specified) | CR2 and CR3 | Both formats are supported through LibRaw, so the exact model does not matter |

**Tested:** the Nikon D750, whose public-domain golden raw is the one sample file CI has; locally also Canon EOS 5D Mark II CR2s and Nikon D200 NEFs, the Photo Merge brackets fetched by `scripts/fetch_test_assets.sh --merge` (`TestAssets/`). The Sony row and CR3 are LibRaw-supported but unverified in Latent.

**Sensor support:**

- **Renders:** Bayer CFAs, and LinearRaw DNGs with three colours per pixel (float or 16-bit, such as Photo Merge results), which enter the pipeline at the camera-RGB seam. Anything else throws `unsupportedCFAForV1`.
- **Not built:** monochrome sensors and the planned CPU fallback for other formats. They open for metadata and thumbnails from the embedded preview but do not render.
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
| Magnifier tile render | The viewport's render path, at most one per 33 ms while the pointer moves | GPU |
| Export sheet size estimate and quality comparison: one render, then encodes and decodes | `.userInitiated`, a new render cancelling the one under way | GPU, then performance cores |
| Red-eye detection, Find Faces, Find Blemishes (Vision, then the blob detector) | `.userInitiated` | Performance cores, after an analysis render on the GPU |
| Find Spots and the dust re-detection | `.userInitiated`, detached | GPU for the analysis render, then performance cores |
| Remove Dust and Find Faces over a selection (`SelectionJobQueue`) | `.userInitiated`, one photo at a time, holding the export queue's GPU slot; pauses while memory pressure is critical | GPU, performance cores |
| Print and Contact Sheet renders; contact sheet pages | `.userInitiated`; pages drawn on the print operation's thread or a GCD worker | GPU, performance cores |
| Slideshow slides | `.userInitiated`, at most one in flight, only the next slide ahead | GPU |
| Moving, copying and renaming images | One operation at a time, in the order asked for, each image off the main thread | Storage |

The planned "Import" row is gone with import (§6).

The pipeline uses Swift structured concurrency throughout. Each catalog is an actor that owns its database connection.

**Launch.** The GPU context (device, command queue, shader library) is shared across the process and built off the main thread, so the window appears at once and an editor model may briefly report not ready. A bundle built by `make_app.sh` loads precompiled shaders when the Metal toolchain was installed; otherwise the shader sources compile at first launch (about 0.4 s).

**Catalog writes.** Ratings, keywords, saved edits, history, snapshots, batch paste, saving the Custom order, moves, copies and renames, and opening a folder go through `Library.perform`, which counts running operations. In the grid, rating, flag and rotation apply to every selected image the filter shows (a filter that hides selected images deselects them), each with its own row update and sidecar write, and rotation adds to the angle stored at the time of the write; a failure on one image doesn't stop the rest. In Loupe, Compare, Survey and Develop they apply to the image shown only (in Survey, the focused pane), and so do pasted settings and presets; Compare's Select image and Survey's panes are never written. Keywords apply to the lead image only.

**Undo in the Library.** Ratings, flags, rotation, keywords, pasted settings and presets are registered on the Library's own `UndoManager` with their `Catalog` as the target (`Library.undoRegistration`), each image going back to its own previous value, and removed when the catalog is replaced, since an image id means another photo in the next catalog. The changes are asynchronous and `UndoManager` files a registration on the redo stack only while it is undoing, so an undo or redo registers its opposite at once, and a fresh action registers its undo once it has finished, for the images it actually changed. A Custom order rearrangement registers with its catalog as the target too, and goes with it. Moves, copies and renames register by file (§5.7). In Develop, ⌘Z steps the image's edit history instead, and while a text field is being typed in, ⌘Z undoes the typing. Text fields file their typing on the window's undo manager, which is not the Library's, so undoing typing stops when the field's own steps run out rather than going on to a rating or a move; the Edit menu and ⌘Z reach the Library's manager only through `ContentView.perform`.

**Selection jobs.** `SelectionJobQueue` (`latent-app`, the `PhotoMergeQueue` shape) runs one `SelectionJob` at a time over explicit records: `DustRemovalJob` (§8.7) and `FaceFindJob` (§8.8). It claims the export queue's GPU slot, so it neither starts during an export or merge nor lets one start; `prepare` runs once (a reference analysis), then per record a detached worker holds one `RawFile` and `ImageSession`, reports "Photo 3 of 12: DSC_0107.NEF", checks for cancellation and waits between photos while memory pressure is critical; a per-image failure becomes a note. Nothing is written while it runs. At the end (or on cancel, for the photos done) the results go through `Library.setEdits(_:expecting:undoName:)` inside `library.perform`, ONE undo group ("Remove Dust (12 Images)"), skipping and naming any image whose stored JSON changed meanwhile; `ContentView` flushes the open image's pending save before the queue reads stored edits and calls `library.didRestoreImages?(changedIDs, .edits)` after the commit, which reloads the editor as an undo does. The job registers with `OutputJobs` (`.dustRemoval`, `.findFaces`) for keep-awake and the quit alert, and `LibraryPanel` shows its title, progress and a Cancel button.

**Quitting.** `applicationShouldTerminate` saves a pending edit at once, then waits up to 10 s for catalog writes to finish. If an export is running it first asks whether to stop after the image being written and quit, or keep exporting and not quit; stopping waits up to 60 s for that file, and a stopped export does not bring Finder forward. Export Open Image asks the same way (finish and quit, or keep working) and is waited for as long. Moves and copies stop after the image under way, which is waited for with the catalog writes, for up to 60 s (§5.7). Edit in External Editor counts as an Export Open Image. A print rendering, a contact sheet being written, a Photo Merge or a selection job (`OutputJobs`) is asked about too: a contact sheet stops unsaved, a merge is cancelled and waited for while it takes back its sidecar (§8.6), a dust removal or face search is cancelled and keeps the photos already done, and a print is waited for up to 5 minutes. A wait that runs out is logged and quitting goes ahead, first removing the temporary file of any write not yet committed (`SafeFileWriter.abandonPendingWrites`), which also runs when nothing needs waiting for.

---

## 12. Testing

**Golden images.** `GoldenImageTests` renders a public-domain Nikon D750 raw (raw.pixls.us, CC0, fetched and checksum-verified by `scripts/fetch_test_assets.sh`) with twenty fixed edits, one per area of the pipeline: as shot, exposure and tone, white balance, colour grading, tone ranges, channel curves, presence, detail, bilinear demosaic, geometry, heal and clone, the heal's ratio field, a brush-stroke heal across a bright rim into shadow (where a seam between pieces would show), red-eye on the frame's reddest cloth, twelve fixed dust spots with one overlapping user heal, touch-up with a fixture mask set on the session (`TouchUpMaskSet.fixture`, since Vision output is never golden-tested), touch-up blemishes as fixed patches, local adjustments, Display P3 output and 8-bit export. Each edit is saved to edit-stack JSON and goes through `ExportPlan`, the same code `ExportWorker` calls to rebuild the parameters, choose the render scale and the rotation; the exporter's GPU passes then rotate, crop, resize (the linear-light Lanczos 3 resample, §8.5) and quantise. Only ImageIO's file encode is left out. The result is compared, pixels and colour space, with 16-bit PNG references in `Tests/PixelEngineTests/Golden`: a 320-pixel overview of the frame, plus a 192-pixel full-resolution window of the in-focus detail where the edit is about fine detail.

A render fails if its mean absolute difference exceeds 0.0005 of full scale or its 99.9th-percentile pixel difference exceeds 0.005. Renders on one Mac are bit-identical, so the limits only absorb floating-point differences between GPU families. Three tests keep the harness honest: renders repeat exactly whatever was rendered in between (the stage cache and texture pool), the PNG references are lossless, and a 1/50 EV exposure change fails. When tuning the limits, a vibrance made 5% stronger inside the shader passed at 4x these limits and fails at them. On failure the render and an 8x difference image are written to `.build/golden-failures/`, which CI uploads as an artifact. An intended change of look is recorded with `LATENT_UPDATE_GOLDEN=1 swift test --filter GoldenImageTests`, and the new references are committed with the change that explains them.

**Not covered:** AI noise reduction (Core ML output differs between compute units, and a full run takes minutes; `AIDenoiseTests` checks that smooth shadows and the sample frame come out without broken tiles), on-screen EDR presentation, the magnifier and slideshow drawing, printed pages and gain maps. The export watermark, page layout, slideshow timing and the viewer's input rules have unit tests (`ExportWatermarkTests`, `PageLayoutTests`, `SlideshowTests`, `ViewerInteractionTests`), and `FileTransferTests` runs moves and copies with injected failures, including the copy-then-delete path a move to another volume takes. `GainMapTests` checks the map's gain range and that JPEG and HEIC maps rebuild the HDR render, and `ExportWorkerGainMapTests` (which needs a private sample, so it skips in CI) that an export writes a readable map; no reference image pins a map's pixels.

**Unit tests.** Seven test targets, 1,358 XCTest tests and 13 Swift Testing tests (21 September 2026, counted as `func test` and `@Test` per target): 384 in `LatentAppTests`, 362 and 3 in `PixelEngineTests`, 256 in `MergeKitTests`, 219 in `CatalogTests`, 121 in `MLKitTests`, 16 in `LensKitTests` and 10 in `HelpKitTests` (all Swift Testing). The retouch work added, in `PixelEngineTests`, the dust and touch-up stack round trips, `BlobDetectorTests` (a synthetic sky at three ISO levels with 25 blobs and decoys: precision ≥ 0.9 and recall ≥ 0.8 at sensitivity 50, none on a clean scene), `DustDetectorTests`, `DustMapTests`, `HealCacheTests`, `TouchUpKernelTests` and `LensRegionTests`; in `MLKitTests`, the manifest, registry, importer (a real import of the bundled NAFNet package copied to a temporary folder, every refusal leaving nothing behind, the zip path, and `ZipSafetyTests` for an archive that climbs out of its folder, one that unpacks to too much, one with too many entries, and an unpacker that complains) and compile-cache tests, `FaceLandmarkerTests` and `TouchUpRegionsTests` (synthetic landmarks always; the CC0 portrait when present), `BlemishFinderTests` and `ExportWorkerTouchUpTests` (a linear DNG written at test time from the portrait JPEG, which is why `MLKitTests` depends on `MergeKit`); in `CatalogTests`, `setEdits`; in `LatentAppTests`, the model menus, dust and touch-up tools, the Remove Dust sheet and `SelectionJobQueueTests` with a fake job over tiny DNGs. Besides the engine, catalog, lens and ML tests, `MergeKitTests` covers Photo Merge without the app: DNGs written and read back through LibRaw and Apple's readers, synthetic brackets and sweeps whose answer is known exactly, and the real sets in `TestAssets/merge` and `TestAssets/pano`, which skip themselves when absent. `HelpKitTests` (Swift Testing) loads the real `docs/wiki`: every page parses, the pages follow `_Sidebar.md`, and every link between pages names a page and heading that exist. `LatentAppTests` tests the app target's own logic through `@testable import latent_app`: the key and menu tables have no clashing shortcuts, command enabling, tool-size steps, VoiceOver wording and the Reduce Motion and Increase Contrast rules, and `ShortcutsPageTests` fails when `docs/wiki/Keyboard-Shortcuts.md` differs from what `Sources/latent-app/Shortcuts.swift` generates (`LATENT_WRITE_SHORTCUTS_PAGE=1 swift test --filter ShortcutsPageTests` rewrites it).

**Snapshot harness.** Debug builds carry `SnapshotHarness`, which walks the app through its main states (by default library, loupe, develop, crop, heal, compare, survey, export sheet, settings) and saves a PNG of the window at each, then quits, so developers and agents can see the UI without screen-recording permission. It is switched on by `LATENT_SNAPSHOT_DIR` and configured by the other `LATENT_SNAPSHOT_*` variables documented in `SnapshotHarness.swift`; release builds neither read them nor contain the code. Other steps, asked for with `LATENT_SNAPSHOT_STEPS`, picture the red-eye tool (`redeye`), the rename sheet (`rename`), the export quality comparison at the saved export preset (`quality`), the Contact Sheet dialog (`contactsheet`), a contact sheet written as a PDF into the snapshot folder, page 1 pictured (`contactsheetfile`), the print panel (`print`), a slideshow's first slide (`slideshow`), full-screen image mode with and without each panel (`fullscreen`, `fullscreen-left`, `fullscreen-right`, `fullscreen-bottom`; only the layout, in the window, unless `LATENT_SNAPSHOT_FULLSCREEN=system` makes the window really full screen, and a step fails when the image doesn't reach the top of the window) and the second display's Loupe (`second-display`, a window of `LATENT_SNAPSHOT_SIZE` when there is one display). `quality` (which renders the image at export size) and `slideshow` are not in the default steps; the two contact sheet steps select every visible image first. To picture a watermark preset without touching preferences, pass the preset on the command line as a defaults override: `.build/debug/latent-app -latent.exportPreset "<hex of the preset JSON>"`. It is a looking aid, not a test: nothing compares its pictures.

**Camera sample files.** The planned matrix was D750 (14- and 12-bit NEF), A7 III (uncompressed and compressed ARW), Canon CR2 and CR3, one monochrome file and one linear DNG. **Actual:** Nikon D750 NEFs, plus the Photo Merge brackets (Canon EOS 5D Mark II CR2s, Nikon D200 NEFs) from `scripts/fetch_test_assets.sh --merge`, all in `TestAssets/`, which is not in the repository. Tests that need a sample skip without it.

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
| 2. Catalogs | Folder catalogs, schema, XMP read/write, reconciliation, subfolder modes, grid view, ratings, flags and keywords | Scrolling a 20,000-image folder stays smooth; the catalog rebuilds from sidecars alone | **Done.** Subfolder modes are not in sidecars (§5.2). Later: a favourites sidebar with folder trees, a filmstrip, a thumbnail size slider and a cancellable thumbnail loader (§10), and automatic rebuilding of a damaged database (§5.3); then Survey, Custom sort and per-key sort directions, Finder tags read into the grid and filter, dragging images out to Finder, clickable stars, Move and Copy to Folder, drops on sidebar folders and Rename with sidecars (§5.7), Back and Forward between folders, and undo in the Library (§11) |
| 3. Import | Card import (§6) | — | **Dropped (September 2026).** Users copy files into a folder themselves; opening that folder in Latent creates its catalog in place |
| 4. Pro pipeline | Lens corrections (Lensfun, embedded data, manual), denoise, sharpening, color grading, process versions | All current lenses are corrected automatically | **Done**, except embedded ARW corrections (§9.2) and a process-version upgrade flow (§5.6) |
| 5. Local edits | Parametric masks; AI masks from Vision and Core ML | AI mask generated in under 1 second | **Done.** Plus spot healing, brush-stroke healing and red-eye removal (§8.1); then (September 2026, `docs/Retouch.md`) a model registry with BiRefNet Lite bundled and models addable from disk (§8.4), sensor dust removal with dust maps and a batch job (§8.7) and portrait touch-up (§8.8) |
| 6. Output | Export queue, ICC soft-proofing, HDR gain-map export, DNG export | Batch export keeps the GPU busy without stalling the UI | **Done** for export queue, soft-proofing and HDR gain-map export (September 2026, §8.5). Later: a text watermark, a size estimate, a quality comparison window, keep-awake during exports, Print and contact sheets, and Edit in External Editor (§8.5). **Not done:** DNG export |
| 7. Polish | Presets, copy/paste settings, snapshots, history, keyboard workflow | Beta release | **Done.** Later: every command in the menu bar from one shortcut table, typed slider values, an in-app Help window built from the wiki, and a VoiceOver, Reduce Motion and Increase Contrast pass; then trackpad swipes and gestures, the press-and-hold magnifier, square pixels past 200%, arrow-key panning, full-screen image mode, the Loupe on a second display and a slideshow (§8.3) |
| 8. Photo Merge | HDR, Panorama and HDR Panorama merges into float DNGs (`docs/PhotoMerge.md`) | A 3×24 MP tripod HDR in under 10 s; results open in Latent, Lightroom and Apple Photos | **Done, with HDR Panorama experimental.** The 10 s target has not yet been timed in a release build (`docs/PhotoMerge.md` §6 says how). DNG writer, linear-source rendering and the `latent:Merge` recipe done; HDR complete (⌃H with its dialog, preview, Auto Align, Deghost and Auto Settings; ⌃⇧H without the dialog). Panorama: the geometry, the stitcher and the app’s Panorama… (⌃M) dialog and job, against the `PanoramaMerging` contract — one row, Auto Crop as an undoable crop edit, and a panorama too big to edit made smaller with the user’s agreement, never refused. HDR Panorama (⌃⇧M, phase 9 of `docs/PhotoMerge.md` §8, `MergeKit/HDRPano`) composes the two: the photos are grouped into positions from their repeating exposures, the gaps between shots and, failing those, their overlap; each position is merged to a temporary linear DNG; those are stitched, since the panorama engine already reads linear DNGs. Marked **experimental** everywhere because no real HDR panorama exists to check it against. Next: multi-row and 360° |
| v1.x | X-Trans support, ML denoising, Pixel Shift, cross-catalog search UI | — | ML denoising **shipped** (§8.4). The rest not started |

---

## 15. Risks

| Risk | Mitigation |
|---|---|
| Demosaic and color quality falls short | Port proven GPLv3 algorithms and gate every change on golden-image tests. RCD is ported, and golden-image tests pin the output of every stage except AI noise reduction (§12) |
| LibRaw updates break decoding for a camera | **In place:** LibRaw 0.22.2 is pinned by commit and the build refuses a moved tag. **Open:** CI has no per-camera matrix and tests only the D750 (§12) |
| A crafted raw file exploits LibRaw | **In place:** decoding runs in a sandboxed XPC service with no file or network access (§4a) |
| The SQLite database and XMP sidecars drift apart | Sidecars are authoritative, writes are atomic, and the database can always be rebuilt; a database SQLite reports as damaged is set aside and rebuilt automatically (§5.3). **Exception:** subfolder modes live only in the database (§5.2) |
| Metal 3/4 API boundary assumed wrong | **Resolved:** checked in Phase 0 (task 6); no Metal-4-only API is used |
| Network volumes corrupt the database | **In place:** the volume type is detected and journal mode switched accordingly |
| Algorithm changes alter old edits | Process versioning, plus recording the Lensfun database version in each edit. **Open:** versions are recorded but not yet used to pin rendering (§5.6). **Happened:** the September 2026 ratio-field heal changed how existing heal patches render (clone keeps its maths, but patches now apply in order, each seeing the ones before), with the process version still `1.0`; the golden references were regenerated for it. Resized exports also changed slightly with the Lanczos 3 resample (§8.5) |
| An edit is lost on quit, or saved to the wrong photo | **In place:** quitting saves the pending edit and waits for catalog writes and the export file being written (§11); every save names its catalog, and the editor closes its image before another folder opens (§5.3) |
| Exports leak location | **In place:** location (GPS, place names, body and lens serial numbers) is a separate switch, off by default and in older presets, in the export sheet and for Export Open Image; a second switch strips all metadata (§8.5, §4a). **Open:** camera metadata, artist and copyright are on by default |
| Memory runs short on small Macs | **In place:** rebuildable caches are released under memory pressure; on 8 GB Macs Compare's Select pane closes its image when Compare is left, and Survey's panes give back their pooled textures after each render and close their images when Survey is left (§7.2). **Open:** each Survey pane holds a full sensor plane while Survey shows |
| Moving or renaming an image loses its edits or overwrites a file | **In place:** the sidecar goes before the file and the original last; nothing is overwritten (`RENAME_EXCL`, hidden temporary copies); undoing a copy uses the Trash; `FileTransferTests` injects failures part-way, including on the copy-then-delete path of a move to another volume (§5.7). **Open:** a crash or force quit in the middle of a long copy to another disk can leave a hidden `.latent-transfer-*` file in the destination (quitting removes it); RAW+JPEG siblings and a `.xmp` sidecar beside the raw are not carried |
| Undo in the Library changes the wrong photo | **In place:** rating, flag, rotation, keyword and paste undo is registered against its catalog and removed when another catalog opens, since ids restart; file operations undo by file URL and read what was actually done when they run (§11, §5.7). A Custom order rearrangement's undo goes with its catalog too |
| Red-eye's shader and its detector disagree on what is red | **Open:** the thresholds in `RedEye.metal` mirror `RedEyeTuning` in `RedEye.swift` by hand; no test ties the two |
| An untrusted model package or manifest | **In place:** the id pattern, http(s) URLs only, a zip-slip guard on a copy in the container, the content hash, the feature-name check and a refusal of stray files (§4a); the sandbox is the boundary, and an imported model is held to the GPU so it cannot hang the ANE compiler in-process |
| A sidecar names a model this Mac lacks | **In place:** the kind's default runs and the substitution is shown on the mask's row, with Get… and Add Model…, and in export notes (§8.4) |
| Large models plus the raw session on 8 GB Macs | **In place:** models load on demand and are released at a memory warning; the importer compiles one package at a time; the batch worker holds one session and pauses at critical (§7.2, §11). **Open:** a Survey of four BiRefNet-masked photos loads the model once but runs it per pane |
| Dust false positives (foliage, stars) and faint dust at wide apertures missed | **In place:** smooth-surround and gradient tests, sensitivity 50 by default, clickable rings, an undoable Find Spots (§8.7). **Open:** the detector is tested on synthetic dust and only a few real photos; the camera string keys dust maps, so two bodies of one model share a map |
| Heal cache staleness; hundreds of patches per render | **In place:** `HealCacheTests` checks the key over every field stages 3–5 read; the cache is cleared with the pooled textures and in `setAIDenoised`; slider ticks skip stage 5 on a hit (§8.2). **Open:** a batched dust kernel is deferred; tile pan reuse degrades with 200 spread spots |
| Vision landmarks fail on turned heads, glasses and hair; the seeded refit drifts across macOS versions | **In place:** a colour gate on the skin, a 64 px minimum, per-face on/off, Show Skin Mask, seeds that keep a face from being lost; drift is accepted as for every regenerated mask (§8.8). **Open:** luma-only smoothing leaves colour blotches; the teeth gate can catch a tongue or lip highlight |

---

## 16. Open Items

- **Namespace owner.** **Resolved** 2026-09-13: `https://github.com/Harmanjit/latent-raw/ns/1.0/` (`XMPSidecar.namespaceURI`).
- **Name availability.** **Resolved**, checked 2026-09-13: no "Latent" trademark in US or EU for software. A mobile app called "Latente" exists, so the public repo is `latent-raw` and the app is described as "Latent, a catalog management and RAW editor for macOS" to keep the two apart.
- **Tokina vignetting.** Open. Validate the borrowed Canon EF vignetting profile against real shots from the Nikon F version.
- **RawTherapee color comparison and A7 III render.** Open, carried over from PHASE0.md §4.
- **Dust on real photos.** Open: no dust test photos existed when the detector was written (`docs/Retouch.md` §0), so its sensitivity mapping is calibrated on synthetic scenes; check it on real photos as they turn up.
- **Catalogue pins.** Open: `convert_sam2.py`'s revision and package hashes for SAM 2.1 Tiny, Base+ and Large are still placeholders, so the script refuses to run until someone pins them; the rows show in Settings with their source link meanwhile.
- **A serial-number key for dust maps.** Open: maps are keyed by "Make Model" until the LibRaw shim exposes the body serial.
