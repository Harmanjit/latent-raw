# Develop

The right panel holds the modules in pipeline order. All controls are live at full quality. Double-click a slider to reset it. ⌘Z and ⇧⌘Z undo and redo; `\` shows the unedited image. The Develop menu holds Auto Adjust, the crop and spot tools, new masks and brush size; the Edit menu holds undo, redo and Copy and Paste Settings.

**Typed values.** Most sliders show their value as a number you can click: type a value and press Return or Tab to apply it, or Escape to cancel. ↑ and ↓ step it by the last digit shown, ⇧↑ and ⇧↓ by ten steps. The unit can be typed or left out, and the value is clamped to the slider's range. A typed value is an ordinary edit and lands in history like a drag. Temperature, the four tone ranges, HSL, Split Toning and export quality don't take typed values yet.

## Modules

**White Balance.** Temperature and tint, starting from the camera's own setting. As Shot returns to it.

**Tone.** Exposure in stops, contrast and mid-grey for the sigmoid tone curve. **Highlights, Shadows, Whites and Blacks** each brighten or darken one band of tones without moving mid grey. They change exposure per pixel by its brightness, so colours keep their hue, there are no halos, and tones never swap order. **Auto** (⌘U) sets exposure, contrast and white balance from the image itself, backing exposure off if it would blow the brightest highlights. On an HDR screen, **HDR display** shows highlights above paper white using the screen's headroom.

**Presence.** Texture (fine local contrast, 1–4 px), Clarity (mid-scale, midtone-weighted), Dehaze (dark-channel prior in linear light; negative adds haze) and Vibrance (saturation that favours muted colours and spares skin).

**Crop and Straighten.** R opens the tool: drag inside to move, edges and corners to resize, with aspect presets that follow the image orientation. Straighten runs −45° to 45° and the crop shrinks to avoid empty corners, growing back as the angle returns. Perspective offers vertical and horizontal keystone. The crop is a sampling map, not a pipeline stage, so it costs no re-render.

**Spot Removal.** H arms the tool. Click a spot to place a patch with an automatic source; drag from the click to choose the source; drag either circle to move it; ⌫ deletes the selected patch. [ and ] make the next patch, and the selected one, smaller or larger. **Heal** copies the source's texture and takes tone and colour from what surrounds the target on every side, so a gradient or an edge running through the patch carries on. **Clone** copies exactly. Patches apply in order, each seeing the ones before, so a patch next to an earlier one matches it. Up to 32 patches.

**Highlight Reconstruction.** Recovery and threshold pull clipped channels back toward neutral before the colour matrix. This repairs clipped colour; it doesn't move tones, which is what Highlights and Whites do.

**Local Adjustments.** Masks with exposure, contrast, saturation and warmth applied inside them: linear gradient, radial, brush, whole image, and two AI masks. The brush has size, feather and flow; [ and ] change its size while painting or erasing. *Click to Select* uses Segment Anything 2.1: click the subject, option-click to exclude. *Select by Class* uses SegFormer to pick sky, people, vegetation, water, buildings, ground, mountains, animals or vehicles. Any mask can be refined by a luminance or hue range and inverted. Model masks are regenerated from the image when needed rather than stored.

**Tone Curve.** A master curve plus red, green and blue curves, picked with the RGB, Red, Green, Blue control above the graph; the channel curves apply after the master, on the display-referred image. Drag points, click the curve to add one, double-click a point to remove it. Channel curves you have changed stay faintly visible behind the one you are editing. Linear resets the curve shown.

**HSL / Colour.** Hue, saturation and luminance for eight hue bands.

**Split Toning.** Shadow and highlight tints with a balance.

**Lens Corrections.** Distortion, chromatic aberration and vignetting from a bundled Lensfun profile matched to the camera and lens, each switchable, plus manual distortion and vignetting and a purple/green defringe.

**Detail.** Demosaic algorithm (RCD or bilinear), sharpening (amount, radius, threshold on perceptual luminance), and bilateral noise reduction in camera space.

**AI Noise Reduction.** NAFNet, trained on real sensor noise, run once per image on the GPU (about 11 s for 24 MP) and then blended at any strength instantly. It runs in camera space before colour, so white balance and every later module see clean data. Exports run it again; thumbnails skip it. If macOS runs critically short of memory the result is let go, and it runs again once memory recovers.

**Soft Proof.** Preview the image as sRGB or Display P3, or through an ICC profile, with a gamut warning that paints out-of-range colours grey.

## Presets and clipboard

Presets and Clipboard holds a menu of presets, five built in and any you save, and a checklist of which module groups copy and paste carry. ⇧⌘C copies the current edit; ⇧⌘V pastes into the open image or onto the whole Library selection. Presets are JSON files in Application Support and can be shared.

## History and snapshots

The left panel lists every settled edit newest first; click one to jump, ⌘Z and ⇧⌘Z step. Thirty steps are kept per image, in the sidecar as well as the catalog. Snapshots are named copies of the whole edit; restoring one is itself a history step.

## The viewport

Pinch or option-scroll to zoom, scroll or drag to pan, double-click to toggle fit and 100%. ⌘0 fits, ⌘1 is 100%, ⌘= and ⌘- step. The image surround grey is set in Settings. The filmstrip along the bottom opens another image with one click; see [Library](Library#filmstrip).

On an HDR display, highlights above paper white are shown using the display's headroom, up to two stops, with the HDR display switch to preview the SDR result. The image follows the screen's brightness without re-rendering, and the screen's extended range (which raises the backlight) is only switched on while the image needs it.

The histogram draws red, green and blue with a luminance outline. Below it, the share of pixels clipped in the highlights and in the shadows per channel, and, with HDR display on, the share of the image above SDR white, which an SDR screen or file can't show. While a slider is dragged, the scopes update up to ten times a second.
