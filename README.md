# Latent, a catalog management and RAW editor for macOS

A native, Apple Silicon–first RAW photo manager and non-destructive editor for macOS.
Repository: `Harmanjit/latent-raw`.

- **Platform:** macOS 15 (Sequoia) and 26 (Tahoe), Apple Silicon. Verified on
  M1 Pro and M4; Metal 3 is the baseline. Building needs the full Xcode 16+
  selected as the active developer directory
  (`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`). The
  Metal toolchain is optional: without it (a separate download on Xcode 26,
  `xcodebuild -downloadComponent MetalToolchain`) the shaders compile at first
  launch.
- **License:** GPLv3. See `LICENSE`.
- **Status:** beta (Phase 9). Editing (with red-eye and brush healing), a catalog with a folder sidebar, Custom sort, Finder tags, moving and renaming images with their edits, undo in the Library, AI masks, Loupe, Compare and Survey, full-screen and second-display viewing, export (with optional HDR gain maps and a watermark), soft-proofing, printing, contact sheets, a slideshow, hand-off to an external editor and Photo Merge — HDR of handheld or tripod brackets (Photo › Photo Merge › HDR…, ⌃H), single-row Panoramas (Panorama…, ⌃M) and, marked experimental, HDR Panorama (⌃⇧M), all writing a DNG — work; DNG export does not exist. HDR Panorama has never been checked on a real bracketed sweep, because nobody has shot one for Latent yet. Expect rough edges.
- **Name:** the project was called *rawhead* until September 2026. Folders
  catalogued by those builds have a `_rawhead/` container; opening them in
  Latent renames it to `_latent/` in place, keeping every edit and sidecar.

See `DESIGN.md` for the full architecture: storage layout, pipeline design,
efficiency rules and the roadmap. `PHASE0.md` records what the Phase 0 spike
measured. The user guide is the wiki in `docs/wiki`, which the app also shows
under **Help > Latent Help**.

## Layout

```
Sources/
  RawCore/            LibRaw wrapper: unpacking, EXIF, embedded previews, the XPC decoder client, export metadata
  latent-rawdecoder/  The sandboxed XPC service that runs LibRaw
  PixelEngine/        Metal pipeline: kernels, stage cache, heal, red-eye, tone ranges, presenter, exporter, watermark, gain maps, page layout, slideshow transitions
  ColorKit/           Camera matrices, white balance, working space
  LensKit/            Lensfun database and lens matching
  Catalog/            Per-folder catalogs: GRDB schema, XMP read/write, reconciliation, thumbnails, sorting and Finder tags, moving and renaming images, undo, export naming
  MLKit/              Core ML and Vision: masks, AI denoise, red-eye detection, the export worker
  MergeKit/           Photo Merge: alignment, deghosting, the HDR merge, the panorama geometry and stitcher, the HDR panorama, the LinearRaw DNG writer and the latent:Merge recipe
  HelpKit/            The Help window's content: the wiki's Markdown, links and search
  latent-cli/         Headless renderer for benchmarks, and the merge commands (merge-hdr, pano-layout, merge-pano, merge-hdrpano)
  latent-app/         The SwiftUI/AppKit app (viewport, grid, sidebar, adjustments, export, print, slideshow, menus)
Tests/                Unit, golden-image, help-page and app-logic tests
docs/                 PhotoMerge.md, the Photo Merge plan and algorithm
docs/wiki/            The user guide (GitHub wiki and in-app Help)
vendor/               Vendored C/C++ dependencies (LibRaw) built as XCFrameworks
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
signed with the sandbox and nothing else: no file access (it is handed
an open descriptor per file), no network. A crafted raw file that
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
no crash reporting and no update check. The only code that can reach
the network is the optional model download, which is not offered in the
current build and, when it is, fetches one fixed URL and verifies a
checksum before installing anything.

What it writes, and where:

- `_latent/` inside each photo folder you open: the catalog database,
  one XMP sidecar per image (ratings, keywords, edits, history),
  thumbnails and, once you arrange a Custom sort, `custom-order.json`.
  Nothing else is written in your photo folders unless you ask: Move
  and Copy to Folder and Rename change files (never overwriting one, and
  undoing a copy puts it in the Trash), and Edit in External Editor
  writes a TIFF to the folder set for it. Finder tags are read, never
  written.
- `~/Library/Application Support/latent/`: compiled Core ML models and
  your saved presets.
- Settings in the app's UserDefaults, including bookmarks for the last
  folder, the export folder, the sidebar's favourite folders, the last
  five Move/Copy destinations, the external editor's folder and
  applications, and slideshow songs.
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

Theme (system/light/dark), accent colour, image surround grey, render
timings, default export folder, subfolder policy for new catalogs, whether
the arrow keys pan a zoomed-in image, the Core ML compute choice, the
slideshow (timing, transition, captions, music) and the external editor
(application and folder). Export naming templates, sequence numbers,
letter case, collision policy, date subfolders, the HDR gain map, the
watermark and saved export presets live in the export sheet (⇧⌘E); the
print layout lives in the print panel (⌘P).

## Building (on macOS, Apple Silicon, Xcode 16+)

```
swift build                                   # everything, debug
scripts/fetch_test_assets.sh                  # public-domain raw for the golden-image tests
swift test                                    # unit + golden tests (tests on private samples skip)
scripts/build_libraw.sh                      # once per clone: builds vendor/LibRaw.xcframework from a pinned tag
swift run latent-app TestAssets/photo.nef    # the editor, opening a file straight away (defaults such as -AppleLanguages (en) may come first)
swift run latent-cli render photo.nef --out /tmp/out.png   # headless render + timings
```

For a proper `.app` (Dock icon, window memory, signed for this Mac):

```
scripts/make_app.sh 0.1.0        # builds release and assembles build/Latent.app
open build/Latent.app
```

`make_app.sh` precompiles the shaders into `default.metallib` when the Metal
toolchain is installed (otherwise the app compiles them at first launch),
strips local symbols from the binaries before signing, and copies
`docs/wiki` into `Contents/Resources/Help` for the Help window.

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

`RawCore` depends on LibRaw as a vendored C library. See `vendor/README.md`
for how it's fetched and built as an XCFramework — this step needs to run
on macOS since it compiles native code for arm64.

## Test assets

Sample RAW files are intentionally not committed (they're large and mostly
redistributable-but-not-ours). `scripts/fetch_test_assets.sh` downloads
the public-domain D750 raw the golden-image tests render, which is all CI
uses. `TestAssets/README.md` describes the optional samples; tests whose
sample is missing skip themselves, and tests that need any D750 raw use the
public-domain one. `LATENT_CI_ASSETS_ONLY=1 swift test` hides every other
file, so a local run skips what CI skips.

## Contributing

Not yet open for contributions.
