# Security and Privacy

## No network

Latent makes no network requests. There is no telemetry, analytics, crash reporting or update check. The app bundle has no network entitlement, so the operating system enforces this: the process cannot open a socket. The Help window shows pages that ship inside the app; a web link in them opens in your browser, not in Latent.

## Sandbox and hardened runtime

The app runs in the App Sandbox with the hardened runtime, signed ad hoc. It can reach only folders you choose in an open panel, folders you add to the sidebar's favourites (by Add Folder… or by dragging them in) and everything inside those, plus its own container under `~/Library/Containers/com.latent.app`. Each is remembered between launches by a security-scoped bookmark; removing a favourite forgets its bookmark. No Apple developer account is involved; the sandbox is enforced from the signature regardless.

## Isolated raw decoding

Raw files are parsed by LibRaw, a large C++ library that processes files you did not create. Latent runs it in a separate XPC service, `LatentRawDecoder.xpc`, sandboxed with no file access and no network. The app hands it an open file descriptor per file and receives pixels back. A crafted file that exploits the decoder gets a process that can do nothing, and the app shows an error instead of crashing.

The service answers one more question, for exports: the photo's own metadata. It reads that with ImageIO and returns two size-capped property lists of plain values. The app checks their shape and rebuilds any XMP through ImageIO's tag interface, so it never parses an XMP document the service produced.

## Location in exports

Exports carry the photo's own metadata by default, and that includes the **GPS position** your camera or phone recorded, along with artist, copyright, camera and lens details, keywords and rating. To share a photo without them, turn off **Include camera metadata, location, keywords and rating** in the export sheet (and save that as a preset if you share often). Export open image… in the left panel has no such switch and always writes the metadata, location included; use the export sheet when that matters. See [Export](Export).

## Parsers

XMP sidecars are parsed with external entities disabled and a size cap. Folder scans never follow symlinks. Export file names are sanitised. Database access is parameterised throughout. Help pages may link only to other pages, web pages and mail addresses; any other link is refused.

## Debug-only switches

Environment variables that change how the app works on the inside, such as `LATENT_RAW_INPROCESS=1` (decode in the app's own process) and the snapshot harness's `LATENT_SNAPSHOT_*`, are compiled only into debug builds. A release build, including every bundle `scripts/make_app.sh` makes, ignores them and doesn't contain their code, so nobody can tell an installed Latent to parse raw files outside the isolated decoder. `LATENT_ML_COMPUTE`, which only chooses the processor Core ML models run on, is read by every build.

## Supply chain

LibRaw is pinned by commit hash and refused if the tag moves. The one Swift dependency is pinned to an exact version. Model weights are pinned by repository revision and SHA-256 in the conversion scripts. Dependabot watches the Actions and Python dependencies.

## What is written, and where

- `_latent/` inside each photo folder: catalog, sidecars, thumbnails, and a set-aside `catalog.damaged-<date>.sqlite` if a database was ever found damaged. Nothing else in your folders is touched.
- The app container: settings, bookmarks for the last folder, export folders and favourites, compiled models, saved presets.
- Exports: only where you choose, written under a temporary name and then moved into place; metadata, including location, can be stripped.
- The unified log receives failure messages with file names marked private.
