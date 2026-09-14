# Limitations

An honest list. Some are design decisions, some are unfinished work, some are the price of targeting one platform.

## Cameras and files

- **Bayer sensors only.** Fujifilm X-Trans, Sigma Foveon, monochrome and four-colour sensors are read for metadata but do not render.
- **Tested on one camera.** The only raw file in the test suite is a Nikon D750 NEF. LibRaw supports hundreds of cameras and the pipeline is generic, but colour and exposure on other cameras have not been checked against a reference.
- **Camera matrix colour only.** Colour comes from the camera's characterisation matrix. There are no camera-matching profiles, so the default rendering will not match the in-camera JPEG look.
- **Lens profiles** cover the bundled Lensfun subset; a lens the matcher cannot identify gets manual sliders only.
- **No DNG export, no HDR gain-map export.** Exports are SDR JPEG, HEIC, PNG or TIFF.
- **HDR display** has been verified on a MacBook Pro's XDR screen, and sRGB and Display P3 output on the same machine. Other HDR displays are untested.

## Platform and distribution

- **Apple Silicon and macOS 15 only.** No Intel Macs, no Windows, no Linux, by design.
- **Not notarised.** Without an Apple developer account, every other Mac shows the Gatekeeper dialog once.
- **Large.** The app is about 215 MB, of which 198 MB are the three bundled machine-learning models.
- **Neural Engine off by default** because its compiler hangs on some macOS 15 builds. The GPU is fast enough.

## Workflow

- **No import from memory cards, no tethering, no folder watching.** Copy files yourself, then open the folder.
- **No collections, no search across folders.** Each folder is its own world.
- **No printing, no video, no plugins.**
- **Metadata editing** is limited to rating, label, flag and keywords. Title, caption and copyright are not editable.
- **Undo works in Develop, not in the Library.**
- **Sliders have no numeric entry.**

## Editing

- **Masks are placed once.** A gradient or radial cannot be dragged into a new position after placement; delete and redraw.
- **Class masks are soft-edged** at the model's native 128-pixel resolution.
- **Spot healing matches rims, not gradients.** It is invisible on sky and skin and can show a faint boundary on strong texture.
- **AI denoise is a single model at one quality.** A larger variant exists in the conversion script but is not offered in the app.
- **Thumbnails ignore AI denoise**, since running the network in the background for every thumbnail would be too slow.
- **Limits:** 8 local adjustments and 32 spot patches per image, 30 history steps.
- **No process-version upgrade flow.** If a rendering algorithm changes in a future version, existing edits will render differently rather than being pinned to the old behaviour.

## Development

- GPU tests need a sample raw that is not in the repository, so a clean clone runs only the CPU tests.
- The editor model in the app target has grown large and would benefit from a split before the next big feature.
