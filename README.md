# Latent, a catalog management and RAW editor for macOS

A native, Apple Silicon–first RAW photo manager and non-destructive editor for macOS.
Repository: `Harmanjit/latent-raw`.

- **Platform:** macOS 15 (Sequoia) and 26 (Tahoe), Apple Silicon M3 or newer.
  Metal 3 is the baseline; Metal 4 only for optional fast paths on Tahoe.
- **License:** GPLv3. See `LICENSE`.
- **Status:** beta (Phase 7). Editing, catalog, AI masks, export and soft-proofing work; expect rough edges.
- **Name:** the project was called *rawhead* until September 2026. Folders
  catalogued by those builds have a `_rawhead/` container; opening them in
  Latent renames it to `_latent/` in place, keeping every edit and sidecar.

See `DESIGN.md` for the full architecture: storage layout, pipeline design,
efficiency rules and the roadmap. See `PHASE0.md` for exactly what this
spike needs to prove before Phase 1 starts.

## Layout

```
Sources/
  RawCore/       LibRaw wrapper — unpacking, EXIF, embedded previews
  PixelEngine/    Metal pipeline: kernels, stage cache, heaps
  ColorKit/       ICC / ColorSync / camera matrix handling
  LensKit/        Lensfun + embedded lens-correction lookup
  Catalog/        Per-folder catalogs: GRDB schema, XMP read/write, import
  MLKit/          Vision + Core ML masking
  latent-cli/    Headless renderer for golden-image tests and benchmarks
  latent-app/    The SwiftUI/AppKit editor (viewport, adjustments, export)
Tests/            Unit and golden-image tests
vendor/           Vendored C/C++ dependencies (LibRaw, etc.) built as XCFrameworks
TestAssets/       Sample RAW files for the CI test matrix (not committed — see below)
```

## Sandbox, signing and Gatekeeper

`scripts/make_app.sh` signs the bundle ad hoc with the App Sandbox and
the hardened runtime (`scripts/Latent.entitlements`). No developer
account is involved, and none is needed for either to be enforced: the
app can reach only the folders you choose in an open panel (remembered
between launches by security-scoped bookmark), its own container under
`~/Library/Containers/com.latent.app`, and nothing on the network, since
the network entitlement is deliberately absent.

Raw decoding runs in a separate XPC service, `LatentRawDecoder.xpc`,
signed with the sandbox and nothing else: no file access (it is handed
an open descriptor per file), no network. A crafted raw file that
exploits the decoder gets a process that can do nothing, and the app
reports an error instead of crashing. `swift run` builds and the tests
decode in-process; `LATENT_RAW_INPROCESS=1` forces that in the bundle.

What an account would add is notarisation. Without it, another Mac shows
"cannot verify the developer" on first launch. Right-click the app and
choose Open once, or run:

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
  one XMP sidecar per image (ratings, keywords, edits, history) and
  thumbnails. Nothing is written elsewhere in your photo folders.
- `~/Library/Application Support/latent/`: compiled Core ML models and
  your saved presets.
- Preferences in the app's UserDefaults, including the last export folder.
- Exported files go only where you choose; the export sheet can strip
  camera metadata, keywords and rating from them.

Failures are logged to the unified system log under `com.latent.app`
with file names marked private, so they show as `<private>` in Console
unless you opt in.

## Preferences (⌘,)

Theme (system/light/dark), accent colour, image surround grey, render
timings, default export folder, subfolder policy for new catalogs, and
the Core ML compute choice. Export naming templates, sequence numbers,
collision policy, date subfolders and saved export presets live in the
export sheet (⌘⇧E).

## Building (on macOS, Apple Silicon, Xcode 16+)

```
swift build                                   # everything, debug
swift test                                    # unit + golden tests (GPU tests skip without TestAssets)
scripts/build_libraw.sh                      # once per clone: builds vendor/LibRaw.xcframework from a pinned tag
swift run latent-app TestAssets/photo.nef    # the editor, opening a file straight away
swift run latent-cli render photo.nef --out /tmp/out.png   # headless render + timings
```

For a proper `.app` (Dock icon, window memory, signed for this Mac):

```
scripts/make_app.sh 0.1.0        # builds release and assembles build/Latent.app
open build/Latent.app
```

## Keyboard reference

| Keys | Action |
|---|---|
| G / D | Library / Develop |
| ← → | previous / next image (loads it in Develop) |
| Return | open the selection in Develop |
| 0–5, P / X / U | rating, pick / reject / unflag |
| ⌘[ ⌘] | rotate |
| ⌘0 ⌘1 ⌘= ⌘- | fit, 100%, zoom in/out |
| \ | before / after |
| ⌘Z ⌘⇧Z | undo / redo |
| ⌘⇧C ⌘⇧V | copy / paste settings (to the Library selection when several are selected) |
| ⌘U | Auto adjust |
| ⌘⇧O ⌘⇧E | open folder, export selection |

`RawCore` depends on LibRaw as a vendored C library. See `vendor/README.md`
for how it's fetched and built as an XCFramework — this step needs to run
on macOS since it compiles native code for arm64.

## Test assets

Sample RAW files are intentionally not committed (they're large and mostly
redistributable-but-not-ours). `TestAssets/README.md` lists exactly which
files to pull from raw.pixls.us for the CI matrix, plus where to drop your
own D750/A7 III samples.

## Contributing

Not yet open for contributions — still pre-Phase-1.
