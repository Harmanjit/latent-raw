# Develop

The right panel holds the modules in pipeline order. All controls are live at full quality. Double-click a slider to reset it. ⌘Z and ⌘⇧Z undo and redo; `\` shows the unedited image.

## Modules

**White Balance.** Temperature and tint, starting from the camera's own setting. As Shot returns to it.

**Tone.** Exposure in stops, contrast and mid-grey for the sigmoid tone curve, and Auto (⌘U), which sets exposure from the image's own histogram with a guard against blowing highlights. Highlight Reconstruction pulls clipped channels back toward neutral before the colour matrix.

**Presence.** Texture (fine local contrast, 1–4 px), Clarity (mid-scale, midtone-weighted), Dehaze (dark-channel prior in linear light; negative adds haze) and Vibrance (saturation that favours muted colours and spares skin).

**Crop and Straighten.** R opens the tool: drag inside to move, edges and corners to resize, with aspect presets that follow the image orientation. Straighten runs −45° to 45° and the crop shrinks to avoid empty corners, growing back as the angle returns. Perspective offers vertical and horizontal keystone. The crop is a sampling map, not a pipeline stage, so it costs no re-render.

**Spot Removal.** H arms the tool. Click a spot to place a patch with an automatic source; drag from the click to choose the source; drag either circle to move it; Backspace deletes. Heal matches the rim of the source to the rim of the target so the seam disappears; Clone copies exactly. Up to 32 patches.

**Local Adjustments.** Masks with exposure, contrast, saturation and warmth applied inside them: linear gradient, radial, brush, whole image, and two AI masks. *Click to Select* uses Segment Anything 2.1: click the subject, option-click to exclude. *Select by Class* uses SegFormer to pick sky, people, vegetation, water, buildings, ground, mountains, animals or vehicles. Any mask can be refined by a luminance or hue range and inverted. Model masks are regenerated from the image when needed rather than stored.

**Tone Curve.** A point curve on the display-referred image.

**HSL / Colour.** Hue, saturation and luminance for eight hue bands.

**Split Toning.** Shadow and highlight tints with a balance.

**Lens Corrections.** Distortion, chromatic aberration and vignetting from a bundled Lensfun profile matched to the camera and lens, each switchable, plus manual distortion and vignetting and a purple/green defringe.

**Detail.** Demosaic algorithm (RCD or bilinear), sharpening (amount, radius, threshold on perceptual luminance), and bilateral noise reduction in camera space.

**AI Noise Reduction.** NAFNet, trained on real sensor noise, run once per image on the GPU (about 11 s for 24 MP) and then blended at any strength instantly. It runs in camera space before colour, so white balance and every later module see clean data. Exports run it again; thumbnails skip it.

**Soft Proof.** Preview the image as sRGB or Display P3, or through an ICC profile, with a gamut warning that paints out-of-range colours grey.

## Presets and clipboard

Presets and Clipboard holds a menu of presets, five built in and any you save, and a checklist of which module groups copy and paste carry. ⌘⇧C copies the current edit; ⌘⇧V pastes into the open image or onto the whole Library selection. Presets are JSON files in Application Support and can be shared.

## History and snapshots

The left panel lists every settled edit newest first; click one to jump, ⌘Z and ⌘⇧Z step. Thirty steps are kept per image, in the sidecar as well as the catalog. Snapshots are named copies of the whole edit; restoring one is itself a history step.

## The viewport

Pinch or option-scroll to zoom, scroll or drag to pan, double-click to toggle fit and 100%. ⌘0 fits, ⌘1 is 100%, ⌘= and ⌘- step. The image surround grey is set in Preferences. On an HDR display, highlights above paper white are shown using the display's headroom, with a toggle to preview the SDR result.
