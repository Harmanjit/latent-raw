# Security and Privacy

## No network

Latent makes no network requests. There is no telemetry, analytics, crash reporting or update check. The app bundle has no network entitlement, so the operating system enforces this: the process cannot open a socket. The Help window shows pages that ship inside the app; a web link in them opens in your browser, not in Latent. Red-eye's Auto button finds faces with Apple's Vision framework on your Mac, as the AI masks run their models there.

## Sandbox and hardened runtime

The app runs in the App Sandbox with the hardened runtime, signed ad hoc. It can reach only folders and files you choose in an open panel, folders you add to the sidebar's favourites (by Add Folder… or by dragging them in) and everything inside those, plus its own container under `~/Library/Containers/com.latent.app`. Each is remembered between launches by a security-scoped bookmark; removing a favourite forgets its bookmark. The same kind of bookmark remembers the last five folders you moved or copied images to, the folder and applications chosen for Edit in External Editor, and the songs added to the slideshow. No Apple developer account is involved; the sandbox is enforced from the signature regardless.

Besides files and bookmarks, the app has one entitlement: `com.apple.security.print`, without which the sandbox refuses to let File > Print… reach the printing system. It grants nothing else, no network and no files.

## Isolated raw decoding

Raw files are parsed by LibRaw, a large C++ library that processes files you did not create. Latent runs it in a separate XPC service, `LatentRawDecoder.xpc`, sandboxed with no file access and no network. The app hands it an open file descriptor per file and receives pixels back. A crafted file that exploits the decoder gets a process that can do nothing, and the app shows an error instead of crashing.

The service answers one more question, for exports: the photo's own metadata. It reads that with ImageIO and returns two size-capped property lists of plain values. The app checks their shape and rebuilds any XMP through ImageIO's tag interface, so it never parses an XMP document the service produced.

## Location in exports

Exports carry the photo's own metadata by default: artist, copyright, camera and lens details, capture time, keywords and rating. Where the photo was taken is left out unless you turn on **Include location**, in the export sheet and, for Export open image…, in the left panel's Export section. Left out means the **GPS position** your camera or phone recorded, the place names (city, sublocation, state or province, country, and the locations shown or created), and the camera body's and lens's **serial numbers**, which tie every photo to one camera as surely as a position ties it to a place. Artist, copyright and the camera owner's name stay, as credits. Turn off **Include camera metadata** to write none of it. Presets saved by earlier versions keep location off. See [Export](Export).

## Your files

Latent never changes the contents of a raw file. It moves, copies or renames one only when you ask, with Move to Folder, Copy to Folder, a drop on a sidebar folder or Rename, and only into folders the sandbox already lets it reach: the open folder, a favourite, a folder you pick in the panel, or a recent destination. It never writes over a file: a name that is taken gets a number. Undoing a copy puts the copy in the Trash rather than deleting it, and only if it is still the file Latent made.

Finder tags are read from each file's `com.apple.metadata:_kMDItemUserTags` attribute and never written. Dragging thumbnails out gives the other application the original files' locations; Finder makes copies. Edit in External Editor writes a TIFF to the folder chosen for it and asks macOS to open it in the application chosen; that application then does with it whatever it does, outside Latent's sandbox. The TIFF's metadata and location follow Export open image…'s switches, so location is left out unless you turned it on there. Prints and contact sheets carry no metadata, only the captions you choose.

## Parsers

XMP sidecars are parsed with external entities disabled and a size cap. Folder scans never follow symlinks. Export file names are sanitised. Database access is parameterised throughout. Help pages may link only to other pages, web pages and mail addresses; any other link is refused.

## Debug-only switches

Environment variables that change how the app works on the inside, such as `LATENT_RAW_INPROCESS=1` (decode in the app's own process) and the snapshot harness's `LATENT_SNAPSHOT_*`, are compiled only into debug builds. A release build, including every bundle `scripts/make_app.sh` makes, ignores them and doesn't contain their code, so nobody can tell an installed Latent to parse raw files outside the isolated decoder. `LATENT_ML_COMPUTE`, which only chooses the processor Core ML models run on, is read by every build.

## Supply chain

LibRaw is pinned by commit hash and refused if the tag moves. The one Swift dependency is pinned to an exact version. The conversion scripts pin NAFNet's weights by repository revision and SHA-256, and SegFormer's by repository revision only. The Segment Anything packages are Apple's own Core ML conversion, committed to the repository with no script to fetch or check them. Dependabot watches the Actions and Python dependencies.

## What is written, and where

- `_latent/` inside each photo folder: catalog, sidecars, thumbnails, `custom-order.json` once you arrange a Custom sort, and a set-aside `catalog.damaged-<date>.sqlite` if a database was ever found damaged. Nothing else in your folders is touched unless you move, copy or rename images.
- The app container: settings, bookmarks for the last folder, export folders, favourites, recent move and copy destinations, the external editor's folder and applications and slideshow songs, compiled models, saved presets.
- Exports, contact sheets and TIFFs for an external editor: only where you choose, written under a temporary name and then moved into place; location and serial numbers only when asked for, and metadata can be stripped altogether.
- The unified log receives failure messages with file names marked private.
