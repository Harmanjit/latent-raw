<p align="center"><img src="Assets/AppIcon.png" width="160" height="160" alt="Latent's app icon: three landscape photos fanned out on a cream tile"></p>

# Latent, a catalog management and RAW editor for macOS

A native, Apple Silicon–first RAW photo manager and non-destructive editor for macOS.
Repository: `Harmanjit/latent-raw`.

- **Platform:** macOS 15 or newer (15, 26 and 27 verified), Apple Silicon.
  Verified on M1 Pro and M4; Metal 3 is the baseline. Building needs the full
  Xcode 16.3 (Swift 6.1) or newer, selected as the active developer directory
  (`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`). The
  Metal toolchain is optional: without it (a separate download on Xcode 26,
  `xcodebuild -downloadComponent MetalToolchain`) the shaders compile at first
  launch.
- **License:** GPLv3. See `LICENSE`. Third-party code, data and models
  (LibRaw, GRDB, the Lensfun database and the bundled Core ML models) keep
  their own licences, listed in [`docs/wiki/Licences.md`](docs/wiki/Licences.md)
  with the full texts in `licences/`; `make_app.sh` copies both `LICENSE`
  and `licences/` into the app. The bundled SegFormer weights (Select by
  Class) are under NVIDIA's non-commercial licence: research and evaluation
  use only.
- **Status:** version 1.0.0, the first public release. Editing (with red-eye and brush healing, a tone equalizer, masks built from several parts, Remove and Lens Blur), sensor dust removal, portrait touch-up, a catalog with a folder sidebar, collections, smart collections and hierarchical keywords, colour labels, virtual copies, stacks, folder watching and Auto Import, moving and renaming images with their edits, undo in the Library, AI masks (subject, click to select and by class, with a choice of models and more addable from disk), Loupe, Compare and Survey, full-screen and second-display viewing, export (wide-gamut and ICC profiles, output sharpening, sizing, DNG, HDR, PDF and a watermark), soft-proofing, printing, contact sheets, a slideshow, hand-off to an external editor and Photo Merge — HDR of handheld or tripod brackets (Photo › Photo Merge › HDR…, ⌃H), single-row Panoramas (Panorama…, ⌃M) and HDR Panorama (⌃⇧M), all writing a DNG — work. Known limits: HDR Panorama is **experimental**, because it has never been checked on a real bracketed sweep; Fujifilm X-Trans raws are catalogued but not rendered; floating-point raw DNGs, such as HDRMerge's output, cannot be opened; and the bundled SegFormer model is for research use only. [`CHANGELOG.md`](CHANGELOG.md) lists what changed since 0.9.0, and the wiki's [Limitations](docs/wiki/Limitations.md) page lists the rest.
- **Name:** the project was called *rawhead* until September 2026. Folders
  catalogued by those builds have a `_rawhead/` container; opening them in
  Latent renames it to `_latent/` in place, keeping every edit and sidecar.
- **Download:** a prebuilt app, ad hoc signed and not notarised, is on the
  [Releases page](https://github.com/Harmanjit/latent-raw/releases). The
  first time it opens, Gatekeeper stops it until you click **Open Anyway**
  in System Settings > Privacy & Security; see the wiki's
  [Installation](docs/wiki/Installation.md) page.

See `DESIGN.md` for the full architecture: storage layout, pipeline design,
efficiency rules and the roadmap. `PHASE0.md` records what the Phase 0 spike
measured. The user guide is the wiki in `docs/wiki`, which the app also shows
under **Help > Latent Help**.

## Layout

```
Sources/
  RawCore/            LibRaw wrapper: unpacking, EXIF, embedded previews, the XPC decoder client, export metadata
  latent-rawdecoder/  The sandboxed XPC service that runs LibRaw
  PixelEngine/        Metal pipeline: kernels, stage cache, heal (with the heal cache), red-eye, the sensor dust detector (BlobDetector, DustDetector, DustMap) and Visualise Spots, the touch-up stage and its mask set (TouchUp, TouchUpMasks, TouchUpStage), tone ranges, presenter, exporter, watermark, gain maps, page layout, slideshow transitions
  ColorKit/           Camera matrices, white balance, working space
  LensKit/            Lensfun database and lens matching
  Catalog/            Per-folder catalogs: GRDB schema, XMP read/write, reconciliation, thumbnails, sorting and Finder tags, moving and renaming images, undo, export naming
  MLKit/              Core ML and Vision: the model registry, manifests and importer (ModelRegistry, ModelManifest, ModelImporter), the bundled models and catalogue under Resources/Models, masks (SAM 2, SegFormer, SubjectSegmenter), AI denoise, the shared face-landmark pass (FaceLandmarker) behind red-eye detection, touch-up regions (TouchUpAnalysis, TouchUpRegions) and the blemish finder, the export worker
  MergeKit/           Photo Merge: alignment, deghosting, the HDR merge, the panorama geometry and stitcher, the HDR panorama, the LinearRaw DNG writer and the latent:Merge recipe
  HelpKit/            The Help window's content: the wiki's Markdown, links and search
  latent-cli/         Headless renderer for benchmarks, and the merge commands (merge-hdr, pano-layout, merge-pano, merge-hdrpano)
  latent-app/         The SwiftUI/AppKit app (viewport, grid, sidebar, adjustments, export, print, slideshow, menus; the Sensor Dust and Touch-up panels, overlays and editor extensions, the Remove Dust sheet, Settings › AI › Models, and SelectionJobQueue with its Remove Dust and Find Faces jobs)
Tests/                Unit, golden-image, help-page and app-logic tests
docs/                 PhotoMerge.md, the Photo Merge plan and algorithm; Retouch.md, the sensor dust, touch-up and subject-model plan
scripts/              Build, packaging and test-asset scripts, and the Core ML conversion scripts with latent_manifest.py, which writes and checks model manifests
docs/wiki/            The user guide (GitHub wiki and in-app Help)
vendor/               LibRaw, the one C/C++ dependency, built here as an XCFramework (not committed)
Assets/               The app icon: Latent.pdf, the vector original, and the AppIcon.icns and AppIcon.png made from it
TestAssets/           Sample RAW files (not committed; see below)
```

## Sandbox, signing and Gatekeeper

`scripts/make_app.sh` signs the bundle ad hoc with the App Sandbox and
the hardened runtime (`scripts/Latent.entitlements`). No developer
account is involved, and none is needed for either to be enforced: the
app can reach only the folders you choose in an open panel or add to the
sidebar's favourites, and everything inside those (remembered between
launches by security-scoped bookmark), its own container under
`~/Library/Containers/com.latent.app`, and nothing on the network, since
the network entitlement is deliberately absent. The one entitlement beyond
files and bookmarks is `com.apple.security.print`, which the sandbox
requires before it lets File > Print reach the printing system.

Raw decoding runs in a separate XPC service, `LatentRawDecoder.xpc`,
signed with the sandbox and nothing else: no network and no access to your
files (it is handed an open descriptor per file); it can write only to its
own container. A crafted raw file that
exploits the decoder gets a process that can do nothing, and the app
reports an error instead of crashing. `swift run` builds and the tests
decode in-process. `LATENT_RAW_INPROCESS=1` forces that only in a debug
build; `scripts/make_app.sh` always builds release, so it does nothing in
the bundles the script makes. Every such debug-only switch is compiled
under `#if DEBUG`.

What an account would add is notarisation. Without it, Gatekeeper stops
the app the first time it is opened from a download or a copy on another
Mac. Try to open it once, then open **System Settings > Privacy & Security**
and click **Open Anyway** next to the message about Latent. (Since macOS 15,
Control-click > Open no longer skips this step.) The Mac that built the app
opens it straight away. Alternatively, remove the quarantine attribute:

```
xattr -dr com.apple.quarantine /Applications/Latent.app
```

Development builds (`swift run`) are unsigned and therefore not
sandboxed, which is why `swift run latent-app <folder>` can open a path
from the command line and the bundle cannot.

## Privacy

Latent makes no network requests. There is no telemetry, no analytics,
no crash reporting and no update check, and nothing in the code base
downloads a model: Settings › AI › Models lists models you can add, its
Get… button only opens the model's page in your browser, and Add Model…
imports a folder, `.mlpackage` or `.zip` you converted yourself with the
scripts in `scripts/` (see `Sources/MLKit/Resources/Models/README.md`),
after checking its manifest and package hashes. Face finding, for red-eye
and Touch-up, uses Apple's Vision framework on this Mac.

What it writes, and where:

- `_latent/` inside each photo folder you open: the catalog database,
  one XMP sidecar per image (ratings, keywords, edits, history),
  thumbnails and, once you arrange a Custom sort, `custom-order.json`.
  Nothing else is written in your photo folders unless you ask: Move
  and Copy to Folder, Duplicate and Rename change files (never overwriting
  one, and undoing a copy or a duplicate puts it in the Trash), Auto Import,
  when you turn it on in Settings › Folders, moves (by default) or copies
  new raws from the folder it watches into the destination you chose,
  Edit in External Editor
  writes a TIFF to the folder set for it, and Photo Merge writes its
  result beside the reference photo (`<name>-HDR.dng`, `-Pano.dng` or
  `-HDRPano.dng`, numbered when the name is taken), with its sidecar in
  `_latent/`. Finder tags are read, never written.
- `~/Library/Containers/com.latent.app/Data/Library/Application Support/latent/`
  (`~/Library/Application Support/latent/` for `swift run` and
  `make_app.sh --dev` builds, which aren't sandboxed): compiled Core ML
  models, models you add (`models/<id>/`), saved dust maps
  (`dust-maps.json`) and your saved presets.
- The temporary folder: a panorama's prepared frames and HDR Panorama's
  intermediate DNGs while a merge runs, removed when it ends.
- Settings in the app's UserDefaults, including bookmarks for the last
  folder, the export folder, the sidebar's favourite folders, the last
  five Move/Copy destinations, Auto Import's watched and destination
  folders, the external editor's folder and applications and slideshow
  songs, plus Auto Import's ledger of the files it has already brought in
  (name, size and date of each, the last 20,000).
- Exported files go only where you choose. By default they carry the
  photo's own metadata (artist, copyright, camera details) plus Latent's
  keywords and rating, but not its **GPS location**, place names or the
  camera and lens serial numbers unless **Include location** is on. Both
  switches are in the export sheet and, for Export Open Image, in the left
  panel.

Failures are logged to the unified system log under `com.latent.app`
with file names marked private, so they show as `<private>` in Console
unless you opt in.

## Settings (⌘,)

Settings has eleven tabs: **Appearance** (theme, accent colour, image
surround grey, render timings), **Export** (default export folder),
**Library** (subfolder policy for new catalogs, whether the arrow keys pan
a zoomed-in image, RAW+JPEG pairs as one photo or two), **Folders** (folder
watching, reading other apps' sidecars, Auto Import, Restore Catalog
Backup), **AI** (the models behind
the masks, Add Model…, Remove, and the Core ML compute choice),
**Viewing** (focus peaking, colour assessment and the other viewing aids),
**Scopes** (vectorscope guides and the colour picker), **Performance**
(thumbnail quality, background generation, grid memory and the thumbnail
cache), **Slideshow** (timing, transition, captions, music), **External
Editor** (application and folder) and **Keyboard** (rebinding shortcuts).
Export naming templates, sequence numbers, letter case, collision policy,
date subfolders, the HDR gain map, the watermark and saved export presets
live in the export sheet (⇧⌘E); the print layout lives in the print panel
(⌘P). The wiki, starting at [`docs/wiki/Home.md`](docs/wiki/Home.md),
describes each setting where its feature is described.

## Building (on macOS, Apple Silicon, Xcode 16.3 or newer)

`RawCore` depends on LibRaw, built from source as an arm64 XCFramework by
`scripts/build_libraw.sh`. The framework is not committed, so a fresh clone
runs that script once, with Homebrew's autotools installed, before
`swift build`. See `vendor/README.md` for why and how.

```
brew install autoconf automake libtool pkg-config   # once
scripts/build_libraw.sh                       # once per clone: builds vendor/LibRaw.xcframework from a pinned commit
swift build                                   # everything, debug
scripts/fetch_test_assets.sh                  # public-domain raw for the golden-image tests
swift test                                    # unit + golden tests (tests on private samples skip)
swift run latent-app TestAssets/golden_nikon_d750_cc0.nef   # the editor, opening a file straight away (defaults such as -AppleLanguages (en) may come first)
swift run latent-cli render TestAssets/golden_nikon_d750_cc0.nef --out /tmp/out.png   # headless render + timings
```

For a proper `.app` (Dock icon, window memory, signed for this Mac):

```
scripts/make_app.sh 1.0.0        # builds release and assembles build/Latent.app
open build/Latent.app
```

A release build needs its version: given as above, or read from a tag on
HEAD (`v1.0.0`); `scripts/make_app.sh --dev` makes an unsandboxed test
build. `scripts/make_release.sh 1.0.0` makes what goes on the Releases page:
it runs `make_app.sh` and `check_app_bundle.sh` for that version, zips the
app with `ditto` into `build/Latent-1.0.0.zip`, checks that the unzipped
copy's signature still verifies, and prints the zip's SHA-256. It publishes
nothing and creates no tag. The checklist for a release is in
[`docs/wiki/README.md`](docs/wiki/README.md#releasing).

`make_app.sh` precompiles the shaders into `default.metallib` when the Metal
toolchain is installed (otherwise the app compiles them at first launch),
strips local symbols from the binaries before signing, copies
`docs/wiki` into `Contents/Resources/Help` for the Help window, copies
`LICENSE` and the third-party licence texts in `licences/` into
`Contents/Resources`, and adds the app icon, `Assets/AppIcon.icns`.
That file is committed; after changing the logo, `Assets/Latent.pdf`, remake
it (and the README's `AppIcon.png`) with `swift scripts/make_icon.swift`,
which places the artwork on Apple's icon grid with the grid's shadow.
`scripts/check_app_bundle.sh` checks the bundle `make_app.sh` leaves; CI runs
both on every push, so the release configuration is built there too.

A debug build can picture its own window without screen-recording
permission: `LATENT_SNAPSHOT_DIR=.build/snapshots swift run latent-app`
walks through the main views, saves a PNG of each and quits. The other
`LATENT_SNAPSHOT_*` switches are documented in
`Sources/latent-app/SnapshotHarness.swift`.

## Keyboard reference

The full list is [`docs/wiki/Keyboard-Shortcuts.md`](docs/wiki/Keyboard-Shortcuts.md),
generated from the one table in `Sources/latent-app/Shortcuts.swift` that
the menu bar and the single-key handler also use, so it can't drift. The
menu bar shows every command with its key. After changing the table, run
`LATENT_WRITE_SHORTCUTS_PAGE=1 swift test --filter ShortcutsPageTests`.

## Test assets

Sample RAW files are intentionally not committed (they're large and mostly
redistributable-but-not-ours). `scripts/fetch_test_assets.sh` downloads
the public-domain D750 raw the golden-image tests render, which is all CI
uses. `TestAssets/README.md` describes the optional samples; tests whose
sample is missing skip themselves, and tests that need any D750 raw use the
public-domain one. `scripts/fetch_test_assets.sh --portrait` adds the
public-domain NASA portrait the face-landmark and touch-up tests use, and
`--merge` the Photo Merge brackets. `LATENT_CI_ASSETS_ONLY=1 swift test`
hides every other file, so a local run skips what CI skips.

## Contributing

Not yet open for contributions. Bug reports are welcome at
https://github.com/Harmanjit/latent-raw/issues.

## Copyright and licence

Copyright © 2026 Harmanjit.

Latent is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free
Software Foundation, version 3 of the License. It is distributed in the
hope that it will be useful, but WITHOUT ANY WARRANTY; without even the
implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
See `LICENSE` for the full text. Third-party code, data and models keep
their own licences; see [`docs/wiki/Licences.md`](docs/wiki/Licences.md).
