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

- **No import from memory cards, no tethering, no folder watching.** Copy files yourself, then open the folder. There is no Refresh command either; open the folder again to re-scan it.
- **Folders on read-only volumes can't be opened,** because the catalog lives inside the folder. A locked memory card has to be copied first.
- **No collections, no search across folders.** Each folder is its own catalog; the sidebar moves between folders but doesn't search or combine them.
- **The sandbox limits the sidebar** to folders inside a favourite. Anything else needs Open Folder, or adding a folder that contains it.
- **Subfolder include/independent choices are not stored in sidecars.** They live only in the catalog database, so rebuilding the catalog, including the automatic rebuild of a damaged database, resets them and asks again. Changing the choice moves no existing sidecars or thumbnails.
- **No printing, no video, no plugins.**
- **Metadata editing** is limited to rating, label, flag and keywords. Title, caption and copyright are not editable. Keywords apply to one image at a time, not to a multiple selection.
- **Undo works in Develop, not in the Library.**
- **Typed values aren't on every slider.** Temperature, Highlights, Shadows, Whites and Blacks, HSL, Split Toning and export quality show their value but can't be typed into.
- **Export open image… is always full size in sRGB.** Use the export sheet for anything else.
- **Compare's Sync isn't remembered;** it is on again at every launch.
- **Showing and hiding the sidebar and filmstrip has no keyboard shortcut or menu item.** The filmstrip has its film button in the status bar.

## Editing

- **Masks are placed once.** A gradient or radial cannot be dragged into a new position after placement; delete and redraw.
- **Class masks are soft-edged** at the model's native 128-pixel resolution.
- **Spot healing copies the source's texture.** Tone and colour are matched to the surroundings, but a source with coarser or different texture than the target still shows; drag to pick a better source.
- **AI denoise is a single model at one quality.** A larger variant exists in the conversion script but is not offered in the app.
- **Thumbnails ignore AI denoise**, since running the network in the background for every thumbnail would be too slow.
- **Limits:** 8 local adjustments and 32 spot patches per image, 30 history steps.
- **No process-version pinning.** When a rendering algorithm changes, existing edits render differently rather than being pinned to the old behaviour. This has already happened once: spot healing changed in September 2026, so heal patches made before then now render with the new method.

## Accessibility

- Grid cells have no VoiceOver action to open an image or change its rating.
- The waveform and vectorscope are named for VoiceOver but not described.
- Compare has no focus highlight.
- Placing patches and masks and moving the crop need a pointer. See [Accessibility](Accessibility).

## Development

- **Golden-image tests don't cover AI noise reduction** or gain maps. Every other stage of the render is pinned against reference images; Core ML output varies between compute units, so neural denoise has only unit tests.
- Tests that render a raw need a sample that is not in the repository. `scripts/fetch_test_assets.sh` downloads the public-domain one the golden-image tests use; a few tests use the author's own samples and skip everywhere else, CI included.
- **`LATENT_RAW_INPROCESS=1` only works in debug builds.** `scripts/make_app.sh` always builds release, so no bundle it makes can decode in process.
