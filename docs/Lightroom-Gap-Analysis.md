# Latent versus Lightroom: what is still missing

This document compares Latent at commit 2078c07 (3 November 2026, after the fifteen Lightroom-gap feature groups and the Help & Learning wiki pages were merged) with Adobe Lightroom as shipped on 2 November 2026: Lightroom Classic 15.6, Lightroom desktop 9.6, Lightroom mobile 11.6 and Camera Raw 18.7. It is a re-check of the 2 November analysis, which was made against commit 891f18f. The Lightroom list of 497 features is unchanged, because Adobe has released nothing since. Every row was checked again against the code by one agent per category, and every status change was checked by a second agent trying to refute it (11 of 110 changes were corrected that way). No build or test was run for this document.

How to read the tables: every row is one Lightroom feature. **Missing** means Latent has nothing comparable. **Partial** means part of it exists; the Notes column says what is there and what is not. **Present** means Latent has it, possibly under another name given in Notes, and you can reach it in the app. **Not applicable** means the feature conflicts with a Latent design decision (no network, no cloud or accounts, no import step, per-folder catalogs with no master catalog, no mobile app, no plugin ecosystem, no tethering, GPLv3 and free) and the decision is named. A status written as *old → new* changed since 2 November. Rows are ordered Missing, Partial, Present, Not applicable. Product says where Lightroom offers it: Classic, Cloud (desktop, mobile, web) or Both.

## Summary

Each cell shows the count now, with the 2 November count in brackets.

| Category | Features | Present | Partial | Missing | Not applicable |
|---|---|---|---|---|---|
| Library & catalog | 37 | 15 (8) | 7 (11) | 3 (6) | 12 (12) |
| Import & file handling | 26 | 2 (2) | 6 (3) | 0 (3) | 18 (18) |
| Metadata, keywords & search | 36 | 5 (1) | 13 (11) | 13 (19) | 5 (5) |
| Organisation: collections, filters, stacks, versions | 20 | 4 (2) | 5 (3) | 8 (12) | 3 (3) |
| Viewing, culling & comparison | 18 | 3 (3) | 9 (9) | 4 (3) | 2 (3) |
| Develop: tone & colour | 45 | 32 (13) | 5 (11) | 6 (18) | 2 (3) |
| Develop: detail, optics & geometry | 31 | 25 (5) | 1 (14) | 4 (10) | 1 (2) |
| Develop: local adjustments & masking | 37 | 18 (6) | 11 (15) | 6 (13) | 2 (2) |
| Develop: AI, retouching & generative | 36 | 11 (9) | 8 (6) | 2 (6) | 15 (15) |
| Presets, profiles, history & snapshots | 38 | 5 (5) | 15 (10) | 14 (18) | 4 (5) |
| Photo Merge (HDR, panorama) | 7 | 0 (0) | 1 (1) | 4 (4) | 2 (2) |
| Export & publish | 41 | 20 (8) | 6 (12) | 5 (12) | 10 (10) |
| Print & book | 20 | 5 (4) | 5 (6) | 8 (8) | 2 (2) |
| Slideshow, web & presentation | 23 | 1 (1) | 7 (6) | 8 (9) | 7 (7) |
| Soft proofing & colour management | 12 | 7 (4) | 5 (8) | 0 (0) | 0 (0) |
| Performance, previews & hardware | 22 | 11 (11) | 3 (3) | 1 (1) | 7 (7) |
| Platform, sync, mobile & ecosystem | 21 | 0 (0) | 1 (1) | 2 (2) | 18 (18) |
| Customisation, shortcuts & accessibility | 10 | 1 (1) | 3 (3) | 3 (3) | 3 (3) |
| Video | 7 | 0 (0) | 0 (0) | 6 (6) | 1 (1) |
| Tethering & capture | 4 | 0 (0) | 1 (0) | 0 (0) | 3 (4) |
| Help, onboarding & learning | 6 | 0 (0) | 3 (2) | 0 (1) | 3 (3) |
| **Total** | **497** | **165** (83) | **115** (135) | **97** (154) | **120** (125) |

Leaving out the Not applicable rows, Latent now fully covers 165 of the 377 Lightroom features that apply to it (44%, up from 22%), and has at least part of 280 (74%, up from 59%). The Develop module is now close to Lightroom's; what remains is mostly library workflow (stacks, faster culling, assisted culling, GPS and the rest of IPTC), preset and default management, and the modules Latent never set out to replace in full (Book, Slideshow, Web, Video).

## The gaps that matter most

These are the 15 gaps a Lightroom user is most likely to notice in their first week with Latent. Things ruled out by Latent's design (cloud, sync, mobile, plug-ins, tethering, an import step, a master catalogue) are left out. Move to Trash is also left out: Harman decided not to build it, so its row stays Missing "(skipped by choice)".

1. **Stacks (manual and automatic)**
   Latent has no way to group photos into a stack: no Group into Stack, no Auto-Stack by Capture Time, no stacking by visual similarity. Lightroom users rely on stacks to fold bursts, brackets and panorama frames into one thumbnail so the grid stays tidy while they cull. This would need a stack table in `Sources/Catalog/Schema.swift`, grouping logic in `Sources/Catalog/Library.swift`, and collapsing and expanding in `Sources/latent-app/ThumbnailGridView.swift`.

2. **Faster culling: Auto Advance, Refine Photos and selection commands**
   When you press a star, flag or label key, Latent stays on the same photo. There is no Auto Advance setting and no Caps Lock or Shift version of the keys. There is also no Invert Selection, no Select by Flag, Rating or Label, no Deselect Unflagged and no Refine Photos. When you are working through hundreds of frames, these small things save a lot of keystrokes. The keys are handled through `Sources/latent-app/Shortcuts.swift` and `Sources/latent-app/AppMenus.swift`, and the selection logic is in `Sources/Catalog/GridSelection.swift`.

3. **Assisted Culling**
   Nothing scores photos for sharpness, closed eyes, faces or exposure, and nothing suggests which to pick or reject. Lightroom now does this both during import and in the Library, and it helps most with big shoots such as weddings and sports. Latent already finds faces with Vision in `Sources/latent-app/FaceFindJob.swift`. A scoring job could build on that and feed `Sources/latent-app/FilterBar.swift` and the smart-collection rules in `Sources/Catalog/SmartCollectionRules.swift`.

4. **GPS, location and capture-time editing**
   Latent does not show GPS anywhere, cannot filter by location and cannot edit the capture time. Export can only keep or remove the GPS that is already in the file. Travel photographers use Lightroom's map and location fields a lot, and fixing a camera clock that was set wrong is a common chore. The reading side is in `Sources/Catalog/Metadata.swift`. Display and editing would go in `Sources/latent-app/DescriptiveMetadataSection.swift`, with storage in `Sources/Catalog/Catalog+Descriptive.swift`.

5. **The rest of IPTC, metadata presets and Copy/Sync Metadata**
   You can edit title, caption, creator and copyright, but not headline, location fields, contact details, usage terms, Alt Text or any IPTC Extension field. There are no metadata presets, and no command to copy one photo's metadata onto others. Professionals who send work to agencies or clients need these fields filled in on every photo. The fields would be added in `Sources/latent-app/DescriptiveMetadataSection.swift` and `Sources/Catalog/Catalog+Descriptive.swift`, and written to the sidecar through `Sources/Catalog/XMPSidecar.swift`.

6. **Keyword synonyms, keyword sets and keyword import/export**
   The hierarchical Keyword List is now in place. It still has no synonyms, no per-keyword Include on Export settings, no Keyword Sets palettes, no suggested keywords, and no way to import or export a keyword list. Anyone coming from Lightroom with years of controlled vocabulary has no way to bring it across. The keyword logic is in `Sources/Catalog/Library+Keywords.swift` and `Sources/Catalog/KeywordPath.swift`, the panel is in `Sources/latent-app/KeywordingViews.swift`, and export writing is in `Sources/PixelEngine/ExportKeywords.swift`.

7. **Locate Missing Photo and Find Missing Folder**
   When a file is renamed inside its folder, Latent relinks it by content hash. When a file leaves the folder, it just drops out of the catalogue, and Latent has no command to point it at a new location. Lightroom users are used to fixing the "?" badge after reorganising drives. The reconciliation code that would carry this is in `Sources/Catalog/Reconcile.swift`, with the sidebar commands in `Sources/latent-app/FolderSidebar.swift`.

8. **Smart Previews (working with the drive unplugged)**
   A favourite folder on a disconnected drive shows greyed out and cannot be browsed or edited. Lightroom users often keep raw files on an external drive and edit on a laptop from Smart Previews. Latent keeps only 512 px thumbnails (`Sources/Catalog/Thumbnails.swift`), so this would need a new proxy cache. The editor would also need a way to open a proxy instead of the raw, in `Sources/latent-app/EditorModel+Opening.swift`.

9. **Duplicate detection**
   Latent already hashes every file in `Sources/Catalog/FileHash.swift`, but it only uses the hash to follow renames. It never uses it to show you files that appear twice. A Duplicates view, or a smart-collection rule built on that hash, would be quick to add and helps anyone tidying up years of copied cards.

10. **Raw Defaults per camera and ISO**
    Every raw still opens with as-shot settings. You cannot say "photos from this camera always start with this profile and this noise reduction", and there are no ISO-adaptive presets. In Lightroom this is how people get a consistent starting point without applying a preset every time. The default edit is built in `Sources/PixelEngine/EditStack.swift` and loaded in `Sources/latent-app/EditorModel+Opening.swift`.

11. **Preset management: Amount slider, groups, favourites, import and hover preview**
    Presets apply at full strength from a flat menu. There is no Amount slider, no groups, no favourites, no search, no hover preview, and no way to import Lightroom XMP presets or zip bundles. Many photographers own preset packs and use the Amount slider all the time. All of this lives in `Sources/latent-app/PresetsPanel.swift`. Strength blending would also need support in `Sources/PixelEngine/EditStack.swift`.

12. **More inside masks: curve, Point Colour, grain, moiré, colour tint and Depth Range**
    Masks now combine components and have about 16 sliders. They still have no tone curve, no Point Colour, no grain, no moiré and no colour tint swatch. There is also no Depth Range mask, even though Lens Blur now makes a depth map. These are the tools Lightroom users reach for in more advanced local work. The parameters would go in `Sources/PixelEngine/LocalAdjustments.swift` and `Sources/PixelEngine/MaskComponents.swift`, and the rendering in `Sources/PixelEngine/LocalDetailStage.swift`.

13. **Before/After split and side-by-side, and editable Reference View**
    The `\` key only switches the whole view between before and after. There are no split or side-by-side layouts, and the photos in Compare cannot be edited. Comparing against a reference photo while editing is a standard Lightroom habit when matching a set. The view work would go in `Sources/latent-app/ImageViewport.swift` and `Sources/latent-app/MetalImageView.swift`.

14. **Camera and lens coverage: X-Trans and built-in lens corrections**
    Only Bayer sensors render, so Fujifilm X-Trans files (and Foveon and monochrome files) are read for metadata only. Lens corrections that the camera embeds in DNG, ARW or RAF files are not read either. For a Fujifilm shooter, or a Sony or Fujifilm user with a lens that is not in the bundled Lensfun data, this is the first thing that stops them. The demosaic path is in `Sources/RawCore/RawFile+BayerSource.swift`, with the LibRaw bridge in `Sources/RawCore/CLibRaw/clibraw_shim.cpp`. Embedded lens data would feed `Sources/LensKit/LensCorrection.swift`.

15. **Print essentials: print sharpening, templates and Picture Package**
    The print panel now does proper colour management. It still has no print sharpening (output sharpening only runs on export), no Print Adjustment brightness and contrast, no saved print templates, no Picture Package or Custom Package layouts, and no Saved Print. Anyone who prints regularly will miss these. The settings are in `Sources/latent-app/PrintLayoutSettings.swift`, the layout in `Sources/latent-app/PageLayout.swift`, and the rendering in `Sources/latent-app/PageRenderer.swift`. The sharpening code in `Sources/PixelEngine/ExportOutputSharpening.swift` could be reused.

*Also worth knowing:* Latent has no video at all, slideshows cannot be exported to PDF or video, and there is no web gallery. These matter less to most people switching for still photography.

## What changed since 2 November

The 15 feature groups merged since the first analysis closed most of the big gaps in the Library and the Develop module. Collections, hierarchical keywords, colour labels and virtual copies were the largest organisational holes, and all now work. In Develop, the white balance tools, Upright, colour grading, profiles and a content-aware Remove brought Latent much closer to what a Lightroom user expects. What remains is mostly speed-of-workflow features (stacks, auto-advance, presets), metadata depth (GPS, IPTC) and the output modules (print, slideshow, web).

- Collections, collection sets, target collection and Quick Collection: Missing → Present
- Smart collections: Missing → Partial (14 rule fields)
- Hierarchical Keyword List and keyword rename and delete: Missing → Present
- Colour labels: Missing → Partial (no label sets), now written to XMP
- Title, caption, creator and copyright editing: Missing → Partial
- Virtual copies: Missing → Present
- Batch rename with templates: Partial → Present
- Synchronize Folder (Refresh Folder, folder watching): Partial → Present
- Recently Added (previous-import source): Missing → Present
- Watched-folder Auto Import: Missing → Partial
- JPEG, HEIC, TIFF, PNG, WebP and AVIF editing: Missing → Partial
- RAW+JPEG pairs: Missing → Partial
- White balance presets, eyedropper and typed Kelvin: Missing/Partial → Present
- Parametric tone curve, targeted adjustment tools and point-curve presets: Missing → Present
- Global Saturation, B&W Mix, three-way Colour Grading, Point Colour and Calibration: Missing/Partial → Present
- Clipping overlay and pixel readouts (RGB and Lab): Missing/Partial → Present
- Camera profiles and creative looks: Missing → Partial (imported DCPs and built-in looks; no Profile Browser or LUTs)
- Upright (Auto, Level, Vertical, Full, Guided), Transform sliders and crop guides: Missing/Partial → Present
- Grain, post-crop vignette, sharpening Masking and Detail, and noise reduction Detail controls: Missing/Partial → Present
- Defringe, automatic CA removal and lens profile override: Partial → Present
- Mask components (add, subtract, intersect), Amount, Feather, Edge and Colour Range: Missing/Partial → Present
- Content-Aware Remove and Detect Objects: Missing → Present
- Lens Blur: Missing → Partial (no refine brushes, no bundled depth model)
- Export colour spaces, sizing, ppi, output sharpening, metadata levels, Export with Previous and multi-batch: Missing/Partial → Present
- DNG export with edits baked in: Missing → Partial
- Soft proofing and print colour management: Partial → Present
- Transparency checkerboard: Not applicable → Missing (Constrain Crop can now be turned off, which leaves empty edges)
- What's New page and in-app tutorials: Missing → Partial

## What Latent has that Lightroom does not

- Sensor dust maps saved per camera and applied across a selection (Photo › Remove Dust…), using a classical detector that needs no cloud. Lightroom's Dust Removal works one photo at a time.
- Per-face Touch-up with Find Blemishes on the desktop. Lightroom offers blemish removal only on mobile and web.
- A choice of subject-selection models (BiRefNet Lite, Apple Vision, importable SAM 2.1 sizes, U²-Net, MODNet, IS-Net) with licences shown. Masks are regenerated, so an export never goes stale.
- A choice of depth source for Lens Blur. You can add your own depth model from disk in Settings › AI › Models, and Latent records which source each edit used and recomputes the depth map at export. Lightroom uses only Adobe's own depth model.
- Live full-quality rendering of every slider in 2–4 ms, with no preview cache and no work done while idle.
- Waveform and vectorscope in Develop. Classic has only a histogram (Camera Raw 18.4 added a vectorscope).
- HEIC export, and an extended-range viewport with headroom readouts verified on an XDR screen.
- The export file-size limit works for HEIC (and AVIF where the Mac can write it) as well as JPEG. Lightroom limits file size for JPEG only.
- A Mid Grey tone control, and hue-preserving tone ranges that cannot swap tone order.
- Copy to Folder and drag-to-copy with edits attached. Lightroom moves files but does not copy them.
- Finder tags shown and filterable. Copy to Folder, Move, Rename, batch Rename with Template, Duplicate and keyword rename and delete are all undoable, including across folder changes.
- Panorama size consent ("Merge at n%") instead of refusal, and merge recipes recorded in the DNG.
- Thorough VoiceOver, Full Keyboard Access, Reduce Motion and Increase Contrast support, plus a light theme. Classic has none of these.
- A sandboxed XPC raw decoder, so a crafted file cannot crash the app. No telemetry, no network entitlement, and GPLv3.

## Library & catalog

| Lightroom feature | Product | Latent status | Notes |
|---|---|---|---|
| Remove from catalog / Delete from Disk / Delete Rejected Photos | Classic | Missing (skipped by choice) | Harman chose not to add Move to Trash. There is no delete command; `trashItem` is used only to undo a copy. |
| Convert Photos to DNG | Classic | Missing | No command converts a raw into a DNG that replaces it in the catalog. Export's DNG option writes a separate linear DNG with corrections baked in (see Render to DNG), not a lossless mosaic conversion of the original. |
| Validate DNG Files | Classic | Missing | No DNG checksum validation anywhere in the app. |
| Render to DNG (bake edits into a new DNG) | Both | *Missing → Partial* | The export sheet's file type now has "DNG (edits baked in)". It writes a full-size, cropped and upright linear DNG with white balance, exposure, noise reduction, lens corrections, healing and masks baked in. Tone, colour grading, presence and sharpening are left out, so the DNG opens with Latent's default look. |
| Locate missing photos / Find Missing Folder | Classic | Partial | Renames inside the folder are relinked by content hash, and putting a removed file back brings back its sidecar edits. There is no Locate Missing Photo or Find Missing Folder command: a file gone from the folder simply leaves the catalog. |
| Rotate, flip and Mirror Image Mode | Classic | Partial | Photo › Rotate Left/Right (⌘[ ⌘]) and Reset to Camera Orientation. Flip Horizontal and Flip Vertical are in Develop's Transform menu and the crop panel, and they flip the crop and masks too. There is no Mirror Image Mode for viewing the whole library mirrored. |
| Cloud Versions (Named and Auto) | Cloud | Partial | Named snapshots are kept in the sidecar, and the History panel lists edit steps. Latent makes no automatic versions. |
| Background process indicator | Classic | Partial | The status bar and Library panel show job progress with Cancel. There is no pause. |
| Catalog Settings: Metadata options | Classic | Partial | Sidecars are always written, with no toggles. Settings › Folders now has folder watching and watched-folder import, but there are still no metadata switches like Lightroom's (auto-write XMP, address lookup, face detection). |
| Folder colour labels, favourite folders and folder search | Classic | Partial | Favourite folders are there (Add Folder…, Add to Favourites, drag in from Finder). There is now a search field above the folder tree that finds folders by name inside the favourites. Folders still can't take colour labels. |
| Virtual copies | Classic | *Missing → Present* | Photo › Create Virtual Copy, Set Copy as Master and Remove Virtual Copy (also on the grid's context menu). Each copy has its own edit stack, shows in the grid with a badge, and exports on its own. |
| Previous Import source and import-complete selection | Classic | *Missing → Present* | A Recently Added row in the sidebar shows the photos the latest scan found new. That covers files copied in from Finder, brought in by a watched-folder import, or there when the folder was first opened. It is kept until a later scan adds more. |
| Folders panel and volume browser (online/offline, free space) | Classic | *Partial → Present* | The folder sidebar has favourites and shows disconnected volumes greyed as "not connected". It also has free-space meters for each volume that holds a favourite or the open folder, with a low-space warning, and Add Parent Folder… on a favourite's context menu. |
| Synchronize Folder | Classic | *Partial → Present* | File › Refresh Folder (⌘R) rescans the open folder for photos added, removed, renamed (matched by hash) or with changed sidecars. Settings › Folders can also watch the open folder through FSEvents, so it refreshes on its own. |
| Rename photos in the Library (templates, batch) | Both | *Partial → Present* | File › Rename… (F2) renames one photo. File › Rename with Template… batch-renames the selection using the export naming tokens plus custom text. Swaps and name chains are ordered safely, and renames are undoable. |
| Local-mode duplicate and folder Refresh | Cloud | *Partial → Present* | File › Duplicate (also on the grid's context menu) makes a real copy in the folder, carrying its metadata and edit. File › Refresh Folder (⌘R) and optional folder watching rescan the folder. |
| Cloud Duplicate photo (true copy) | Cloud | *Partial → Present* | File › Duplicate and the grid's context menu Duplicate make a numbered in-place copy with its rating, keywords, edit stack, snapshots, sidecar and thumbnail. Copy to Folder… still works too. |
| Catalog database model | Classic | Present | Each folder has a `_latent/` container holding catalog.sqlite as a cache, xmp/ sidecars as the source of truth, and thumbnails/. |
| Include Photos From Subfolders toggle | Classic | Present | Subfolders can be included or kept separate. The choice is remembered per catalog, and Settings has a default. |
| Move photos between folders from within Lightroom | Classic | Present | File › Move to Folder…, Copy to Folder…, and drag onto the sidebar. Lightroom itself cannot copy. |
| Catalog upgrade from earlier versions | Classic | Present | Schema migrations now run v1–v4 plus descriptive-metadata and virtual-copy migrations. An old `_rawhead/` container is still migrated. |
| Catalog integrity test and repair | Classic | Present | A damaged database is set aside and rebuilt from the sidecars. |
| Local browsing mode (Local tab) | Cloud | Present | Latent is entirely local browsing, with edits kept in sidecars. |
| Include subfolders (Local mode) | Cloud | Present | Uses the same subfolder include / keep-separate policy. |
| Remember last selection per source | Classic | Present | Folder history restores the selection on Back/Forward. |
| Multiple catalogs, default catalog, Open Recent, Manage Catalogs | Classic | Not applicable | One catalog per folder by design: there is no global master catalog. |
| Rename / copy / move a catalog | Classic | Not applicable | The folder is the catalog; moving the folder moves it. |
| Export as Catalog | Classic | Not applicable | Copy to Folder… carries sidecars and thumbnails. There is no catalog object to export. |
| Scheduled backup, Backups tab, restore | Classic | Not applicable | Sidecars are the source of truth, so backing up the photo folder backs up everything. |
| Optimize Catalog | Classic | Not applicable | Each folder has a small SQLite database, rebuilt from sidecars when damaged. |
| Import From Another Catalog (merge) | Classic | Not applicable | There is no central catalog to merge into. |
| Catalog panel sources (All Photographs, Quick Collection, All Synced) | Classic | Not applicable | No master catalog and no sync. Per-folder collections and a target collection now exist, but there is no all-photos source across folders. |
| Cloud Local tab Copy to Cloud / Archive Photos Locally | Cloud | Not applicable | No cloud. |
| Cloud Deleted album with restore window | Cloud | Not applicable | No cloud, and delete was skipped by choice; the macOS Trash would be the equivalent. |
| Cloud cache and originals storage preferences, storage quota | Cloud | Not applicable | No cloud. |
| Cloud All Photos smart views | Cloud | Not applicable | No master catalog. Per-folder smart collections exist. |
| Import Sequence Numbers | Classic | Not applicable | No import step. |

## Import & file handling

| Lightroom feature | Product | Latent status | Notes |
|---|---|---|---|
| Auto Import from a watched folder | Classic | *Missing → Partial* | Settings › Folders › Auto Import watches a chosen folder (for example a tethering or card-reader drop folder). It waits for files to settle, then moves or copies new photos (raw and supported non-raw files directly in the folder, not its subfolders) into a destination folder, and can apply one develop preset. There is no file-naming template, no named subfolder in the destination, no metadata preset and no keywords on import, and an import can't be undone. Separately, the open folder can be watched for changes and File › Refresh Folder (⌘R) rescans it. |
| Non-raw still formats (JPEG, TIFF, PNG, HEIC, PSD/PSB, AVIF, JPEG XL, WebP) | Both | *Missing → Partial* | JPEG, HEIC/HEIF, TIFF, PNG, WebP and AVIF (where macOS can read them) are indexed, shown and editable, with edits kept in a sidecar. PSD/PSB, JPEG XL, layers and pages after the first in a multi-page TIFF aren't read, and HDR gain maps and floating-point TIFFs open as SDR. |
| Raw+JPEG pair handling | Classic | *Missing → Partial* | A JPEG or HEIF with the same name as a raw in the same folder is treated as its companion. The grid shows the raw alone, the Library panel shows "+ name.JPG" under it, and the companion goes with the raw on Move/Copy to Folder and on a single-photo Rename. Settings › Library can show the JPEGs as separate photos instead. Batch rename with a template and Duplicate don't take the companion along. After a template rename the JPEG keeps its old name, the pair breaks and the JPEG shows up as a separate photo. |
| Camera and lens support cadence | Both | Partial | No change. LibRaw 0.22.2 is pinned at build time. Only Bayer sensors render; X-Trans, Foveon, monochrome and four-colour sensors are read for metadata only. Colour is checked against a reference on one camera (Nikon D750). Imported DCP camera profiles can now supply camera-matching looks. |
| Filename Template Editor reused for rename, import, external copies | Classic | Partial | Library › Rename with Template… opens a template editor with tokens, custom text, a start number and a preview of every new name. It uses the same template language as export naming. Edit in External Editor copies still get a fixed name (source name plus a number), and Latent has no import step. |
| Edit in Photoshop handoff options (format, space, depth, SDR/HDR) | Both | Partial | No change. Edit in External Editor (⌘E) always writes a 16-bit Display P3 TIFF and opens it in the chosen app. It is one-way and SDR only, and there are no format, colour space or bit-depth choices. |
| Apple ProRAW and linear-raw handling | Both | Present | Linear-raw DNGs, such as merge results, still render through the linear source path. AI denoise is hidden for them. |
| External editors beyond Photoshop | Both | Present | Settings › External Editor still lets you pick any application, or the default app for TIFFs. |
| Import window, methods (Copy, Copy as DNG, Move, Add) and progress | Classic | Not applicable | No import step: folders are opened in place. Auto Import's move or copy from a watched folder is the closest equivalent. |
| Import preview filtering and sorting | Classic | Not applicable | No import step. |
| Destination panel: subfolders, organise by date | Classic | Not applicable | No import step. Move to Folder… and Copy to Folder… do this after the fact, and Auto Import has a single destination folder. |
| Build Previews on import | Classic | Not applicable | Thumbnails come from embedded previews when the folder opens. |
| Don't Import Suspected Duplicates (incl. 14.4 time-and-size match) | Classic | Not applicable | No import step. |
| Make a Second Copy To | Classic | Not applicable | No import step. |
| Rename files on import | Classic | Not applicable | No import step. Rename with Template… renames files afterwards. |
| Apply Develop preset, metadata preset and keywords during import | Both | Not applicable | No import step. Apply Preset works on a selection afterwards, and Auto Import can apply a develop preset to the files it brings in. |
| Import presets and compact import window | Classic | Not applicable | No import step. |
| Memory-card auto-launch and Eject After Import | Classic | Not applicable | Card import was dropped and isn't planned. |
| Import and File Handling preferences (DNG creation, raw+JPEG, keyword separators) | Classic | Not applicable | No import step. How RAW+JPEG pairs are shown is set in Settings › Library. |
| Migration from Elements, iPhoto/Aperture, Apple Photos, Classic catalog | Both | Not applicable | No catalog to migrate into. Only standard XMP fields (including keyword hierarchies from sidecars) are read. |
| Network volumes as import source | Classic | Not applicable | Network folders open directly (rollback journal mode). |
| Assisted Culling during import | Classic | Not applicable | No import step. For culling itself, see the Viewing section. |
| Cloud Add Photos review, mobile Auto Add and multi-select import | Cloud | Not applicable | No cloud and no mobile app. |
| .acr sidecar files for pixel-based AI edits | Both | Not applicable | Model masks and Remove fills are stored as parameters and regenerated, never as pixels. |
| Adobe DNG Converter | Both | Not applicable | Adobe tool; LibRaw updates fill the same role. |
| Camera Raw parity gaps and higher-quality import previews | Both | Not applicable | Adobe-internal. |

## Metadata, keywords & search

| Lightroom feature | Product | Latent status | Notes |
|---|---|---|---|
| Keyword synonyms and per-keyword export options | Classic | Missing | No synonyms and no per-keyword Include on Export / Export Containing Keywords settings; export always writes every level of every keyword as a flat IPTC keyword (Limitations: keywords have no synonyms). |
| Keyword Suggestions and Keyword Sets | Classic | Missing | The keywording field autocompletes from keywords already in the folder, but there are no suggested keywords from nearby photos and no Keyword Sets palettes. |
| Import and export keyword lists | Classic | Missing | No Import Keywords or Export Keywords commands; the Limitations page says so. |
| Metadata panel views (EXIF, IPTC, Location…) | Classic | Missing | The Library panel has two fixed sections, a Title & Copyright section and an EXIF Metadata section (camera, lens, exposure, capture time, size, file); there is no choice of views and no Location view. |
| Customizable Default Metadata panel, Edit-only mode, Target vs Selected | Classic | Missing | The fields can't be chosen or hidden and there is no edit-only mode. Typing in a field always sets it on every selected photo; there is no switch to show or edit only the target photo. |
| Alt Text and Extended Description | Both | Missing | Only title, caption, creator and copyright are editable; there are no Alt Text or Extended Description fields. |
| Metadata presets | Classic | Missing | No metadata presets; the Limitations page says so. |
| Edit Capture Time (incl. milliseconds) | Both | Missing | Capture time is read-only; the Limitations page says so. |
| Metadata Status field and filter | Classic | Missing | Sidecars are written as soon as anything changes, so there is no out-of-date or conflict status to show or filter on. |
| GPS tracklog import and Auto-Tag | Classic | Missing | No GPS handling: the catalog keeps no coordinates and there is no tracklog import. |
| GPS display, Map Location Filter, collection from pin | Classic | Missing | GPS is neither shown in the Metadata section nor filterable; it is only stripped on export when Include location is off. |
| People view and face recognition (Classic and cloud) | Both | Missing | Vision face detection is used for Touch-up, red-eye and Select People masks, but faces are never named, grouped or turned into people keywords. |
| Natural-language and AI content search (Sensei facets, Improved Search) | Cloud | Missing | Text search matches file name, title and caption only; there is no content-based or natural-language search. |
| IPTC Core and Extension editing (title, caption, copyright, creator) | Classic | *Missing → Partial* | The Title & Copyright section edits title, caption, creator and copyright (with a one-click © year notice) across the selection, written to the sidecar as dc:title/description/creator/rights and carried into exports. Other IPTC Core fields (headline, location, contact, usage terms) and all IPTC Extension fields can't be edited. |
| Copy/Paste Metadata, Sync Metadata, metadata Auto Sync | Classic | *Missing → Partial* | Rating, flag, colour label, keywords, title, caption, creator and copyright all apply to every selected photo at once, which works like Auto Sync. There is no Copy/Paste Metadata or Sync Metadata command to copy one photo's metadata to others. |
| Library Filter presets | Classic | *Missing → Partial* | File > Save Filter as Smart Collection… (also in the Collections sidebar) turns the filter bar's settings into a smart collection in that folder's catalog. There are no named filter presets that reload into the filter bar or work across folders. |
| Metadata depth: IPTC, GPS, capture time editing, XMP writing | Both | *Missing → Partial* | XMP now carries rating, colour label (xmp:Label), flag, hierarchical keywords, title, caption, creator and copyright, and exports carry the same fields. GPS can't be viewed or edited (export can only keep or strip the source's GPS), capture time can't be edited, and the other IPTC fields (headline, location, contact, usage terms) are missing. |
| Library Filter bar: Text filter | Classic | Partial | The filter bar's search box finds a case-insensitive substring in the file name, title or caption. It can't search keywords or other fields and has no rule choices (starts with, doesn't contain); smart collections offer those rules for file name only. |
| Library Filter bar: Attribute filter | Classic | Partial | The filter bar has a rating threshold (at least only), pick/unflagged/reject toggles, a colour label menu and Edited only. There is no kind filter (master, virtual copy, video) and no rating at most or equal to, though smart collections can do those ratings. |
| Library Filter bar: Metadata columns | Classic | Partial | The filter bar has Camera, Lens, Keyword and Finder tag menus. Date, ISO, aperture, focal length and file type are available only as smart collection rules, not as filter bar columns. |
| Develop-state and AI metadata filters | Both | Partial | There is an Edited only toggle (also an Edited smart collection rule); there is nothing per tool, per mask or per AI edit. |
| Filmstrip filters and sticky filter behaviour | Classic | Partial | The filmstrip follows the grid's filter and sort. Sort is remembered, but filters are not remembered per folder or source, and the filmstrip has no filter controls of its own. |
| Save/Read Metadata to File and conflict resolution | Classic | Partial | Sidecars are written as soon as anything changes and re-read when they are newer, but there are no conflict choices, and sidecars live in _latent/xmp/, not beside the raw. Lightroom's own sidecars beside raws are not read. |
| Saved Locations with privacy radius | Classic | Partial | The export Include location switch strips GPS, place names and serial numbers; there are no saved places and no privacy radius. |
| Cloud Info panel metadata | Cloud | Partial | The panel shows EXIF, and title, caption, creator and copyright are now shown and editable; GPS and location are not. |
| Find photos from Keyword List and Metadata panel arrows | Classic | Partial | Clicking a keyword in the Keyword List, or a keyword chip, shows every photo with it or a keyword inside it. The Metadata section has no arrows to filter by camera, lens or date; the filter bar menus do that instead. |
| Hierarchical keyword list | Classic | *Missing → Present* | The Library panel has a Keyword List showing every keyword in the folder as an expandable hierarchy with photo counts, a Find keyword field and checkboxes to put a keyword on or off the selection. Keywords typed as "Places > France > Paris" are hierarchical and are written to XMP as lr:hierarchicalSubject. It shows only keywords some photo carries; empty keywords can't be kept. |
| Keyword maintenance (rename, delete everywhere, purge unused) | Classic | *Missing → Present* | Right-click a keyword in the Keyword List for Rename… (typing a path moves it in the hierarchy, children go with it) and Delete Keyword, which takes it and everything inside it off every photo in the catalog, as one undo step. Purge Unused isn't needed: the list holds only keywords some photo carries. |
| Keywording panel (entry, autocomplete, tag views) | Classic | *Partial → Present* | The Selected section shows the selection's keywords as chips (drawn faintly when only some photos have them), and an Add keywords field adds them to every selected photo, with hierarchy ("A > B") and autocomplete from the folder's keywords. It has no Will Export tag view; suggestions and keyword sets are covered by their own row. |
| Flags and colour labels stored in XMP | Classic | *Partial → Present* | Colour labels (Photo > Label menu, keys, grid dots, filter) are now written as xmp:Label using the five standard names, and the flag is written as latent:Flag. There are no label sets. |
| Automatically Write Changes Into XMP | Classic | Present | Always on: every change to rating, flag, label, keywords or descriptive fields writes the sidecar. |
| Reverse geocoding (Address Lookup) | Classic | Not applicable | Needs an online service; Latent has no network access. |
| Map module on Google Maps | Classic | Not applicable | Needs online map tiles; Latent has no network access. |
| Keyword sync with the Lightroom ecosystem | Both | Not applicable | No cloud or accounts. |
| Mobile Info panel, Location tab, map pin editing | Cloud | Not applicable | No mobile app. |
| Likes and Comments filters | Both | Not applicable | No shared albums, since there is no cloud. |

## Organisation: collections, filters, stacks, versions

| Lightroom feature | Product | Latent status | Notes |
|---|---|---|---|
| Collection colour labels, panel search, output collections | Classic | Missing | Collections now exist, but they have no colour labels, the Collections panel has no search field, and Print, Contact Sheet and Slideshow make no output collections. |
| Create collections or sets from folders | Classic | Missing | The folder sidebar has no command to make a collection or set from a folder. Collections are made empty, from the selection, or from the filter bar. Because each folder is its own catalog, a collection cannot hold photos from another folder. |
| Painter tool (spray-can) | Classic | Missing | There is no painter tool. Ratings, flags, labels, keywords and collection membership apply to the selection through keys, menus, the context menu or drag. |
| Manual stacks | Both | Missing | There is no stacking or grouping in the grid. RAW+JPEG pairs and virtual copies are the only linked records. |
| Auto-Stack By Capture Time | Classic | Missing | Not available, because there are no stacks. |
| Auto Stack by visual similarity | Both | Missing | Not available, because there are no stacks. |
| Auto Advance after rating or flagging | Both | Missing | Rating, flag and label keys change the selection but do not move to the next photo. There is no Auto Advance option and no Shift-modifier variant. |
| Built-in Duplicate Detection (Duplicates view) | Classic | Missing | There is no Duplicates view. The per-file xxHash64 is used for rename reconciliation and Photo Merge provenance, not to find duplicates. Library > Duplicate makes file copies; it does not detect them. |
| Smart collections, criteria catalogue, Smart Albums | Both | *Missing → Partial* | New Smart Collection… and Save Filter as Smart Collection… build saved live rules with Match all/any over 14 fields: rating, flag, colour label, edited, keyword, camera, lens, file name, file type, Finder tag, capture date, ISO, focal length and aperture. The editor shows a live match count, and smart collections can be edited later and placed in sets. The criteria catalogue is a small part of Lightroom's: there are no develop-setting, title/caption/creator/copyright or other IPTC text, collection, size/dimension or any-searchable-text criteria, and no nested rule groups. Save Filter as Smart Collection leaves out the filter bar's colour-label choice. Smart Albums do not apply (no cloud). |
| Colour labels and label sets (Classic and cloud custom labels) | Both | *Missing → Partial* | The five colour labels work from keys 6–9 (pressing the same key again removes the label), from Photo > Label, the grid context menu and the panel picker. They show as a dot in grid cells, can be filtered from the filter bar's label menu, are written to xmp:Label, and can be undone. Custom labels written by other apps are kept and shown as a hollow ring. There are no label sets, and labels cannot be renamed. |
| Flags (Pick/Reject/Unflagged) and Refine Photos | Both | Partial | Pick, Reject and Unflag work from the P, X and U keys and the menu, with grid badges, a flag filter, a smart-collection criterion and undo. There is still no Refine Photos command and no auto-advance with Shift. |
| Grid sort orders | Classic | Partial | Sort is still limited to capture time, file name, rating, modified and Custom, ascending or descending. There is no sort by label, pick, edit count, file type, aspect ratio or Lightroom's other orders. |
| Selection commands (Invert, Select Flagged, Deselect Unflagged) | Both | Partial | Select All (⌘A), click, Shift-click and ⌘-click work. There is still no Invert Selection, Select by Flag, Rating or Label, or Deselect Unflagged. |
| Regular collections, collection sets, cloud albums and folders | Both | *Missing → Present* | The sidebar has a Collections section under the folders with regular collections and collection sets that nest, rename, move and delete, with drag-from-grid and an undo step for each change. Collections belong to the open folder's catalog only, and cloud albums do not apply because there is no cloud. |
| Quick Collection and target collection / target album | Both | *Missing → Present* | B adds the selection to the target collection, or removes it when it is already all there. With no target it uses a Quick Collection, creating one if needed. Any regular collection can be made the target from its context menu (Set as Target Collection), and it is then marked with a + in the sidebar. |
| Star ratings (0–5) | Both | Present | Ratings work from keys 0–5, grid stars, the panel and the context menu. They are written to xmp:Rating, can be undone, and are available as a smart-collection criterion. |
| Custom (User Order) sort by dragging | Both | Present | Custom sort by dragging in the grid is still there. The order is saved in _latent/custom-order.json and can be undone. |
| Cloud Shared panel, shared albums, Shared with You | Cloud | Not applicable | Not applicable: Latent has no cloud and no accounts, by design. |
| Likes and Comments criteria | Both | Not applicable | Not applicable: there are no shared albums, so there are no likes or comments to filter on. |
| Enhance Create Stack, album placement on cloud transfer | Cloud | Not applicable | Not applicable: these are cloud-transfer behaviours, and Latent has no cloud. (Latent also has no stacks.) |

## Viewing, culling & comparison

| Lightroom feature | Product | Latent status | Notes |
|---|---|---|---|
| Assisted Culling (select/reject criteria, Info panel, Faces, batch actions, Best Photos) | Both | Missing | Still no sharpness, eye, face or exposure scoring and no automatic pick/reject suggestions. Culling is done by hand with flags, stars and colour labels. |
| Lights Out / Lights Dim | Classic | Missing | No dimming of the interface around the photo. View › Full-Screen Image (F) is the nearest thing. |
| Loupe Overlay (grid, guides, layout image) | Classic | Missing | No overlay in Loupe. The crop tool now has a choice of guides (Thirds, Grid, Golden Ratio, Golden Spiral, Diagonal, Triangle), but they show only while cropping. There is no layout-image overlay. |
| Transparency checkerboard | Both | *Not applicable → Missing* | No longer Not applicable: the new Transform panel lets you turn Constrain Crop off, which leaves empty areas at the edges. Those areas show as black, with no transparency checkerboard and no transparent export. |
| Grid view cell options (Library View Options) | Classic | Partial | Each cell shows a fixed set of marks: name, edited badge, flag, stars, Finder tag dots, and now a colour label dot and a virtual-copy badge. There is a size slider. The cell contents can't be configured, and there are no header labels and no label tint. |
| Loupe view Info Overlay and Navigator | Classic | Partial | A caption under the image in Loupe and Compare shows the name, exposure, flag and stars. Lightroom's two configurable info overlays and the Navigator panel are missing. |
| Filmstrip with Source Indicator | Classic | Partial | Loupe and Develop have a filmstrip that follows the grid's filter and sort. It has no source indicator or source menu; you switch sources only with Back and Forward. |
| Secondary display window (Grid, Loupe, Compare, Survey, Slideshow) | Both | Partial | View › Show Loupe on Second Display shows the current image (or Survey's focused pane) at fit zoom, view-only. The second display has no Grid, Compare, Survey or Slideshow modes. |
| Full-screen preview and screen modes | Both | Partial | F shows the image full screen, with fly-outs at the edges, and macOS's own Enter Full Screen also works. There is no Shift+F screen-mode cycle and no Tab to hide panels. |
| Navigator zoom levels and scrubby zoom | Both | Partial | View has Zoom to Fit, Actual Size, Zoom In and Out in ×2 steps, and Z to switch Fit and 100%; pinch zoom also works. There is no Navigator panel, no menu of 6–1600% zoom levels and no scrubby zoom. |
| Before/After views (split, side by side) | Both | Partial | Show Before/Show After (\) switches the whole view between the two. There are no split or side-by-side Before/After layouts. |
| Reference View | Both | Partial | Compare can pin a Select image beside a Candidate, but both panes are view-only. You can't edit a photo next to a reference image. |
| Cloud grid views, filmstrip badges, Square Grid filenames | Cloud | Partial | There is one grid style, with filename, badges and now colour label and virtual-copy marks. There is no borderless Photo Grid style. |
| Compare view (select vs candidate) | Both | Present | Compare (C) puts the Select and Candidate side by side, with Sync zoom and pan, Swap Select and Candidate, and Make Select. |
| Survey view (N) | Classic | Present | Survey (N) shows 2 to 4 selected images side by side and has Remove from Survey (Lightroom allows more images). |
| HDR display in Library (Loupe, Compare, full screen) | Classic | Present | The HDR display switch applies in Loupe, Develop and the second display. JPEGs and other rendered images, and soft proofing, are now held to SDR white. |
| AI-update badge and Show in Library | Classic | Not applicable | AI masks, AI denoise and Lens Blur depth maps are regenerated in the editor when needed and again at export, so nothing goes stale and needs a badge. |
| Mobile Gallery grid (justified layout, pinch resize) | Cloud | Not applicable | There is no mobile app, by design. |

## Develop: tone & colour

| Lightroom feature | Product | Latent status | Notes |
|---|---|---|---|
| Alt/Option hue-isolation preview | Classic | Missing | No Option-drag preview that isolates a hue on the HSL or Colour Mixer sliders. Option-drag is only used for the Sharpening Masking preview. |
| Calibration: Process version menu | Classic | Missing | The edit records process version 1.0, but there is no menu or control to choose a process version. |
| Visualize HDR Ranges overlay | Both | Missing | No overlay that marks the HDR ranges on the image. |
| SDR Rendition Settings | Both | Missing | No separate controls for the SDR rendition; the SDR output is still just the tone curve without headroom. |
| HDR colour readouts and HDR clipping colours | Both | Missing | The new pixel readout clamps RGB to SDR (0–100%), and the clipping overlay has no HDR clipping colours. The histogram shows only the share of pixels above SDR white. |
| Match Total Exposures | Classic | Missing | There is no command that matches exposure across selected photos. |
| Color Grading: Global wheel, Blending slider, wheel modifiers | Both | *Missing → Partial* | The Colour Grading panel has a Global wheel and a Blending slider, and a single-wheel view with typed Hue and Saturation. The wheels have no Lightroom-style modifier keys (Shift to lock hue, Command for fine moves); double-click is the only shortcut and removes the tint. |
| Auto tone (Sensei Auto) | Both | Partial | Auto Adjust (Command-U, Develop menu) still sets only exposure, contrast and white balance. It leaves Highlights, Shadows, Whites, Blacks, Vibrance and Saturation alone. |
| HDR editing mode (HDR button) | Both | Partial | The HDR display switch shows headroom up to the per-photo HDR Limit (0.5–3 stops), and gain-map export follows it. There is still no separate HDR editing pipeline with HDR-specific tools. |
| Extended HDR histogram | Both | Partial | Unchanged: there is a readout of pixels above SDR white, but the histogram itself is SDR only. |
| Single-channel grayscale image support | Classic | *Not applicable → Partial* | Latent now opens JPEG, HEIC, TIFF and PNG, so grayscale files open and can be edited. They are converted to RGB on decode, so editing and export are not single-channel. |
| White Balance presets (Daylight, Cloudy, Tungsten…) | Both | *Missing → Present* | A White Balance menu in the Basic panel offers As Shot, Auto, Daylight, Cloudy, Shade, Tungsten, Fluorescent and Flash, showing Custom once the sliders move. |
| White Balance Selector (eyedropper) | Both | *Missing → Present* | White Balance Selector button next to the preset menu (shortcut W): click something neutral in the photo to set Temperature and Tint. |
| Interactive histogram (drag to adjust) | Both | *Missing → Present* | Drag sideways across the histogram to adjust Blacks, Shadows, Exposure, Highlights or Whites, depending on where the drag starts. |
| RGB and Lab colour readouts under the pointer | Both | *Missing → Present* | A readout under the histogram shows the colour under the pointer as RGB percentages and CIE Lab (D50). |
| Tone Curve: parametric curve with region sliders | Both | *Missing → Present* | The Tone Curve panel switches between the point curve and a region curve with Highlights, Lights, Darks and Shadows sliders and three draggable split points. |
| Tone Curve: Refine Saturation slider | Both | *Missing → Present* | A Refine Saturation slider in the Tone Curve panel sets how much colour the curve's contrast adds. |
| Tone Curve Targeted Adjustment Tool | Classic | *Missing → Present* | The targeted adjustment button in the Tone Curve panel lets you drag up or down on the photo to move that tone, on either the point curve or the region curve. |
| Color Mixer Targeted Adjustment Tool | Both | *Missing → Present* | A Targeted adjustment picker in the HSL panel (Hue, Saturation or Luminance) lets you drag up or down on a colour in the photo to move the matching bands. |
| Point Color Variance slider | Both | *Missing → Present* | Each Point Colour swatch has a Variance slider (alongside Hue, Saturation, Luminance and Range). |
| B&W Mix panel | Both | *Missing → Present* | Choosing the Black & White treatment shows a grey mix slider for each of the eight colours, with Auto and Reset buttons. |
| Calibration: Shadows tint and primary hue/saturation | Both | *Missing → Present* | A Calibration panel has a Shadows Tint slider and Hue and Saturation sliders for the red, green and blue primaries, with a Reset button. |
| Treatment: Color / Black & White | Both | *Partial → Present* | A Treatment switch (Color / Black & White) heads the Black & White section. It keeps the grey mix while switching back to colour. |
| Temp slider (typed Kelvin) | Both | *Partial → Present* | The Temperature slider has a Kelvin field beside it, so you can type a value; the slider itself still moves in mired steps. |
| Clipping indicators and clipping previews | Both | *Partial → Present* | Shadow and highlight clipping toggles beside the readout, and Show/Hide Clipping (J), mark crushed shadows in blue and clipped highlights in red on the image. The per-channel clipping percentages remain. |
| Tone Curve: point curve with presets | Both | *Partial → Present* | A Point Curve preset menu offers Linear, Medium Contrast and Strong Contrast (Custom once edited). |
| Point Color | Both | *Partial → Present* | A Point Colour panel lets you pick colours from the photo as swatches, each with Hue, Saturation and Luminance shift plus Range and Variance. |
| Color Grading three-way wheels | Both | *Partial → Present* | The Colour Grading panel has a 3-Way view with Shadows, Midtones and Highlights wheels, each with a Luminance slider, and single views for Shadows, Midtones, Highlights and Global. |
| HDR Limit slider | Both | *Partial → Present* | An HDR Limit slider with a typed field (0.5–3 stops, default 2) sits under the HDR switch. It is part of the edit and applies to display and gain-map export. |
| Saturation slider | Both | *Partial → Present* | The Presence group has a global Saturation slider (−1…1) under Vibrance that affects every colour equally. |
| Tint slider | Both | Present | Tint slider in the Basic panel, −100…+100. |
| Exposure slider | Both | Present | −5…+5 EV, values can be typed. |
| Contrast slider | Both | Present | Sigmoid contrast, plus a Mid Grey control that Lightroom does not have. |
| Highlights, Shadows, Whites, Blacks | Both | Present | Hue-preserving per-pixel tone ranges without halos. |
| Texture | Both | Present | Fine local contrast at 1–4 px. |
| Clarity | Both | Present | Midtone-weighted local contrast. |
| Dehaze | Both | Present | Dark-channel prior; negative values add haze. |
| Vibrance | Both | Present | Skin-sparing vibrance in the Presence group. |
| Tone Curve: per-channel R/G/B curves | Both | Present | Master curve plus separate red, green and blue curves. |
| Color Mixer HSL sliders | Both | Present | Eight colour bands, each with Hue, Saturation and Luminance, now with a targeted adjustment tool. |
| Color Grading: Balance slider | Both | Present | Balance slider in the Colour Grading panel. |
| HDR rendering in Library and secondary window | Classic | Present | The second display is rendered for its own headroom. |
| HDR display warning icon | Cloud | Present | A headroom readout ("this screen: up to N× above white"); the HDR switch is only active when the screen has headroom. |
| Legacy tone controls (Recovery, Fill Light, Brightness) | Classic | Not applicable | There is no process-version history to keep compatible with. |
| HDR default-enable preference and HDR settings in Copy/Sync | Both | Not applicable | HDR display is a view setting rather than part of the edit, though HDR Limit is part of the edit and is copied with Tone. |

## Develop: detail, optics & geometry

| Lightroom feature | Product | Latent status | Notes |
|---|---|---|---|
| Raw Details (AI demosaic) | Both | Missing | The Detail panel's Demosaic menu offers only the classical RCD and Bilinear methods; there is no machine-learning demosaic. |
| Super Resolution | Both | Missing | No upscaling or Enhance command anywhere in Sources. |
| Built-in lens profile support (embedded correction data) | Both | Missing | Lens correction still comes only from the bundled Lensfun subset (automatic or picked by hand); embedded DNG opcodes and ARW/RAF maker-note correction data are not read. |
| Flat-Field Correction | Classic | Missing | None. |
| Copy/Sync Upright options | Classic | *Not applicable → Partial* | Upright now exists, so this row applies again. Upright travels with the 'Crop, Straighten & Perspective' group in Copy/Paste Settings as its stored matrix (like copying Upright Transforms), but there are no separate Upright Mode / Upright Transforms / Transform Adjustments choices and no option to re-analyse each target photo. |
| Sharpening: Detail slider | Both | *Missing → Present* | Develop › Detail › Sharpening now has a Detail slider (0–100) beside Amount, Radius, Threshold and Masking; lower values hold back edge halos, 100 is plain unsharp masking. |
| Upright Auto, Level, Vertical, Full (with Update and preserve-crop) | Both | *Missing → Present* | Crop & Straighten › Transform has an Upright segmented picker (Off, Auto, Guided, Level, Vertical, Full) driven by a line detector and solver, an Update button to re-read the lines, and Constrain Crop refits the crop; also in the Develop › Transform menu. The result is stored as a matrix; photos without straight lines may get no correction. |
| Guided Upright | Both | *Missing → Present* | Upright › Guided with a Draw Guides tool: drag two to four guides on the image, Option-click to remove one, Clear to remove all. |
| Auto straighten (Auto button) | Both | *Missing → Present* | An Auto button under the Straighten slider (and Develop › Transform › Auto Straighten) levels the picture from its straight lines. |
| Crop Mask opacity | Classic | *Missing → Present* | A Surround slider (0–100%, double-click to reset) in the Crop & Straighten panel sets how dark the area outside the crop is drawn; it is an app preference, not per photo. |
| Grain | Both | *Missing → Present* | Develop › Effects › Grain with Amount, Size and Roughness; the pattern is fixed per photo so export matches the screen. Masks have no grain of their own. |
| Sharpening: Masking with Alt preview | Both | *Partial → Present* | Detail › Sharpening › Masking slider restricts sharpening to edges; holding Option while dragging shows the sharpening mask in black and white. |
| Noise Reduction: Luminance, Detail, Contrast | Both | *Partial → Present* | Detail › Noise Reduction has Luminance plus its own Detail and Contrast sliders. |
| Noise Reduction: Color, Detail, Smoothness | Both | *Partial → Present* | Detail › Noise Reduction has Colour plus its own Detail and Smoothness sliders. |
| Lens profile corrections with manual Make/Model override | Both | *Partial → Present* | Lens Corrections has a profile menu (Automatic, lenses that fit this camera grouped by maker, other mounts) with Distortion, Chromatic aberration and Vignetting switches, and Use for All Photos From This Lens remembers the choice in the catalog's lens_overrides table. Limited to the bundled Lensfun subset; no profile Amount sliders. |
| Remove Chromatic Aberration | Both | *Partial → Present* | Lens Corrections › Remove chromatic aberration (automatic) measures the fringes on the photo and corrects them without a profile, alongside the profile-based switch. |
| Defringe with hue ranges and eyedropper | Both | *Partial → Present* | Lens Corrections › Defringe has Purple and Green amounts, each with a from/to hue range drawn over a hue strip, and a Pick Fringe Colour eyedropper that moves the range to a clicked fringe. |
| Manual lens vignetting (Amount, Midpoint) | Classic | *Partial → Present* | Lens Corrections › Manual has Vignetting (amount) and Midpoint sliders. |
| Manual Transform sliders (Vertical, Horizontal, Rotate, Aspect, Scale, X/Y Offset) | Both | *Partial → Present* | The Transform section (folded under Crop & Straighten) has Vertical, Horizontal, Rotate, Aspect, Scale, X Offset and Y Offset sliders, plus flip buttons and Reset. |
| Constrain Crop | Both | *Partial → Present* | A Constrain Crop checkbox in Transform refits the crop inside the picture whenever the transform or straighten changes; a crop dragged by hand afterwards can still reach an empty edge. |
| Aspect ratio presets, custom ratios and lock | Both | *Partial → Present* | The Aspect menu has Free, Original, 1:1, 3:2, 4:3, 5:4, 5:7, 16:9 and their portrait forms, plus Custom… which takes any width and height; choosing a ratio locks the crop to it. |
| Angle slider and Straighten tool | Both | *Partial → Present* | Straighten slider (−45…45°) plus a ruler button (or ⌘-drag in the crop tool) to draw a line along something that should be level or upright. |
| Crop guide overlays | Both | *Partial → Present* | Overlay menu with Thirds, Grid, Golden Ratio, Golden Spiral, Diagonal, Triangle and None; O cycles and ⇧O rotates the spiral or triangle (also in Develop › Transform). No Aspect Ratios overlay. |
| Post-Crop Vignetting | Both | *Partial → Present* | Develop › Effects › Post-Crop Vignetting with Style (Highlight Priority, Colour Priority), Amount, Midpoint, Roundness, Feather and Highlights, applied to the cropped frame. No Paint Overlay style. |
| Reset to Camera Orientation | Classic | *Partial → Present* | Photo › Reset to Camera Orientation removes the selection's own quarter turns in one undoable step; flips made in Transform are left alone. |
| Sharpening: Amount and Radius | Both | Present | Unsharp mask Amount 0–2 and Radius 0.5–3 px in Develop › Detail. |
| Denoise (AI noise reduction) | Both | Present | A separate AI denoise section in Develop runs NAFNet on the GPU with a strength blend; one model only, not for linear DNGs, and thumbnails leave it out. |
| Manual distortion slider | Both | Present | Lens Corrections › Manual › Distortion slider. |
| Crop Overlay tool (handles, drag to move) | Both | Present | R or the Crop… button shows the crop rectangle with handles on the image; drag to move or resize. |
| Zoom and pan while cropping | Both | Present | The crop overlay passes scroll and pinch through to the image view, so zooming and panning still work with the tool on. |
| Redesigned mobile Crop & Geometry | Cloud | Not applicable | No mobile app by design. |

## Develop: local adjustments & masking

| Lightroom feature | Product | Latent status | Notes |
|---|---|---|---|
| Select People body-part options and separate masks per part | Both | Missing | Select by Class ▸ People selects everyone as one mask; there are no body-part options. Touch-up's skin, teeth and eye regions work only for its own sliders. |
| Landscape mask Snow component | Both | Missing | Not among the nine classes in Select by Class (sky, people, vegetation, water, buildings, ground, mountains, animals, vehicles). |
| Depth Range mask | Both | Missing | No depth range mask or component. Lens Blur now makes a depth map, but masks cannot use it. |
| Tone Curve inside masks | Both | Missing | Masks have no curve of their own. |
| Point Color inside masks | Both | Missing | Point Color exists only as a global panel. Masks do have a Hue rotation slider and a Colour Range selection. |
| Local Grain | Both | Missing | Grain is now available globally in Effects, but not inside masks. |
| Masks panel housekeeping (Delete Empty Masks, Auto Hide) | Both | *Missing → Partial* | Masks ▸ Delete Empty Masks is in the panel. There is no Auto Hide option for the overlay or the mask pins. |
| Select Background | Both | Partial | There is no one-click Background option. You make a Subject mask and tick Invert, or use Masks ▸ Duplicate and Invert on it. |
| Select Objects brush mode | Both | Partial | Click to Select (SAM 2.1) works by clicks and option-clicks, and there is now a box mode, but you cannot paint over an object to select it. |
| Select People person detection | Both | Partial | Select by Class ▸ People selects all people together. There is no list of detected people to pick from. |
| Select Landscape components | Both | Partial | Select by Class offers sky, vegetation, water, buildings, ground and mountains, and several classes can now be added as components of one mask. There is no snow, and ground is not split into natural and artificial. |
| Brush mask (Auto Mask, Density, pressure, A/B) | Both | Partial | Paint and Erase with Size, Feather, Flow and now Density. There is no Auto Mask, no pen pressure and no A/B brush presets. |
| Radial Gradient mask | Both | Partial | Drag from the centre to draw a circle; Width and Height sliders make it an ellipse, and Feather and Invert are there. Place or move drags a placed ellipse to a new position, and its outline is drawn on the image. It cannot be rotated, and there are no on-image handles to reshape or resize it (only the sliders or redrawing). |
| Local adjustment sliders (Light, Color, Effects, Detail) and slider groups | Both | Partial | Sliders are grouped as Light (Exposure, Contrast, Highlights, Shadows, Whites, Blacks), Colour (Temperature, Tint, Hue, Saturation), Effects (Texture, Clarity, Dehaze) and Detail (Sharpness, Noise, Defringe), plus Amount. Moiré and the Color tint swatch (colourising inside a mask) are missing. |
| Masks in presets and Copy/Sync (Merge or Replace) | Both | Partial | The Local Adjustments group travels in copy, paste and presets, with components, sliders and model masks. It only replaces the target's masks; there is no merge option. |
| Masking workflow shortcuts | Both | Partial | Develop ▸ Masks has items for new masks and Show Mask Overlay, but none of them has a key. [ and ] change the brush size. There are no keys for new masks, cycling masks or the overlay. |
| Check All / Check None for People and Landscape | Classic | Partial | Each Select by Class mask has one class. To combine several classes you add them as components, but there is no checklist and no Check All or Check None. |
| Select Objects rectangle mode | Both | *Missing → Present* | Add ▸ Select Objects (Box) in the Local Adjustments panel: drag a rectangle and Segment Anything 2.1 selects the object; clicks can be added to the same selection afterwards, and Draw box redraws it. |
| Add / Subtract mask components | Both | *Missing → Present* | Each mask has a Components list with + and − menus that add or subtract any shape, colour range, luminance range or model mask, up to six components per mask, each with its own Invert. |
| Mask Amount slider | Both | *Missing → Present* | An Amount slider (0 to 1) at the top of each mask's sliders scales everything that mask applies. |
| Feather slider for AI masks | Both | *Missing → Present* | Subject, class and selection masks (and model components) have a Feather slider that softens the model's edge. It is stored with the edit and reapplied whenever the mask is regenerated. |
| Edge slider (expand/contract) | Both | *Missing → Present* | An Edge slider grows or shrinks a model mask by up to 3% of the frame's short side. |
| Local Defringe | Both | *Missing → Present* | Each mask's Detail group has a Defringe slider that removes purple and green fringes inside the mask. |
| Masking panel (unified components) | Both | *Partial → Present* | The Local Adjustments panel lists up to eight masks. Each mask combines a shape with up to six components by Add, Subtract or Intersect, and any shape, range or model mask can be a component. |
| Color Range mask | Both | *Partial → Present* | Add ▸ Colour Range arms an eyedropper. Click up to five colours on the image (shown as swatches, with Clear), and Refine sets how far the selection reaches. It can also be used as a component. Sampling is by clicks only (no drag-a-rectangle sample area). |
| Intersect Mask With | Both | *Partial → Present* | The ◎ menu under Components intersects the mask with any shape, colour range, luminance range or model mask. The older luminance and hue range tickboxes still narrow a mask. |
| Invert / Duplicate and Invert | Both | *Partial → Present* | Invert works on each component and Invert mask on the whole combination. Masks ▸ Duplicate and Invert (also on the right-click menu) copies a mask turned inside out. |
| Duplicate, Rename, Hide and Delete masks | Both | *Partial → Present* | The Masks menu and the right-click menu have Duplicate and Hide/Show; Delete is on the right-click menu and as a Delete button under the selected mask's sliders. A name field renames a mask, and each list row has an eye to hide it. |
| Mask overlay modes and colours | Both | *Partial → Present* | The Overlay menu offers Colour Overlay, Colour Overlay on B&W, Image on Black, Image on White and White on Black, with six tint colours (red, green, blue, yellow, magenta, white) and opacity 25/50/75/100%. Lightroom's Image on Alpha mode and free colour picker are not there. |
| Select Subject (AI) | Both | Present | Add ▸ Subject uses BiRefNet Lite (bundled) or Apple Vision, with a model chooser and a Model menu to remake the mask. |
| Select Sky (AI) | Both | Present | Select by Class ▸ Sky (heuristic fallback). |
| Linear Gradient mask | Both | Present | Drawn on the image with Place gradient. Dragging again redraws it; it cannot be moved as a whole. |
| Luminance Range mask | Both | Present | Low, High and Feather, as its own mask, as a component or as a range on any mask. |
| Update AI Masks / automatic recompute | Both | Present | Model masks are stored as parameters and made again for each photo on paste, preset and export. Feather and Edge are reapplied, and a Model menu remakes a mask with another model. |
| Masking performance (GPU) | Both | Present | Metal pipeline with live sliders. The Effects and Detail sliders run in a separate stage only when a mask uses them. |
| AI pixel-data storage (.lrcat-data, .acr) | Both | Not applicable | By design, masks are stored as parameters and model masks are regenerated, so there is no pixel-data sidecar. |
| Mobile Masking tool options | Cloud | Not applicable | No mobile app. |

## Develop: AI, retouching & generative

| Lightroom feature | Product | Latent status | Notes |
|---|---|---|---|
| Distraction Removal: Reflections | Both | Missing | There is no reflection-removal tool or model. Remove can paint out a small reflection by hand, but nothing separates a reflection layer from glass. |
| Pet Eye correction | Classic | Missing | Red Eye Correction only changes red pupils. An animal's green, yellow or white eyeshine is left as it is, and there is no Pet Eye mode. |
| Lens Blur (depth map, bokeh styles, focus range, refine brushes, copy/paste) | Both | *Missing → Partial* | Develop has a Lens Blur panel with Amount, three bokeh shapes (Circle, Bubble, 5-Blade), Boost highlights, a Focus Range over the depth histogram, Pick Focus, Show Depth and a depth-source menu. It travels with Copy/Paste Settings and presets as the Lens Blur group. There are no refine brushes, and no depth model is bundled: without one added from disk in Settings › AI › Models, the depth is only two planes made from the subject mask. |
| Adaptive: Blur Background presets | Both | *Missing → Partial* | There are no built-in Blur Background presets; the five built-in presets cover tone and colour only. A user can save their own preset that includes the Lens Blur group, and it makes a fresh depth map for each photo it is applied to. |
| Remove tool (unified Remove / Heal / Clone, Opacity) | Both | Partial | Spot Removal now offers Heal, Clone and Remove in one picker, with spot and brush shapes, feather and up to 32 patches. A patch has no opacity setting. |
| Remove tool overlay and pin management | Both | Partial | Patches can be dragged and selected, deleted with ⌫ or Delete Spot, resized with [ and ], and cleared with Clear all. Remove patches draw their filled outline. There are no overlay show modes (Auto, Always, Never) and no Alt-marquee delete. |
| Enhance dialog (Raw Details, Super Resolution, Denoise) | Both | Partial | AI Denoise only, as one model at one quality. There is no Raw Details (enhanced demosaic) and no Super Resolution upscale. |
| Quick Actions: Retouch (Eyes, Teeth, Skin, Hair, Clothing) | Cloud | Partial | Touch-up gives each face Skin Smoothing, Teeth Whitening and Brighten Eyes. There are no hair or clothing actions. |
| Quick Actions: Scene enhance | Cloud | Partial | Class masks (sky, people, vegetation, water, buildings and others) can be added in Masking, but there are no one-tap scene recipes. |
| Quick Actions: Subject, Background, Sky looks | Cloud | Partial | Subject and Sky masks exist, and Background is the subject inverted, but there are no ready-made looks to apply to them. |
| Content-Aware Remove | Both | *Missing → Present* | Spot Removal now has a Remove mode beside Heal and Clone: brush or click over something and it is filled with texture synthesised from around it on the GPU, with no source to place. It fills from the photo itself, not from a generative model, so it cannot invent hidden detail, and a patch covers at most 35% of the short side. |
| Detect Objects (object-aware Remove) | Both | *Missing → Present* | A Detect Objects checkbox under Spot Removal in Remove mode uses the bundled SAM 2.1 Small click-to-select model to refine each rough Remove stroke to the object's outline. A selected patch can be detected again or switched back to the brushed area with Use Brush. It looks at the unedited photo, so it can still see an object another patch has already removed. |
| Heal mode | Both | Present | Spot Removal's Heal mode copies a source and matches its tone and colour to the surroundings. |
| Clone mode | Both | Present | Spot Removal's Clone mode copies a source exactly. |
| Visualize Spots | Both | Present | Visualise Spots, with a Contrast slider, sits under Spot Removal's Sensor Dust section. |
| Distraction Removal: Dust (automatic) | Both | Present | Sensor Dust's Find Spots, dust maps per camera, and Library › Remove Dust… for many photos at once; ahead of Lightroom. |
| Red Eye Correction | Both | Present | Red Eye tool (Y) with Pupil Size and Darken. |
| Automatic red-eye detection | Cloud | Present | The Red Eye panel's Auto button finds eyes with Vision. It can miss small faces in a large group shot. |
| Blemish Removal (Quick Action) | Cloud | Present | Find Blemishes in Touch-up places a ring on each blemish, per face; rings can be kept or added. |
| Quick Actions: Auto | Cloud | Present | Auto Adjust (⌘U), from the Develop menu or the Auto button. |
| Background AI processing with photo locking | Classic | Present | Find Faces, Remove Dust, Detect Objects and Lens Blur's depth map run in the background with progress shown. Find Faces and Remove Dust each commit as one undo step. |
| Generative Remove (Firefly) and variations | Both | Not applicable | Generation happens on Adobe's servers, and Latent makes no network connections. The local Remove mode covers the non-generative case. |
| Distraction Removal: People | Both | Not applicable | This uses Firefly generation, and Latent makes no network connections. |
| AI Sharpen (Topaz) | Cloud | Not applicable | Runs in the cloud and costs credits; Latent makes no network connections. |
| Generative Upscale (Topaz) | Cloud | Not applicable | Runs in the cloud and costs credits; Latent makes no network connections. |
| Generative Expand and Flatten AI Edits | Cloud | Not applicable | Uses Firefly, so it needs the network. It is also out of scope (PhotoMerge.md §1, Fill Edges). |
| Prompt to Edit | Cloud | Not applicable | Uses a cloud model; Latent makes no network connections. |
| Edit Using Describe | Cloud | Not applicable | Uses a cloud model and is Android only. |
| Edit in Firefly, Firefly Boards, Generate Video, Animate | Both | Not applicable | These are Adobe cloud services. |
| Firefly AI Assistant | Cloud | Not applicable | An Adobe cloud service. |
| Generative credits and credit display | Both | Not applicable | Latent is free and GPLv3, with no accounts. |
| AI edit status, Update AI indicator, export warning | Both | Not applicable | Masks and depth maps are stored as parameters and made again at export, so nothing goes stale. Lens Blur records which depth source it used. |
| Download originals when using AI tools | Cloud | Not applicable | There is no cloud; the originals are already on disk. |
| Early Access toggles and Technology Previews | Both | Not applicable | This is part of Adobe's release process. |
| Open Eyes (generative blink fix) | Cloud | Not applicable | Uses cloud generation; Latent makes no network connections. |
| Quick Actions framework (mobile/web) | Cloud | Not applicable | Latent has no mobile app. The individual Quick Actions are judged in the rows above. |

## Presets, profiles, history & snapshots

| Lightroom feature | Product | Latent status | Notes |
|---|---|---|---|
| Adaptive Color and Adaptive B&W profiles | Both | Missing | No adaptive profiles. The Black & White group has fixed Monochrome and colour-filter looks, which do not adapt to each image. |
| Profile Favorites | Both | Missing | Profiles now exist, but there is no way to mark favourites; the menu is a fixed grouping. |
| Preset Amount slider | Both | Missing | Presets still apply at full strength. Only creative profiles have an Amount slider. |
| Import presets (XMP, zip bundles) | Both | Missing | No preset import command. JSON preset files can be dropped into the presets folder by hand; Lightroom XMP presets are not read (edit compatibility is a non-goal). |
| Manage Presets groups, Favorite presets | Both | Missing | Apply preset is a flat menu: built-ins, then user presets. There are no groups and no favourites. |
| ISO adaptive presets | Classic | Missing | None. |
| Raw Defaults (master, per camera, per ISO, Set Default Settings) | Both | Missing | Every raw still opens with as-shot defaults. The nearest thing is Auto Import's Develop preset, which only applies to photos Auto Import copies in. It is not a per-camera or per-ISO default. |
| Process versions and Update Process Version dialog | Classic | Missing | A process version (1.0) is recorded with each edit, but there is no choice of version and no upgrade flow. |
| Auto Sync | Classic | Missing | Paste applies once; there is no live sync across a selection. |
| Previous button (Paste Settings From Previous) | Classic | Missing | No Previous command; copy then paste. Export with Previous exists, but it is for export settings only. |
| Per-panel eye indicators and panel switches | Both | Missing | No per-panel on/off switch to bypass a module. |
| Copy settings between Before and After / Swap | Classic | Missing | Before is always the unedited image; the Presets panel has only a Before/After toggle. |
| Hover preview for presets, History and Snapshots | Classic | Missing | Presets, history steps and snapshots apply only when clicked; no hover preview. |
| Preset search field | Classic | Missing | None. |
| Profile pop-up, Profile Browser and Adobe Raw profiles | Both | *Missing → Partial* | A Profile menu at the top of the Develop panel lists Latent Standard/Neutral/Flat, Creative and Black & White looks plus imported DCPs grouped for this camera and Other Cameras. There is no Profile Browser with preview thumbnails, and no Adobe Raw profiles are bundled (an Adobe .dcp the user already has can be imported). |
| Camera Matching profiles | Both | *Missing → Partial* | Latent bundles no camera-matching profiles, so the default look still won't match the camera JPEG. Camera-matching DNG profiles (.dcp) you already have can be imported and are offered under Camera Profiles for the matching camera, with their look table and an optional tone curve. |
| Creative LUT profiles, Film-Inspired profiles and presets | Both | *Missing → Partial* | The Profile menu has built-in Creative looks (Vivid, Portrait, Landscape) with an Amount slider up to 200%, and Black & White looks (Monochrome plus yellow, red and green filters) with an Amount slider up to 100%. They are hue/saturation tables written in code, not LUTs: there is no .cube/LUT support and no film-inspired set. |
| Import profiles (DCP, LCP, XMP) and Manage Profiles | Both | *Missing → Partial* | Develop > Import Camera Profile… and Import Profile… in the Profile menu copy .dcp files into Latent's profile folder. LCP lens profiles and XMP profiles cannot be imported (lens profiles come only from the bundled Lensfun data), and there is no Manage Profiles to hide or remove imported ones. |
| Presets panel with live hover preview and name filter | Both | Partial | The Presets panel has an Apply preset menu with built-ins and user presets, Save… and Delete preset. There is no preview and no name filter. |
| Export preset / Export Group | Both | Partial | No export command. Preset JSON files in Application Support can be shared by hand. |
| Adaptive presets (AI mask-based) | Both | Partial | A saved preset can carry model masks that regenerate for each photo. There is no bundled set of adaptive presets. |
| Preset thumbnails view and batch apply from Grid | Cloud | Partial | Apply Preset works on a Library selection from the grid context menu. There is no thumbnail view of presets. |
| History panel | Classic | Partial | The History panel keeps 30 named steps per image and jumps to a step on click. It has no rename, no Clear All and no hover preview. |
| Versions (Named and Auto) | Cloud | Partial | Named versions exist as snapshots (Snapshot… in the History panel; soft-proof copies are saved as snapshots too), and virtual copies keep separate edits side by side. There are no automatic versions. |
| Reset to Original / Reset to Open / Revert Changes | Cloud | Partial | Reset All and undo are available, plus Reset buttons inside some panels. There is no revert to the state the photo was opened in. |
| Edit indicator dots on the tool strip | Classic | Partial | The grid shows a pencil badge on edited photos. There are no per-tool dots in Develop. |
| Copy/Paste Settings dialog with subsets and checkbox presets | Both | Partial | The Presets panel has a 'Copy / paste carries' checklist, now 17 groups (Profile, Effects and Lens Blur were added). There are no saved subsets and no 'Modified' option. |
| Update preset with current settings | Both | Partial | There is no Update command. Save… under an existing user preset's name overwrites it with the current settings. Built-ins cannot be updated. |
| Legacy and Basic profile groups | Both | *Not applicable → Partial* | Profiles now exist, so this row no longer rests on 'no profiles'. The Profile menu has a basic group ('Latent': Standard, Neutral, Flat) alongside the Creative and Black & White groups. There is no Legacy group: Latent has a single process version, so there are no older profiles to carry. |
| Create Develop preset (settings checklist) | Both | Present | Save… in the Presets panel saves the groups ticked under 'Copy / paste carries'. |
| Snapshots panel | Classic | Present | Named snapshots are kept in the History panel and stored in the sidecar. Restoring one is a history step, and snapshots can be deleted. |
| Reset button and undo | Classic | Present | Reset All, double-click on a slider to reset it, and ⌘Z undo. |
| Sync Settings | Classic | Present | Paste Settings applies to the whole Library selection. |
| Paste to one or many photos | Both | Present | Paste Settings (⇧⌘V) works on the Library selection and can be undone; Copy Settings is also in the grid context menu. |
| Show Partially Compatible Develop Presets | Both | Not applicable | Presets are camera-agnostic, so there is nothing partially compatible to show. |
| Duplicate preset names and Store Presets With Catalog | Classic | Not applicable | Presets live in Application Support by design (per-folder catalogs, no master catalog). |
| Premium presets | Both | Not applicable | These are subscription content, and Latent is free with no accounts. |
| Recommended presets (Sensei, community) | Cloud | Not applicable | These need cloud community content; Latent has no network access. |

## Photo Merge (HDR, panorama)

| Lightroom feature | Product | Latent status | Notes |
|---|---|---|---|
| JPEG XL lossy DNG compression for merges | Both | Missing | Merged DNGs are still written as uncompressed half-float LinearRaw DNGs (about 145 MB at 24 MP). The writer has a lossless deflate option, but no merge uses it and there is no JPEG XL or lossy choice. JPEG XL is now only an export format, and only on Macs that can write it. |
| Nikon Pixel Shift merge | Both | Missing | There is no pixel-shift merge. The Photo Merge menu offers only HDR, Panorama and HDR Panorama. |
| HDR previews in merge dialogs | Cloud | Missing | The Photo Merge sheet preview is still an SDR image about 1,024 px long. The new HDR Limit slider only affects Develop and soft proofing, not the merge dialogs. |
| Denoise on merged results | Both | Missing | AI denoise is still turned off for HDR merges and other linear DNGs, with the message "Not available for merged or linear DNG images". Only the manual Luminance and Colour noise reduction sliders in the Detail panel work on a merge. |
| Merge to HDR, Panorama and HDR Panorama | Both | Partial | Photo > Photo Merge offers HDR…, HDR Merge Without Dialog, Panorama… and HDR Panorama… (Experimental). They include auto-align, deghost levels with an overlay, a choice of reference frame, projections, auto crop and size consent. Boundary Warp and Fill Edges are missing, and panoramas can only be a single row: no grids and no 360° wrap. Nothing in the merge feature has changed since 2 November. |
| Merge to Panorama in Photoshop | Classic | Not applicable | This belongs to the Adobe ecosystem. Latent has no external-editor or Photoshop link. |
| Merge to HDR Pro in Photoshop | Classic | Not applicable | This belongs to the Adobe ecosystem. Latent has no external-editor or Photoshop link. |

## Export & publish

| Lightroom feature | Product | Latent status | Notes |
|---|---|---|---|
| Add exported photos to catalog / Add to Stack | Classic | Missing | There is no Add to This Catalog option and no stacks. The export queue never re-indexes its output. Files exported into the open folder only turn up if folder watching happens to pick them up. |
| JPEG XL export | Classic | Missing | The code for JPEG XL export exists. Exporter.swift has Format.jxl with quality and size limit support. The Format menu only lists it when ImageIO reports a JPEG XL encoder, and this Mac (macOS 27.2) has none, so no user can reach it. Limitations.md also says JPEG XL is shown only where the system can write it. |
| PSD and PSB export | Classic | Missing | No PSD or PSB writer. Limitations says there is no PSD. |
| Export Actions folder (droplets, scripts) | Classic | Missing | No Export Actions folder. After export you can only show in Finder or open in one chosen app. |
| Hard Drive publish service (republish tracking) | Classic | Missing | No publish services and no tracked published folders, so there is no marking of photos that changed for republishing. |
| AVIF export | Classic | *Missing → Partial* | AVIF appears in the Format menu, with quality and a size limit, only when the system ImageIO can encode AVIF. It is not guaranteed on every Mac. |
| DNG export | Classic | *Missing → Partial* | The Format menu has "DNG (edits baked in)". It writes a full-size linear DNG with white balance, exposure, noise reduction, lens corrections, healing and masks baked in. The look (tone, colour, presence, sharpening) is left out, so the DNG does not reproduce the edit the way a Lightroom DNG with settings does. |
| Write Keywords as Lightroom Hierarchy | Classic | *Missing → Partial* | Keywords are now hierarchical. The Original + XMP sidecar export writes lr:hierarchicalSubject. Rendered JPEG/TIFF and other image exports flatten keywords into IPTC/dc:subject levels only, with no hierarchy and no option to choose. |
| Export image formats | Classic | Partial | JPEG, HEIC, PNG and TIFF always; AVIF and JPEG XL when the system can encode them; DNG; and Original + XMP. PSD/PSB are still missing. |
| HDR Output on export | Both | Partial | An optional gain map for JPEG and HEIC, in sRGB or Display P3 only. The headroom follows the photo's HDR Limit (up to three stops). The main image is always SDR, with no SDR-rendition settings, and there is no HDR AVIF, JPEG XL or TIFF. |
| Watermarking and Watermark Editor | Classic | Partial | A text watermark (tokens, font, colour) or a PNG graphic, with size, opacity, four corners and quarter-turn rotation. There is no centre or edge anchor, no offsets, no shadow, a single line only, and no named watermark presets or editor window. |
| Export resolution (ppi) | Both | *Missing → Present* | The Image Sizing section has a Resolution toggle with a ppi field and 240/300/360 shortcuts. The value is written into the file and used by matte and glossy sharpening. |
| Output sharpening (Screen/Matte/Glossy) | Both | *Missing → Present* | "Sharpen for" offers Screen, Matte or Glossy paper at three amounts. It runs after the resize, scaled to the ppi. |
| Export With Previous | Both | *Missing → Present* | File > Export with Previous (Option-Shift-Command-E) repeats the last run's batches without the sheet. |
| Multi-batch export | Classic | *Missing → Present* | "Export with several presets" in the sheet lets you tick saved presets. One run exports the selection once per preset, each into its own subfolder. |
| Export location options | Classic | *Partial → Present* | Export to Chosen folder, Same folder as original or Choose folder later. There is also a subfolder field and date subfolders. Adding the files to the catalog is covered by its own row. |
| JPEG export options (Quality, Limit File Size) | Classic | *Partial → Present* | Quality, with its comparison window, plus "Limit file size to … KB". The limit lowers quality per image and reports any image that will not fit. |
| TIFF export options (bit depth, compression) | Classic | *Partial → Present* | 8 or 16 bits per channel, and None, LZW or ZIP compression. |
| Export Original (with XMP sidecar) | Both | *Partial → Present* | Format > "Original + XMP sidecar" copies the raw unchanged with an .xmp beside it. The sidecar holds rating, label, keywords (with hierarchy) and Latent's edit. |
| Export colour space selection | Both | *Partial → Present* | sRGB, Display P3, Adobe RGB (1998), ProPhoto RGB, any installed RGB ICC profile, or Other… to pick one. |
| Image sizing (Width & Height, Long/Short Edge, Megapixels, Percentage, Don't Enlarge) | Classic | *Partial → Present* | "Resize to fit" offers Long edge, Short edge, Width & height, Dimensions, Megapixels and Percentage, with Don't enlarge. |
| Metadata inclusion levels | Classic | *Partial → Present* | The Metadata menu offers None, Copyright only, Copyright and contact, All except camera info, or All, plus the Include location switch. |
| Post-processing After Export | Classic | *Partial → Present* | "Show in Finder when done" and "Open in" a chosen application. The Export Actions folder is covered by its own row. |
| Export dialog | Classic | Present | The Shift-Command-E export sheet, now with format, colour space, sizing, sharpening, watermark, metadata, location, after-export and multi-batch sections. |
| Existing-file conflict handling | Classic | Present | Add a number, Replace or Skip, planned before the export starts. |
| File naming templates on export | Classic | Present | Tokens, sequence and case. |
| PNG export | Both | Present | 8-bit PNG; there is still no 16-bit option. |
| Gain-map export (ISO 21496-1) | Both | Present | JPEG and HEIC, in sRGB or Display P3. |
| Remove Location Info | Both | Present | The Include location switch, off by default, also strips serial numbers. It is greyed out at the copyright-only levels. |
| Export presets | Classic | Present | Built-in presets plus saved presets, which now also feed multi-batch and Export with Previous. |
| Background export with progress | Classic | Present | A queue with progress, failures, cancel and keep-awake, now running one batch per preset. |
| Video export | Classic | Not applicable | Latent has no video. |
| Reverse-geocoding suggestions on export | Classic | Not applicable | Needs the network, which Latent never uses. |
| Export to CD/DVD | Classic | Not applicable | Obsolete; current Macs have no optical drive. |
| Content Credentials (C2PA) | Both | Not applicable | Requires an Adobe account and internet. |
| AI Updates Required dialog | Both | Not applicable | Model masks are regenerated at export, so there is nothing to prompt for. |
| Email Photo and Email Account Manager | Classic | Not applicable | Latent has no network access. |
| Publish Services (Flickr, Adobe Stock, third-party plug-ins, export plug-ins, SDK) | Classic | Not applicable | No network and no plug-in ecosystem. |
| Cloud sharing family (Lightroom Links, Share & Invite, Connections, web download, Google Photos, Instagram, edit replay) | Both | Not applicable | Latent has no cloud. |
| Mobile export (Export as, borders, save copy) | Cloud | Not applicable | Latent has no mobile app. |
| Remove Person Info on export | Classic | Not applicable | Latent keeps no people metadata, so there is nothing to strip. |

## Print & book

| Lightroom feature | Product | Latent status | Notes |
|---|---|---|---|
| Picture Package, Custom Package and Cells panel | Classic | Missing | Still only even grids from the print panel's photos-per-page choice; no mixed-size packages, freely placed cells or Cells panel. |
| Print templates (Template Browser, import/export) | Classic | Missing | The last print layout is remembered between prints, but there are no named print templates to save, browse, import or export. |
| Print guides, rulers, grid snap, cut guides | Classic | Missing | None. The print panel preview shows the layout from thumbnails but has no rulers, guides, snapping or cut marks. (The new crop guides are in Develop only.) |
| Draft Mode Printing | Classic | Missing | Prints always render each photo in full from the RAW; there is no quick print from cached previews. |
| Print Sharpening | Classic | Missing | The new output sharpening (screen/matte/glossy) is in the Export sheet only; the print panel has no print sharpening. |
| Print Adjustment (Brightness, Contrast) | Classic | Missing | No print-only brightness or contrast compensation. |
| Saved Print (print collection) | Classic | Missing | Collections and smart collections now exist and their photos can be printed from the Library selection, but a collection cannot store a print layout with its photos as a Saved Print. |
| Book module (Blurb/PDF/JPEG books, auto layout, templates, cells, text, type, backgrounds, saved book) | Classic | Missing | No book module; File > Contact Sheet… PDF is still the only multi-page output. |
| Print module layout styles | Classic | Partial | File > Print… lays out single images or contact-sheet grids of 1 to 30 per page; no Picture Package or Custom Package styles. |
| Print Image Settings (Zoom to Fill, Rotate to Fit, borders) | Classic | Partial | Fit or Fill scaling and Auto-Rotate in the print panel's Latent section; no photo border or inner stroke. |
| Print Layout panel (margins, grid, spacing, cell size) | Classic | Partial | Margin (0–72 pt) and spacing (0–36 pt) are adjustable; the grid follows the photos-per-page choice, with no separate rows/columns or cell size controls. |
| Print Page overlays (background, identity plate, watermark, page info, photo info) | Classic | Partial | Captions under each photo (name, date, camera). No page background colour, identity plate or page info; the new watermark applies to exports only, not prints. |
| Print To: JPEG File | Classic | Partial | File > Contact Sheet… writes JPEG, PNG or PDF; single-image print layouts from Print… can only go to the printer (or the system PDF button), not to a JPEG. |
| Print colour management (ICC profile, rendering intent) | Classic | *Partial → Present* | The print panel's Colour choice prints in Display P3 16-bit (printer-managed) or converts into the printer/paper ICC profile chosen in Soft Proof, and a new Rendering Intent picker offers Perceptual or Relative Colorimetric (with black point compensation), starting from Soft Proof's intent. Saturation intent is not offered and the profile is picked in Soft Proof rather than the print panel. |
| Page Setup and Print Settings | Classic | Present | Uses the macOS print panel and Page Setup for paper, scale and printer, with Latent's own section added. |
| Print Resolution control | Classic | Present | Renders at the printer's reported resolution, clamped to 150–360 dpi. |
| 16 Bit Output | Classic | Present | Prints render at 16 bits (Display P3, or RGB/grey printer profiles). |
| Contact sheet printing | Classic | Present | File > Contact Sheet… and multi-photo layouts in File > Print…. |
| Order prints through Connections | Cloud | Not applicable | Needs a network service; Latent makes no network access by design. |
| Send Book to Blurb / BookWright connection | Both | Not applicable | Needs a network service; Latent makes no network access by design. |

## Slideshow, web & presentation

| Lightroom feature | Product | Latent status | Notes |
|---|---|---|---|
| Slideshow Options (Zoom to Fill, Stroke Border, Cast Shadow) | Classic | Missing | Slides are always fitted to the screen; there is no Zoom to Fill, border or shadow option in Settings > Slideshow. |
| Slideshow Layout margins and guides | Classic | Missing | No layout margins or guides; slides are simply fitted to the screen. |
| Slideshow Backdrop (colour wash, image, colour) | Classic | Missing | The backdrop is always black; no colour, colour wash or background image. |
| Slideshow Titles (intro and ending) | Classic | Missing | No intro or ending title screens. |
| Export Slideshow to PDF or JPEGs | Classic | Missing | A slideshow can only be played on screen; it can't be exported to PDF or JPEG slides. |
| Export Slideshow to Video | Classic | Missing | No video export of a slideshow. |
| Web module gallery generation (HTML layouts, export to disk, preview) | Classic | Missing | No web module and no HTML gallery export. An offline gallery would fit the design, but none has been built. |
| Web module design panels (templates, site info, colours, appearance, image info, output) | Classic | Missing | No web module, so none of these panels exist. |
| Saved slideshow collection | Classic | *Missing → Partial* | Collections and smart collections now exist, and choosing one in the Collections sidebar scopes the grid, so Slideshow (⌘Return) plays that collection. But slideshow settings are one global set in Settings > Slideshow, and you can't save a slideshow with its own settings as a collection. |
| Slideshow module and templates | Classic | Partial | Slideshow settings live in Settings > Slideshow (interval, transition, duration, loop, caption, music). There is no slideshow module, editor or saved templates. |
| Slideshow Overlays (identity plate, rating, text) | Classic | Partial | Captions come from four fixed presets: none, file name, name and date, or camera and exposure. No identity plate, star rating or free text overlay. The new watermark applies to exports only. |
| Slideshow music | Classic | Partial | Plays an ordered list of chosen songs with fades. No Fit to Music and no beat sync. |
| Slideshow Playback settings | Classic | Partial | Has slide duration, five transitions (Cut, Cross-Fade, Fade Through Black, Push, Zoom), transition length and loop. No random order, no pan and zoom, and no fade colour choice. |
| Text Template Editor for captions | Classic | Partial | Token templates exist for export naming and batch rename, and the watermark takes {year} and {name}. Slideshow captions are still a fixed set of four presets with no template editor. |
| Identity Plate overlays | Classic | Partial | There is no identity plate. The export watermark can now be either a text line ({year}/{name} tokens, with font, style and rotation) or a graphic logo from a PNG with transparency. You can set the corner, size, opacity and colour, and presets remember the settings. It is applied to exports only: it doesn't appear on slideshows, prints or contact sheets. |
| Play, preview and impromptu slideshow | Classic | Present | Choose Slideshow (⌘Return) from the Library to play the selection, or everything the filter or collection shows. You can step through slides with the keyboard. |
| Video clips inside slideshows | Classic | Not applicable | Latent doesn't handle video. |
| Web Upload Settings (FTP) | Classic | Not applicable | No network access, by design. |
| Web gallery engine plug-ins | Classic | Not applicable | No plugin ecosystem, by design. |
| Share synced collections, Share & Invite, album customisation and permissions, Shared with You | Both | Not applicable | No cloud or accounts, by design. |
| Connections to third-party services | Cloud | Not applicable | No network access, by design. |
| Edit replay videos and Post to Community | Cloud | Not applicable | No cloud, by design. |
| Mobile and web slideshow | Cloud | Not applicable | No mobile app and no cloud, by design. |

## Soft proofing & colour management

| Lightroom feature | Product | Latent status | Notes |
|---|---|---|---|
| HDR colour spaces | Both | Partial | HDR is shown through an extended linear Display P3 EDR layer, and the new HDR Limit slider caps how far highlights go. There is no choice of HDR output colour space such as HDR P3 or HDR Rec.2020 (PQ/HLG), and HDR exports are gain maps only. |
| Separate SDR and HDR external-editing colour settings | Both | Partial | Edit in External Editor (⌘E) always writes a 16-bit Display P3 TIFF. Settings only let you pick the app and the folder. There are no colour space, bit depth or HDR settings for external editing. |
| HDR output on export (AVIF, JXL, JPEG gain map, TIFF, PSD, PNG) | Both | Partial | Export now writes AVIF and JPEG XL (when the Mac supports them) as well as JPEG, HEIC, PNG and TIFF, but only JPEG and HEIC can carry an HDR gain map, and only in sRGB or Display P3. AVIF, JPEG XL, TIFF and PNG are SDR only, and there is no PSD. |
| HDR Output editing mode | Both | Partial | Develop has an HDR display switch showing the screen's headroom and a new HDR Limit slider (a saved, undoable part of the edit) that sets the gain-map headroom, up to three stops. There are no SDR rendition settings or SDR preview for the HDR edit. |
| 16-bit HDR Photoshop round-trip | Classic | Partial | External editing makes a 16-bit Display P3 TIFF, which is SDR. HDR is not kept, and the TIFF doesn't come back into the Library. |
| Soft Proofing (intents, paper & ink, gamut warnings, proof copy) | Classic | *Partial → Present* | The Soft Proof group in Develop proofs against sRGB, Display P3 or any ICC printer/paper profile, with Perceptual or Relative Colorimetric intent (with black point compensation), Simulate Paper & Ink, a red destination gamut warning and a blue monitor gamut warning. Create/Update Proof Copy saves the edit as a "Proof — <profile>" snapshot rather than a virtual copy, and Saturation intent isn't offered. |
| Export colour space selection (Adobe RGB, ProPhoto, custom ICC) | Both | *Partial → Present* | The Export sheet's Colour space menu offers sRGB, Display P3, Adobe RGB (1998), ProPhoto RGB, the Mac's installed RGB profiles and Other… for any RGB ICC file (custom profiles convert with Perceptual intent). It warns about 8-bit ProPhoto, every file embeds its profile, and CMYK and grey profiles are refused. |
| Print colour management | Classic | *Partial → Present* | The print panel's Colour menu prints either as 16-bit Display P3 (left to the printer's own colour matching, like Lightroom's Managed by Printer) or converted into the soft-proof printer/paper profile, with its own Rendering intent menu (Perceptual or Relative Colorimetric). The profile can't be chosen in the print panel: the profile option appears only while Soft Proof is switched on in Develop with an ICC profile as its target. Print Adjustment brightness/contrast sliders are missing; that has its own row. |
| Develop working colour space | Classic | Present | Edits are rendered in a linear Rec.2020 working space (Lightroom uses ProPhoto primaries). |
| Display colour management (OS monitor profile) | Both | Present | The image view is a colour-tagged EDR Metal layer, so macOS ColorSync converts it to the monitor's profile. The monitor gamut warning reads the screen's own ICC profile. |
| HDR display support and requirements | Both | Present | EDR is turned on only while the photo needs headroom. The HDR display switch appears only on screens that have headroom. This has been verified on an XDR screen; other HDR displays are untested. |
| Enable HDR in Library | Classic | Present | The HDR display switch also applies when viewing a photo in Loupe, through the same EDR Metal view. Slideshows are SDR. |

## Performance, previews & hardware

| Lightroom feature | Product | Latent status | Notes |
|---|---|---|---|
| Smart Previews (edit while originals offline) | Classic | Missing | Still no proxy files: a favourite folder on a disconnected drive cannot be browsed or edited; nothing in Sources builds or reads smart previews. |
| Standard previews (size and quality settings) | Classic | Partial | Fixed 512 px HEIC thumbnails (decoded at 256 px for small grid cells), now also made for JPEG, HEIC, TIFF and PNG files; everything larger is rendered live. No size or quality setting. |
| Preview cache management (Previews.lrdata, discard commands) | Classic | Partial | Byte-bounded in-memory thumbnail cache (64-256 MB, scaled to RAM) and the thumbnail folder is excluded from Time Machine; no size controls and no discard or rebuild command in the menus. |
| Camera Raw cache settings | Classic | Partial | Demosaic result is cached per open image session in memory; there is no disk cache and no settings for one. |
| Use Graphics Processor (Auto/Custom/Off) and per-task GPU options | Classic | Present | Metal is always used for display, processing, export and thumbnails; there is no off switch, which Latent does not need. |
| GPU and memory requirements for AI features | Both | Present | Apple Silicon M1 or later with Metal 3; 8 GB Macs get reduced limits. |
| Apple Neural Engine acceleration for Denoise | Both | Present | Settings has an AI compute choice; GPU is the safe default and the Neural Engine can be opted into. |
| Native Apple silicon builds | Both | Present | Built for arm64 Apple Silicon only. |
| System requirements | Both | Present | macOS 15 or 26 on Apple Silicon. |
| Embedded & Sidecar preview workflow | Classic | Present | The grid fills from embedded RAW previews within seconds; JPEG/TIFF/HEIC/PNG files now serve as their own preview. |
| Generate Previews in Parallel | Classic | Present | Thumbnails are generated in the background with progress shown. |
| Develop pre-loading and XMP write throttling | Classic | Present | Sidecar writes are debounced and the demosaic is cached per image session. |
| Interactive slider and full-screen performance | Both | Present | Preview re-renders take 2-4 ms and need no draft mode. |
| Memory release under pressure | Classic | Present | On memory warnings Latent releases texture pools, caches, loaded models and the denoise result, and trims the thumbnail cache. |
| Multi-display preview resolution matching | Classic | Present | The second display is rendered live at its own resolution and headroom. |
| Windows on ARM support | Both | Not applicable | Latent runs on macOS only (DESIGN non-goals). |
| AVX2 CPU requirement | Classic | Not applicable | There is no Intel build. |
| Mobile and web platform requirements | Cloud | Not applicable | There is no mobile or web app. |
| 1:1 previews, discard schedule, Limit Preview Cache Size | Classic | Not applicable | Latent renders at full quality live and keeps no rendered preview cache (Motivation, Design principles). |
| Use Smart Previews instead of Originals | Classic | Not applicable | Latent has no preview proxies by design. |
| Video cache settings | Classic | Not applicable | Latent does not handle video. |
| Cloud desktop and mobile performance work, mobile cache limit | Cloud | Not applicable | There is no cloud service or mobile app. |

## Platform, sync, mobile & ecosystem

| Lightroom feature | Product | Latent status | Notes |
|---|---|---|---|
| Localisation (16 UI languages) | Both | Missing | Still English only: there are no .strings, .xcstrings or .lproj resources anywhere in the repository and no default localisation in the package. |
| External Controllers API | Cloud | Missing | There is no MIDI, game controller or editing console support. Sliders respond only to the mouse, keyboard and typed values. |
| Edit in third-party apps (last five remembered) | Cloud | Partial | Settings > External Editor keeps a list of added applications and a hand-off folder, but only one is chosen at a time. File > Edit in <app>… (⌘E) offers just that one, with no submenu of recently used apps. The export sheet's separate 'Open in' option also takes a single application. |
| Classic-to-cloud sync, sync preferences, sync limitations, cloud sync controls | Both | Not applicable | Latent has no network access and no cloud, by design. |
| Shared albums with contributions and notifications | Cloud | Not applicable | There is no cloud and there are no accounts, so there is nothing to share albums through. Collections are local to each folder's catalog. |
| Lightroom on the web | Cloud | Not applicable | No cloud and no web version. Latent is a native Mac app only. |
| Lightroom for mobile feature set | Cloud | Not applicable | No iPad or iOS version, by design. |
| Lightroom mobile in-app camera | Cloud | Not applicable | No mobile app. |
| Lightroom for Apple Vision Pro | Cloud | Not applicable | No mobile or visionOS app. |
| Lightroom for Apple TV | Cloud | Not applicable | No cloud library to stream to a TV. For on-screen viewing, use the slideshow in the Mac app. |
| Creative Cloud Libraries and cross-app access | Both | Not applicable | No Adobe or other cloud ecosystem. Other apps can open images through the external editor hand-off and through exports. |
| Lua plug-in SDK and no-plugins policy in the cloud apps | Both | Not applicable | No plugin ecosystem, by design. |
| Publish Services vs Connections | Both | Not applicable | No network access, so there are no publish services. Export writes to local folders only. |
| Adobe Discover community | Cloud | Not applicable | No cloud or online community features. |
| Migrate Lightroom Classic catalog to the cloud | Cloud | Not applicable | No cloud. |
| Classic vs ecosystem storage model | Both | Not applicable | Latent keeps one catalog per folder and works on files in place, locally. There is no master catalog and no cloud storage. |
| Pricing plans, licensing and activation, generative credits, storage add-ons | Both | Not applicable | Latent is free under GPLv3, with no accounts, activation or credits. |
| Open as Smart Object / Layers in Photoshop and Camera Raw fallback | Both | Not applicable | These are Photoshop-specific hand-offs. Latent's general equivalent is File > Edit in <app>…, which sends a TIFF to any chosen application. |
| Send photos to Photoshop on iPad | Cloud | Not applicable | No mobile app and no network. |
| Import and display of Camera Raw Technology Preview edits | Both | Not applicable | Compatibility with Lightroom and Camera Raw edits is a non-goal, by design. |
| HDR editing on more mobile devices and web | Cloud | Not applicable | No mobile or web app. HDR work happens in the Mac app only. |

## Customisation, shortcuts & accessibility

| Lightroom feature | Product | Latent status | Notes |
|---|---|---|---|
| Customize Develop Panel (reorder, hide) | Classic | Missing | Develop panels still appear in a fixed order with no option to reorder or hide them; the only control is collapsing groups (Transform now starts folded). |
| Customisable Identity Plate | Classic | Missing | No identity plate or custom branding area. The Appearance tab in Settings offers theme, accent colour and image surround only. |
| Keyboard shortcut customisation | Both | Missing | Shortcuts still come from one fixed table (Shortcuts.all) and use Lightroom's keys. Settings has no tab for rebinding them. |
| Panel and workspace customisation (Solo Mode, panel swap, font size) | Both | Partial | Groups collapse, the sidebar and filmstrip can be toggled, and Settings › Appearance sets the light/dark theme, accent colour and image surround (black, grey or light grey). There is no solo mode, no swapping or reordering of panels and no panel font size. |
| Module shortcut help overlay (Cmd+/) | Both | Partial | Help › Latent Help (⌘?) opens the in-app Help window, which has search and includes the generated Keyboard Shortcuts page. There is no overlay over the current module. |
| Disable single-key shortcuts preference | Cloud | Partial | Single-key shortcuts pause while a text field has focus. Settings has no switch to turn them off entirely; the related option there is Library's 'Arrow keys pan a zoomed-in image'. |
| Accessibility: keyboard navigation and screen readers | Both | Present | Still in place: Full Keyboard Access, VoiceOver labels and spoken status announcements throughout, Reduce Motion and Increase Contrast. Newly added controls (for example the RAW+JPEG toggle) also carry accessibility labels. |
| iPad keyboard shortcuts and menu bar | Cloud | Not applicable | No mobile app. |
| Redesigned mobile edit UI and gestures | Cloud | Not applicable | No mobile app. |
| New Classic shortcuts and tool-UI changes | Classic | Not applicable | Lightroom-internal. |

## Video

| Lightroom feature | Product | Latent status | Notes |
|---|---|---|---|
| Video files in the Library (import, play, trim, poster frame) | Both | Missing | Latent still shows stills only. The new formats work added JPEG, HEIC, TIFF and PNG files and RAW+JPEG pairs, but video files are not listed, played or trimmed, and there is no poster frame. The Limitations page still says no video. |
| Supported video import formats | Classic | Missing | No video container or codec is recognised. Folders are scanned for raw files and still-image formats only. |
| Develop adjustments on video and Tone Curve for video | Both | Missing | The Develop pipeline works on still images only. No adjustments or tone curve can be applied to video frames. |
| Video export (H.264, DPX, Original, 4K) | Classic | Missing | The expanded Export sheet offers still formats (JPEG, HEIC, TIFF, PNG, DNG) only. It has no video encoding and no option to export the original video. |
| Hardware-accelerated HEVC decoding and encoding | Classic | Missing | There is no HEVC video decoding or encoding. Latent can export HEIC stills through ImageIO, but that is still-image output and does not cover this row. |
| HDR video viewing, editing and export | Cloud | Missing | There is no video support of any kind. HDR display and the HDR limit in soft proofing apply to stills only. |
| Generated video from stills (Generate Video, Animate) | Cloud | Not applicable | This is a cloud generative feature, and it conflicts with Latent's rule of no network access and no cloud. |

## Tethering & capture

| Lightroom feature | Product | Latent status | Notes |
|---|---|---|---|
| Third-party tether plug-ins and watched-folder tethering | Classic | *Not applicable → Partial* | Watched-folder tethering now works. Under Settings › Folders › Auto Import, you choose the watched folder your tethering app saves into and a destination folder. Latent waits until each new raw or JPEG/HEIC/TIFF/PNG file has finished being written, moves or copies it in, can apply a Develop preset, and shows it in the grid and Recently Added. Only files directly in the watched folder are taken, not its subfolders. Tether plug-ins are still not applicable because Latent has no plugin ecosystem. |
| Tethered capture and Tethered Capture Settings | Classic | Not applicable | Still a declared non-goal: Latent has no camera connection or capture code at all. The nearest thing is Auto Import, which picks up files that another app's tethering software saves into a watched folder. |
| Tethered Live View with focus control | Classic | Not applicable | Non-goal (no tethering). Latent has no Live View and no camera control. |
| Native tethering for Canon, Nikon, Sony, Fujifilm, Leica | Classic | Not applicable | Non-goal (no tethering). Latent has no camera drivers or vendor SDKs. |

## Help, onboarding & learning

| Lightroom feature | Product | Latent status | Notes |
|---|---|---|---|
| Redesigned What's New window | Classic | *Missing → Partial* | A What's New page listing everything added since the 0.9.0 beta, with links to the full descriptions, now ships in the app and opens from Help › Latent Help (⌘?) under Help & Learning. There is no dedicated What's New window, no Help menu item for it, and nothing opens it on its own after an update. |
| In-app learning, interactive tutorials and contextual help | Cloud | Partial | The Help window (Help › Latent Help, ⌘?) has the whole wiki with search, now including Getting Started, three step-by-step tutorials (Culling and Organising, Editing, Printing and Sharing), Coming from Lightroom, a Glossary and an FAQ. Controls have tooltips and there are empty-state hints. The tutorials are written pages you read and follow yourself. There are no interactive walkthroughs that point at or drive the interface, and no help opens from a panel's context. |
| Provide Feedback / Report an issue | Both | Partial | The FAQ page in the Help window has a 'Report an issue or get help' section that says what to include and links to the GitHub issues page, which opens in the browser. There is no Report an Issue or Provide Feedback menu item and no form inside the app. A form would also clash with the no-network rule. |
| Early Access and Technology Previews | Both | Not applicable | This is part of Adobe's release process. Latent is a free GPLv3 project with no accounts and no channel for previews. |
| Discover renamed Community | Cloud | Not applicable | This is an online community feed. Latent has no cloud and no network access. |
| In-app tutorials on mobile | Cloud | Not applicable | Latent has no mobile app. |

## Method and sources

Lightroom side: Adobe help pages read through the browser on 2 November 2026 (helpx.adobe.com returns 403 to fetchers), covering Lightroom Classic 15.x import, catalog, folders, metadata, keywords, collections, develop module tools, tone and colour, masking, Remove tool, Lens Blur, Enhance, HDR output, export, print, book, slideshow, web module, GPU FAQ, system requirements, tethered camera support, supported formats, release notes (updated 29 September 2026, version 15.6) and the Classic versus ecosystem feature comparison (20 February 2026); Lightroom desktop 9.6 and mobile 11.6 help and release notes; Lightroom Queen's per-release notes from 13.0 to 15.6; Adobe community announcements for 15.0 to 15.6 and 9.2 to 9.6; Julieanne Kost's masking and book references; Adobe blog posts. Entries whose dates the researchers marked as model knowledge are noted in their original lists. Adobe MAX 2026 (10 to 12 November) had not happened, so nothing announced there is included.

Latent side: the 437-entry inventory built from the wiki (Getting-Started, Library, Develop, Models, Export, Photo-Merge, Keyboard-Shortcuts, Accessibility, Security-and-Privacy, Limitations, Troubleshooting, Motivation, Architecture), DESIGN.md, docs/PhotoMerge.md and README.md, plus read-only greps on 2 November 2026 of /Users/harman/latent/Sources (ContentView.swift, AppMenus.swift, LibraryFileOperations.swift, Catalog/Metadata.swift, Catalog/Schema.swift, PixelEngine/EditModules.swift, PixelEngine/EditStack.swift, PixelEngine/Crop.swift, PixelEngine/Exporter.swift, MetalImageView.swift, LocalAdjustmentsPanel.swift, HistogramView.swift, SlideshowSettings.swift, PrintLayoutSettings.swift) to confirm the absence of a delete command, saturation slider, flip, grain, GPS handling, auto-advance, invert selection, pixel readouts, localisation, preset update, TIFF compression, Lightroom XMP import and a Refresh command. No build, test or script was run and .build was not touched.

Latent side, 3 November re-check: 21 category agents read the code at commit 2078c07 (Sources/ and docs/wiki), with file:line evidence for every changed row, and a verifier per category tried to refute each change. The 2 November version of this document is kept in the session scratchpad for comparison.
