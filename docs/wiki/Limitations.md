# Limitations

An honest list. Some are design decisions, some are unfinished work, some are the price of targeting one platform.

## Cameras and files

- **Bayer sensors only.** Fujifilm X-Trans, Sigma Foveon, monochrome and four-colour sensors are read for metadata but do not render.
- **Tested on one camera.** The only raw file in the test suite is a Nikon D750 NEF. LibRaw supports hundreds of cameras and the pipeline is generic, but colour and exposure on other cameras have not been checked against a reference.
- **Camera matrix colour only.** Colour comes from the camera's characterisation matrix. There are no camera-matching profiles, so the default rendering will not match the in-camera JPEG look.
- **Lens profiles** cover the bundled Lensfun subset; a lens the matcher cannot identify gets manual sliders only.
- **No DNG export.** JPEG and HEIC can carry an optional HDR gain map, but the main image is always SDR, and the map's headroom is fixed at two stops. PNG and TIFF are SDR only.
- **Optional interop XMP beside the image is not implemented.** Latent's sidecars live in `_latent/xmp/`, where Lightroom and darktable do not look.
- **HDR display** has been verified on a MacBook Pro's XDR screen, and sRGB and Display P3 output on the same machine. Other HDR displays are untested.

## Platform and distribution

- **Apple Silicon and macOS 15 only.** No Intel Macs, no Windows, no Linux, by design.
- **Not notarised.** Without an Apple developer account, every other Mac shows the Gatekeeper dialog once.
- **Large.** The three bundled machine-learning models alone are 198 MB.
- **Neural Engine off by default** because its compiler hangs on some macOS 15 builds. The GPU is fast enough.

## Workflow

- **No import from memory cards, no tethering, no folder watching.** Copy files yourself, then open the folder. There is no Refresh command either; open the folder again to re-scan it. Latent re-reads the open folder by itself only after its own moves, copies and renames.
- **Folders on read-only volumes can't be opened,** because the catalog lives inside the folder. A locked memory card has to be copied first.
- **No collections, no search across folders.** Each folder is its own catalog; the sidebar moves between folders but doesn't search or combine them.
- **The sandbox limits the sidebar** to folders inside a favourite. Anything else needs Open Folder, or adding a folder that contains it.
- **Subfolder include/independent choices are not stored in sidecars.** They live only in the catalog database, so rebuilding the catalog, including the automatic rebuild of a damaged database, resets them and asks again. Changing the choice moves no existing sidecars or thumbnails.
- **No video, no plugins.**
- **Metadata editing** is limited to rating, label, flag and keywords. Title, caption and copyright are not editable. Keywords apply to one image at a time, not to a multiple selection.
- **Finder tags are read, never written,** and a tag changed in Finder while the folder is open shows only when the folder is opened again.
- **Undo in the Library has edges.** It covers ratings, flags, rotation, keywords, pasted settings and presets, Custom sort rearrangements, and moves, copies and renames. Exports can't be undone. Opening another folder clears it, except for moves, copies and renames. A move, copy or rename can't be undone while an export is running.
- **Rename is one image at a time.** There is no batch rename.
- **Rename, Move and Copy work only in the Library grid,** and not while an export is running.
- **A move takes only the raw file.** A JPEG shot alongside it (RAW+JPEG) and an `.xmp` sidecar another application put beside the raw stay where they were.
- **A move to another disk copies, then deletes the original.** If Latent crashes or is force-quit during a long copy, a hidden `.latent-transfer-…` file can be left in the destination. The original is still in place, and the hidden file can be deleted.
- **Arranging the Custom order needs dragging.** There are no keys for it.
- **Typed values aren't on every slider.** Temperature, Highlights, Shadows, Whites and Blacks, HSL, Split Toning and export quality show their value but can't be typed into.
- **Export open image… is always full size in sRGB.** Use the export sheet for anything else.
- **Compare's and Survey's Sync aren't remembered;** they are on again at every launch.
- **Survey shows at most four images** and has no before/after view. It is for looking; to edit, open an image in Develop.
- **The Loupe on a second display is for looking only.** It shows one image at fit; zoom, pan and tools stay in the main window.
- **Edit in External Editor is a one-way hand-off.** It writes a 16-bit Display P3 TIFF (no Adobe RGB or ProPhoto), and the TIFF the other application saves doesn't come back into the Library, since Latent catalogs raw files only.
- **Slideshows are SDR,** even on an HDR screen, and leave out AI noise reduction so each slide is ready in time. The edit's other noise reduction still applies.
- **The watermark is for exports.** Prints, contact sheets and the TIFF for an external editor don't carry it, and it is one line of text; there is no logo or image watermark.
- **A JPEG or PNG contact sheet is one picture,** at most 8192 px a side, holding every photo, so a large selection gets small cells. A PDF can have as many pages as it needs.
- **The print panel's preview is drawn from thumbnails.** It shows the layout; the photos themselves are rendered for the printer only when you print.
- **Showing and hiding the sidebar and filmstrip has no keyboard shortcut or menu item.** The filmstrip has its film button in the status bar.

## Photo Merge

- **HDR only.** Panorama and HDR Panorama merges aren't there yet, and neither is focus stacking (Lightroom doesn't have it either).
- **Auto Align moves whole frames.** It lines up handheld brackets, but near and far things that shifted against each other (parallax) still show slightly doubled edges. A frame it can't align is merged unaligned if it looks within a pixel or so, or left out of the merge otherwise; the dialog says which.
- **Deghost compares brightness, not colour.** Something that moved in front of an equally bright background can go unnoticed and look doubled or semi-transparent, and deghosted areas come from a single frame, with its noise. There is no overlay showing what Deghost masked, and no preview of the merge before it runs.
- **Raw files from Bayer sensors only,** all from one camera at one size and orientation; merged photos can't be merged again. On 8 GB Macs a merge takes at most 5 photos.
- **Edits on the bracket's photos aren't used.** The merge reads the raw files; the result starts unedited at the reference photo's exposure.
- **The reference photo is chosen automatically;** the only merge options are Auto Align and Deghost.
- **No re-merge.** The result records which photos made it, but Latent can't merge them again from that record, and a merge can't be undone except by deleting its DNG in Finder.
- **Merged DNGs are large and uncompressed,** about 6 bytes per pixel (roughly 145 MB for 24 MP). Merges write DNG; export still doesn't.
- **A merged DNG copied in from Finder without its sidecar** is catalogued as a plain DNG; the record of what made it stays inside the file, unread.

## Editing

- **Masks are placed once.** A gradient or radial cannot be dragged into a new position after placement; delete and redraw.
- **Class masks are soft-edged** at the model's native 128-pixel resolution.
- **Spot healing copies the source's texture.** Tone and colour are matched to the surroundings, but a source with coarser or different texture than the target still shows; drag to pick a better source. A brush stroke heals from one source beside it along its whole length, so an edge running along the source, such as a horizon, shows as a line. A stroke keeps up to 256 points; a longer scribble is simplified.
- **Red-eye Auto can miss small faces.** It looks for faces on a render about 1600 px across, so faces in a large group shot may not be found; add those spots by hand. Only red pupils change: an animal's green, yellow or white eyeshine is left as it is.
- **AI denoise is a single model at one quality.** A larger variant exists in the conversion script but is not offered in the app.
- **Thumbnails ignore AI denoise**, since running the network in the background for every thumbnail would be too slow.
- **Limits:** 8 local adjustments, 32 spot patches (a brush stroke counts as one) and 32 red-eye spots per image, 30 history steps.
- **No process-version pinning.** When a rendering algorithm changes, existing edits render differently rather than being pinned to the old behaviour. This has already happened once: spot healing changed in September 2026, so heal patches made before then now render with the new method.

## Accessibility

- Grid cells have no VoiceOver action to open an image; they do have one per rating.
- The waveform and vectorscope are named for VoiceOver but not described.
- Compare has no focus highlight.
- Placing patches, brush strokes, red-eye spots and masks, moving the crop, arranging a Custom sort and the magnifier need a pointer. See [Accessibility](Accessibility).

## Development

- **Golden-image tests don't cover AI noise reduction** or gain maps. Every other stage of the render is pinned against reference images; Core ML output varies between compute units, so neural denoise has only unit tests. What the magnifier and the slideshow draw on screen, and printed pages, aren't pictured by any test either.
- **Red-eye's thresholds are written twice,** in `RedEye.metal` and in `RedEyeTuning` (`RedEye.swift`), which Auto uses to decide an eye is red. They are kept in step by hand; no test ties them.
- Tests that render a raw need a sample that is not in the repository. `scripts/fetch_test_assets.sh` downloads the public-domain one the golden-image tests use; a few tests use the author's own samples and skip everywhere else, CI included.
- **`LATENT_RAW_INPROCESS=1` only works in debug builds.** `scripts/make_app.sh` always builds release, so no bundle it makes can decode in process.
