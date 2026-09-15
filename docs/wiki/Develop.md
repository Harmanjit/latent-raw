# Develop

The right panel holds the modules in pipeline order. All controls are live at full quality. Double-click a slider to reset it. ⌘Z and ⇧⌘Z undo and redo; `\` shows the unedited image. The Develop menu holds Auto Adjust, the crop, spot removal and red-eye tools, new masks and brush size; the Edit menu holds undo, redo and Copy and Paste Settings.

**Typed values.** Most sliders show their value as a number you can click: type a value and press Return or Tab (or click elsewhere) to apply it, or Escape to cancel. If the value changes while the field is open, because the slider moved or another image opened, the field follows it and anything typed is dropped. ↑ and ↓ step it by the last digit shown, ⇧↑ and ⇧↓ by ten steps. The unit can be typed or left out, and the value is clamped to the slider's range. A typed value is an ordinary edit and lands in history like a drag. Temperature, the four tone ranges, HSL, Split Toning and export quality don't take typed values yet.

## Modules

**White Balance.** Temperature and tint, starting from the camera's own setting. As Shot returns to it.

**Tone.** Exposure in stops, contrast and mid-grey for the sigmoid tone curve. **Highlights, Shadows, Whites and Blacks** each brighten or darken one band of tones without moving mid grey. They change exposure per pixel by its brightness, so colours keep their hue, there are no halos, and tones never swap order. **Auto** (⌘U) sets exposure, contrast and white balance from the image itself, backing exposure off if it would blow the brightest highlights. On an HDR screen, **HDR display** shows highlights above paper white using the screen's headroom.

**Presence.** Texture (fine local contrast, 1–4 px), Clarity (mid-scale, midtone-weighted), Dehaze (dark-channel prior in linear light; negative adds haze) and Vibrance (saturation that favours muted colours and spares skin).

**Crop and Straighten.** R opens the tool: drag inside to move, edges and corners to resize, with aspect presets that follow the image orientation. Straighten runs −45° to 45° and the crop shrinks to avoid empty corners, growing back as the angle returns. Perspective offers vertical and horizontal keystone. The crop is a sampling map, not a pipeline stage, so it costs no re-render.

**Spot Removal.** H arms the tool. Click a spot to place a patch with an automatic source; drag from the click to choose the source; drag either circle to move it; ⌫ deletes the selected patch. [ and ] make the next patch, and the selected one, smaller or larger. **Heal** copies the source's texture and takes tone and colour from what surrounds the target on every side, so a gradient or an edge running through the patch carries on. **Clone** copies exactly. Patches apply in order, each seeing the ones before, so a patch next to an earlier one matches it. Up to 32 patches.

**Shape** switches between **Spot** and **Brush**. With Brush, drag along a wire, a hair or a dust streak: it becomes one patch when you let go, with its source placed beside it, across the stroke. Drag the dashed outline or its dot to move the source, or the solid outline to move the stroke. A click with Brush makes an ordinary circle. [ and ] resize the selected patch. A stroke counts as one of the 32 patches, however long, and keeps up to 256 points; a longer scribble is simplified to fit. Healing copies the source's texture, so pick a source without edges running along the stroke: a cloud edge or a horizon under the source shows up as a line.

**Red-Eye**, under Spot Removal. Y arms the tool. Click a red pupil to add a spot, and drag while adding to size it; drag inside a spot to move it and its rim to resize it. ⌫ removes the selected spot, and [ and ] resize it. **Pupil Size** sets the selected spot's size (and the next one's), and **Darken** its strength. **Auto** finds faces with Apple's Vision framework on this Mac, with nothing sent anywhere, and adds a spot for each pupil that is actually red; brown and dark eyes are left alone. Only flash-red pixels inside a circle change, so a generous circle is harmless. Spots follow crop, straighten and rotation. Up to 32 spots.

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

Presets and Clipboard holds a menu of presets, five built in and any you save, and a checklist of which module groups copy and paste carry. Spot removal patches and red-eye spots travel together, as **Spot Removal & Red-Eye**. ⇧⌘C copies the current edit; ⇧⌘V pastes into the open image or onto the whole Library selection. Presets are JSON files in Application Support and can be shared.

## History and snapshots

The left panel lists every settled edit newest first; click one to jump, ⌘Z and ⇧⌘Z step. Thirty steps are kept per image, in the sidecar as well as the catalog. Snapshots are named copies of the whole edit; restoring one is itself a history step. Steps are named by what changed, such as Tone, Spot Removal or Red-Eye.

## The viewport

Pinch, or scroll with ⌥ or ⌘, to zoom about the pointer; scroll or drag to pan a zoomed-in image; double-click, or double-tap with two fingers, to toggle fit and 100%. ⌘0 fits, ⌘1 is 100%, ⌘= and ⌘- step. At fit, a two-finger swipe steps to the next or previous image, and holding the mouse button shows a magnifier at 100% under the pointer; past 200% pixels are drawn as squares. F shows the image full screen, with the adjustments coming in from the right edge. See [Library](Library#looking-closely). The image surround grey is set in Settings. The filmstrip along the bottom opens another image with one click; see [Library](Library#filmstrip).

On an HDR display, highlights above paper white are shown using the display's headroom, up to two stops, with the HDR display switch to preview the SDR result. The image follows the screen's brightness without re-rendering, and the screen's extended range (which raises the backlight) is only switched on while the image needs it.

The histogram draws red, green and blue with a luminance outline. Below it, the share of pixels clipped in the highlights and in the shadows per channel, and, with HDR display on, the share of the image above SDR white, which an SDR screen or file can't show. While a slider is dragged, the scopes update up to ten times a second.
