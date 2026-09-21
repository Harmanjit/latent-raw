# Limitations

An honest list. Some are design decisions, some are unfinished work, some are the price of targeting one platform.

## Cameras and files

- **Bayer sensors only.** Fujifilm X-Trans, Sigma Foveon, monochrome and four-colour sensors are read for metadata but do not render.
- **Colour checked on one camera.** The golden-image tests, which compare renders with reference images, use a Nikon D750 NEF. The Photo Merge tests also read raws from a Canon EOS 5D Mark II and a Nikon D200, but don't check their colour. LibRaw supports hundreds of cameras and the pipeline is generic, but colour and exposure on other cameras have not been checked against a reference.
- **Camera matrix colour only.** Colour comes from the camera's characterisation matrix. There are no camera-matching profiles, so the default rendering will not match the in-camera JPEG look.
- **Lens profiles** cover the bundled Lensfun subset; a lens the matcher cannot identify gets manual sliders only.
- **No DNG export.** JPEG and HEIC can carry an optional HDR gain map, but the main image is always SDR, and the map's headroom is fixed at two stops. PNG and TIFF are SDR only.
- **Optional interop XMP beside the image is not implemented.** Latent's sidecars live in `_latent/xmp/`, where Lightroom and darktable do not look.
- **HDR display** has been verified on a MacBook Pro's XDR screen, and sRGB and Display P3 output on the same machine. Other HDR displays are untested.

## Platform and distribution

- **Apple Silicon and macOS 15 only.** No Intel Macs, no Windows, no Linux, by design.
- **Not notarised.** Without an Apple developer account, every other Mac shows the Gatekeeper dialog once.
- **Large.** The four bundled machine-learning models alone are 311 MB, 103 MB of it the BiRefNet Lite subject model. Models added from disk take their own space: up to 457 MB each for the largest in the catalogue, and a second or more to load; on an 8 GB Mac the bundled ones are the safer choice.
- **Neural Engine off by default** because its compiler hangs on some macOS 15 builds. The GPU is fast enough.

## Workflow

- **No import from memory cards, no tethering, no folder watching.** Copy files yourself, then open the folder. There is no Refresh command either; open the folder again to re-scan it. Latent re-reads the open folder by itself only after its own moves, copies and renames.
- **Folders on read-only volumes can't be opened,** because the catalog lives inside the folder. A locked memory card has to be copied first.
- **No collections, no search across folders.** Each folder is its own catalog; the sidebar moves between folders but doesn't search or combine them.
- **The sandbox limits the sidebar** to folders inside a favourite. Anything else needs Open Folder, or adding a folder that contains it.
- **Subfolder include/independent choices are not stored in sidecars.** They live only in the catalog database, so rebuilding the catalog, including the automatic rebuild of a damaged database, resets them and asks again. Changing the choice moves no existing sidecars or thumbnails.
- **No video, no plugins.**
- **Metadata editing** is limited to rating, flag and keywords. Colour labels, title, caption and copyright can't be set. Keywords apply to one image at a time, not to a multiple selection.
- **Finder tags are read, never written,** and a tag changed in Finder while the folder is open shows only when the folder is opened again.
- **Undo in the Library has edges.** It covers ratings, flags, rotation, keywords, pasted settings and presets, Custom sort rearrangements, and moves, copies and renames. Exports can't be undone. Opening another folder clears it, except for moves, copies and renames. A move, copy or rename can't be undone while an export, print, contact sheet or Photo Merge is running.
- **Rename is one image at a time.** There is no batch rename.
- **Rename, Move and Copy work only in the Library grid,** and not while an export, print, contact sheet or Photo Merge is running.
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

- **HDR, Panorama and HDR Panorama.** HDR Panorama (⌃⇧M) is **experimental**: it works and is tested end to end, but only against synthetic sweeps and against overlapping windows cut out of a real bracket, because no real HDR panorama exists to check it with. A real bracketed sweep — changing light, parallax across positions, brackets that drift — has never been tried. Focus stacking isn't planned (Lightroom doesn't have it either).
- **Panoramas are one row.** One sweep, left to right or right to left. Several rows stacked into a grid, and full 360° panoramas that join back to their start, aren't built.
- **Parallax.** When the camera moves sideways instead of turning on the spot, near things shift against far things and no stitch lines both up: edges close to the camera can look doubled. The dialog warns when the photos only match to several pixels.
- **A panorama too big to edit is made smaller, never refused.** The dialog says what it would have been, what it will be and why (memory, or the largest picture the graphics processor can hold), and waits for you to agree. The limit is this Mac's: the same sweep merges larger on a bigger machine.
- **A photo that can't be joined is left out** and named in a warning; the panorama is made from the rest. The usual cause is too little overlap — aim for about 30%.
- **Auto Align moves whole frames.** It lines up handheld brackets, but near and far things that shifted against each other (parallax) still show slightly doubled edges. A frame it can't align is merged unaligned if it looks within a pixel or so, or left out of the merge otherwise; the dialog says which.
- **Deghost compares brightness and colour,** and takes each moving area whole from one frame, so something that moved in front of an equally bright background is caught. What it can't fix is parallax, and deghosted areas come from a single frame, with its noise. The dialog's preview and its deghost overlay are small, about 1,000 pixels across, and past a long edge of about 6,100 pixels (roughly 25 MP and up) the overlay is a rougher guide to what the merge takes from one frame.
- **Raw files from Bayer sensors only,** all from one camera at one size and orientation. An already-merged photo can't be merged to HDR again, though a panorama will stitch HDR merges (which is how HDR Panorama works). An HDR merge takes at most 9 photos, or 5 on an 8 GB Mac; a panorama has no frame limit and is made smaller instead of refused.
- **A panorama's lens corrections need a lens Latent can identify.** Distortion, vignetting and chromatic aberration are baked into the stitch, but only when the bundled Lensfun subset matches the lens. When it doesn't, the panorama is stitched uncorrected, nothing warns about it, and because the result is recorded as already corrected, Develop won't correct it afterwards either.
- **Edits on the bracket's photos aren't used.** The merge reads the raw files; the result starts unedited at the reference photo's exposure.
- **The merge options are few, and differ by kind.** HDR offers Auto Align, Deghost (with Show Deghost Overlay, which isn't remembered) and Auto Settings, plus a reference photo you pick that lasts for that merge only — HDR Merge Without Dialog always chooses the reference automatically. Panorama offers Projection, Auto Crop and Auto Settings. HDR Panorama offers both sets. There is nothing else to tune.
- **No re-merge.** The result records which photos made it, but Latent can't merge them again from that record, and a merge can't be undone except by deleting its DNG in Finder.
- **Merged DNGs are large and uncompressed,** about 6 bytes per pixel (roughly 145 MB for 24 MP). Merges write DNG; export still doesn't.
- **A merged DNG copied in from Finder without its sidecar** is catalogued as a plain DNG; the record of what made it stays inside the file, unread.

## Editing

- **Masks are placed once.** A gradient or radial cannot be dragged into a new position after placement; delete and redraw.
- **Class masks are soft-edged** at the model's native 128-pixel resolution.
- **Spot healing copies the source's texture.** Tone and colour are matched to the surroundings, but a source with coarser or different texture than the target still shows; drag to pick a better source. A brush stroke heals from one source beside it along its whole length, so an edge running along the source, such as a horizon, shows as a line. A stroke keeps up to 256 points; a longer scribble is simplified.
- **Red-eye Auto can miss small faces.** It looks for faces on a render about 1600 px across, so faces in a large group shot may not be found; add those spots by hand. Only red pupils change: an animal's green, yellow or white eyeshine is left as it is.
- **AI denoise is a single model at one quality.** A larger variant exists in the conversion script but is not offered in the app, and the Models list in Settings has no row for the denoiser.
- **`latent-cli` renders and thumbnails leave out what needs a model:** model masks and Touch-up's smoothing, whitening and eyes. Dust spots and blemishes are heal patches and render everywhere. Exports, prints, contact sheets and slides carry everything.
- **Sensor dust has been tested on synthetic dust** and checked on only a few real photos. It looks for round dark shadows: foliage, birds and stars can be taken for dust, and faint spots at wide apertures can be missed; the rings are there to correct it. A dust map is keyed by the camera's make and model, so two bodies of the same model share one.
- **Touch-up works on faces at least 64 pixels wide** on a render about 4000 pixels across, seen more or less straight on; a turned head, glasses or hair across the face can defeat the landmarks. Smoothing acts on brightness only, so colour blotches stay; the teeth gate can catch a tongue or a lip highlight. Survey panes rebuild the regions when they open, which costs a moment per pane.
- **Subject masks with BiRefNet take about half a second each** on an M4 and longer on an M1, so a Survey of four such photos takes a few seconds to settle. Added models run on the GPU only.
- **Thumbnails ignore AI denoise**, since running the network in the background for every thumbnail would be too slow.
- **Limits:** 8 local adjustments, 32 spot patches (a brush stroke counts as one), 32 red-eye spots, 200 dust spots, 16 faces and 64 blemishes per image, 30 history steps.
- **No process-version pinning.** When a rendering algorithm changes, existing edits render differently rather than being pinned to the old behaviour. This has already happened once: spot healing changed in September 2026, so heal patches made before then now render with the new method.

## Accessibility

- Grid cells have no VoiceOver action to open an image; they do have one per rating.
- The waveform and vectorscope are named for VoiceOver but not described.
- Compare has no focus highlight.
- Placing patches, brush strokes, red-eye spots, dust spots, blemishes and masks by hand, moving the crop, arranging a Custom sort and the magnifier need a pointer; Find Spots, Find Faces and Find Blemishes place theirs without one. See [Accessibility](Accessibility).

## Development

- **Golden-image tests don't cover AI noise reduction** or gain maps. Every other stage of the render is pinned against reference images, the touch-up stage with a fixed set of face regions; Core ML and Vision output varies between compute units and macOS versions, so neural denoise, the model masks and the face landmarks have only unit tests, and the dust detector is tested on synthetic scenes. What the magnifier and the slideshow draw on screen, and printed pages, aren't pictured by any test either.
- **Red-eye's thresholds are written twice,** in `RedEye.metal` and in `RedEyeTuning` (`RedEye.swift`), which Auto uses to decide an eye is red. They are kept in step by hand; no test ties them.
- Tests that render a raw need a sample that is not in the repository. `scripts/fetch_test_assets.sh` downloads the public-domain one the golden-image tests use, and with `--merge` the freely licensed brackets the Photo Merge tests use (about 390 MB), which skip without them; a few tests use the author's own samples and skip everywhere else, CI included.
- **`LATENT_RAW_INPROCESS=1` only works in debug builds.** `scripts/make_app.sh` always builds release, so no bundle it makes can decode in process.
