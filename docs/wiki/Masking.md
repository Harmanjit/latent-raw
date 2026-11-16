# Masking

Local adjustments change part of the picture: a mask says where, and the mask's sliders say what. They live in the **Local Adjustments** panel in Develop. Up to eight masks per photo; each applies in order, on top of the global edit. For step-by-step examples, see [How to: blend and combine masks](#how-to-blend-and-combine-masks).

## Making a mask

**Add** in the panel's header starts a new mask:

- **Linear Gradient**: drag on the image from where the effect is full to where it fades out.
- **Radial**: drag from the centre outward. **Width** and **Height** stretch it into an ellipse and **Feather** softens its edge. Click **Place or move** and drag from inside the ellipse to move it; drag from outside to draw a new one. While the tool is armed or the mask is shown, its outline is drawn on the image (dashed where the feather begins).
- **Brush**: paint with **Size**, **Feather**, **Flow** and **Density**; Erase takes paint away. Flow is how much each dab adds; Density is the most a stroke can build up to, however often you go over it. **[** and **]** change the size. Tick **Auto Mask** and each dab paints only where the photo is like the colour and brightness under the brush's centre, so a stroke along the edge of a sky stops at the trees; it works for Erase too. See [Auto Mask](#auto-mask).
- **Whole Image**: everywhere, for use with a range.
- **Subject** selects the main subject in one go with BiRefNet Lite (bundled) or Apple Vision.
- **Click to Select** uses Segment Anything 2.1: click the thing you want, option-click to leave something out.
- **Select Objects (Box)** also uses Segment Anything: drag a rectangle around the object and it is selected. You can add clicks to the same selection afterwards with **Click to select**, and **Draw box** draws the box again.
- **Select by Class** picks sky, people, vegetation, water, buildings, ground, mountains, animals or vehicles. It uses the bundled SegFormer model, whose licence from NVIDIA allows research and evaluation use only, not commercial work; Settings › AI › Models marks it **Research use only**. See [Licences](Licences#bundled-models).
- **Colour Range** selects colours you pick from the image (below).
- **Luminance Range** selects a band of tones, from **Low** to **High**, with a **Feather**. See [Luminance and Channel Range](#luminance-and-channel-range).

Model masks (subject, class, selection) are made again from the photo when needed rather than stored, and each records the model that made it; see [Models](Models).

## Editing gradients and radials

While a gradient's or radial's tool is armed (**Place gradient** or **Place or move**), the shape shows handles you can drag, so you can reshape it instead of drawing it again:

- A **Linear Gradient** has a handle where the effect is full, one where it ends, and one in the middle that moves the whole gradient.
- A **Radial** has a handle on the edge of each of its two axes (width and height), a ring handle on the dashed inner line that sets the **Feather**, and a ring above the ellipse that **turns** it. Drag inside the ellipse to move it, as before. **Angle** in the panel turns it too.
- Over the selected shape, the **mouse wheel** changes its feather (a gradient's fade gets longer or shorter about its middle); with **⇧** it changes the mask's **Amount**. A trackpad's scroll still pans.
- Tick **Keep tool armed** and the tool stays armed after you place a shape: drag away from it to place another mask of the same kind (or, when the selected row is a component, another component in the same mode), as many as you like in a row.

## Components: add, subtract, intersect

A mask can be built from several parts. Under **Components**, the first row is the mask's own shape; the **+**, **−** and **◎** menus beside the heading add another part that is combined with everything above it:

- **Add** joins it on. Where two soft edges overlap the stronger wins, so nothing doubles up.
- **Subtract** takes it out: a radial on a face minus a brush over the eyes, say.
- **Intersect** keeps only what is in both: a subject mask intersected with a luminance range brightens only the subject's shadows.

Any shape, a colour range, a luminance range or a model mask can be a component, up to six per mask. Click a component's row to point the tools at it (a brush component is painted, a radial component is placed), change its mode from the menu at the start of the row, tick **Invert** to flip just that part, or remove it with ✕. **Invert mask** under the sliders flips the whole combination.

The mode menu at the start of a component's row has two more modes, as in darktable:

- **Sum** adds the two values, up to full strength, so where two soft edges overlap they build up rather than the stronger winning.
- **Exclusion** keeps what is in one or the other but not both: two overlapping radials leave their overlap untouched.

### Reordering

Order matters: masks apply one after another, and each component joins what is built above it. Drag a mask in the list onto another to put it there, or drag a component onto another component (the first shape always stays first). Right-click either for **Move Up** and **Move Down**, which VoiceOver offers as actions too. Each move is one step for ⌘Z.

### Using another mask

**Use Mask** at the bottom of the **+**, **−** and **◎** menus adds a component that is another mask of the same photo, as it is now: its shape, its components, its Invert and its ranges. The row shows a link icon and that mask's name. Edit the mask it uses and every mask using it changes too, so one carefully painted sky can be added to one mask, subtracted from another and intersected with a third.

Links are one level deep. A mask can't use itself, a mask that uses another, or a mask whose parts would take it past six; and a mask that another one uses can't use others. The menu greys those out. If the mask a link uses is deleted, the link stays in the list as **Missing Mask** and does nothing.

## Feather and Edge for model masks

When a subject, class or selection mask (or component) is selected, two sliders refine the model's edge:

- **Edge** grows the mask outward (to the right) or shrinks it inward (to the left), by up to 3% of the frame's short side. Use it to take in a halo the model missed, or to stop a sky mask spilling onto the treeline.
- **Feather** softens the edge by up to the same distance.

Both work on the mask itself, before the adjustments, and are stored with the edit, so a regenerated mask gets the same treatment.

### Edge refine

Brush masks and model masks (and brush or model components) also have **Edge refine**. It runs a guided filter over the mask that pulls its edge onto edges in the photo, so a loosely painted sky or a model's soft outline follows the skyline or the hair. Higher reaches further, up to about 2% of the frame's short side, and follows fainter edges. It compares against the same quarter-size picture of the raw that [Auto Mask](#auto-mask) uses, so moving a slider never changes it and the export matches the screen. Gradients and radials have no pixels to refine and don't show it.

## Colour Range

Add a Colour Range mask (or component) and the eyedropper is armed: click a colour on the image. Each click adds a colour, up to five; the swatches show what is picked and **Clear** starts over. **Option-click** takes away the picked colour nearest the pointer, and the colours picked this session are drawn on the image while the eyedropper is armed. **Refine** sets how far from the picked colours the selection reaches. Colours are judged as the mask sees them, before any mask changes the picture, by hue and saturation together, so pale and vivid versions of a colour are close but not the same, and greys can be picked too.

The older **Hue range** tickbox under the sliders still narrows any mask to a band of hues by centre and width.

## Luminance and Channel Range

A **Luminance Range** component selects pixels by how bright they look; a **Channel Range** component (in the **+**, **−** and **◎** menus) selects by one channel you choose: **Red**, **Green**, **Blue**, **Saturation**, Lab **Lightness**, Lab **a** (green to magenta), Lab **b** (blue to yellow) or Lab **Chroma**. Both read the picture as the mask sees it, before any mask changes it.

- The **range control** shows the channel as a gradient with four handles: where the fade below the band starts, **Low**, **High**, and where the fade above it ends. Drag the outer handles to give the two sides different fades. The **Low**, **High** and **Feather** sliders below still work; Feather sets both fades at once.
- **Pick Range** arms an eyedropper: click the image and the band is set 10% either side of the value there; drag a rectangle and it spans the darkest to the brightest (least to most) inside it. The eyedropper puts itself away after one pick. **Shift-click** (or Shift-drag) adds another sample and the band grows to cover them all; **Option-click** takes away the sample nearest the pointer and the band fits the ones left. Both keep the eyedropper armed, and the samples are drawn on the image, numbered, while it is. Shift-click on a band you set by hand grows that band. Only the band is saved in the edit, not the samples.
- **Under pointer** reads the value under the pointer live, and a mark on the gradient shows where it falls.

The **Luminance range** tickbox under a mask's sliders has the same range control, eyedropper and readout while no component is selected.

To see what a range is reading, click the half-filled circle on its component row (**Show Channel**): the image shows that component's input as a grey, the luminance or the channel, or for a Colour Range how near each pixel is to the picked colours. Click it again to go back. **Develop ▸ Masks ▸ Show Mask Channel** does the same, and can be given a key in Settings ▸ Keyboard.

## The sliders

Each mask has an **Amount** (how strongly all its sliders apply, from 0 to full) and four groups:

- **Light**: Exposure, Contrast, Highlights, Shadows, Whites and Blacks. The last four are the global sliders of the same name, working inside the mask.
- **Colour**: Temperature (cooler or warmer), Tint (greener or more magenta), Hue (turns every colour round the colour wheel, ±180°) and Saturation.
- **Effects**: Texture, Clarity and Dehaze, as the Presence sliders, inside the mask.
- **Detail**: Sharpness (sharpens fine detail; below zero, softens), Noise (smooths luminance grain in flat areas and leaves edges alone), Defringe (removes purple and green fringes on edges) and Smooth (an edge-preserving blur of up to about 20 pixels of the raw, for skin or sky, that leaves edges sharp).

Effects and Detail open once used. They need a look at each pixel's neighbourhood, so they run in a stage of their own after the global Presence; a photo whose masks don't use them never runs it.

Below the sliders, three more groups open once used:

- **Curve**: a point curve inside the mask, with RGB, Red, Green and Blue channels, drawn and edited as the global Tone Curve. It works on the same scale as the global curve, so the same shape does the same thing; a straight line is no curve.
- **Point Colour**: **Pick a Colour** and click the photo; up to four swatches per mask, each with Hue, Saturation, Luminance, Range and Variance as in the global [Point Colour](Develop). Only the picked colours inside the mask change.
- **Grain**: Grain, Size and Roughness, as the Effects grain but only inside the mask, on top of any global grain. Its pattern is fixed to the photo, so the export matches the screen.

These three run in the same stage as Effects and Detail, after the global edit, so a mask's curve bends the picture as it finally looks.

- **Tone Equalizer**: the [Tone Equalizer](Tone-Equalizer)'s nine bands in a compact strip, only inside the mask, so you can, say, pull down the bright parts of the sky alone. The bands read the global tone equalizer's mask, with its Masking settings, so each moves the same tones as the panel's band of that stop; the panel's own bands can stay at 0. It acts like the mask's Exposure, scaled by the mask and its Amount and joined by its Blend, and with no band moved the mask stores and renders nothing new. **Reset** puts every band back to 0. Copy, paste, Sync and mask presets carry it with the mask's other sliders.

### Blend

The **Blend** menu beside the mask's name sets how its result joins the photo:

- **Normal**: the result as the sliders make it, as every mask did before.
- **Colour Only**: only the mask's change of colour. The photo keeps its lightness, so a warm-up, a hue turn or a curve on one channel never brightens or darkens.
- **Lightness Only**: only the mask's change of lightness. The photo keeps its colour, so an exposure, contrast or curve move never shifts the saturation.

Lightness here is luminance in linear light, so the recombination keeps hue and saturation exactly. It applies to everything the mask does, the Detail and Effects sliders, curve, Point Colour and grain included.

## Auto Mask

With **Auto Mask** ticked, every new brush stroke compares each pixel under a dab with the colour and brightness at the dab's centre and paints only as much as they are alike. Brightness counts in stops, so a stroke on a mid-grey wall ignores both the black window frame and the white sky; colour counts for less in deep shadow, where noise scatters it. Strokes made with it off stay as they were.

The stroke stores only that Auto Mask was on, never the pixels. What it compares against is the raw itself at a quarter of its size with the as-shot white balance and no other edit, worked out the first time a stroke needs it, so moving a slider never changes what a stroke covers, and the export paints exactly what the screen showed.

## Looking after masks

- Click a mask's eye to **hide** it: it keeps its settings and changes nothing until shown again.
- **Rename** it in the name field at the top of its controls.
- **Masks ▸ Duplicate** copies the selected mask; **Duplicate and Invert** copies it turned inside out, the quick way to treat a subject and its background differently. Model masks are copied with their pixels, so nothing is made again.
- **Masks ▸ Delete Empty Masks** removes every mask with nothing in it: a brush never painted, a selection never clicked, a gradient never dragged out.
- Right-click a mask in the list for the same commands.

All of these are ordinary edits: ⌘Z undoes them, and they travel in copy, paste and presets with the Local Adjustments group.

### Mask presets

**Presets ▸ Save Selected Mask as Preset…** keeps the selected mask under a name: its shape, components, ranges and every slider. Choose a preset from the same menu to add its mask to the open photo as a new mask (existing masks are never replaced); **Rename** and **Delete** are in the menu too. Brush strokes are kept as drawn, in proportion to the frame, and Subject, class and Click to Select masks are kept as their kind and clicks and are made again from each photo. A component that uses another mask of the photo (Using another mask, above) can't travel and is left out; the save sheet lists it. Mask presets are files in `~/Library/Application Support/latent/mask-presets`, beside the edit presets' folder.

### Copying a mask to other photos

Right-click a mask in the list (or use **Develop ▸ Masks**) for **Copy Mask**, **Paste Mask** and **Paste Mask to Selection**. Copy takes the mask's shape, components, ranges and adjustment sliders. **Paste Mask** adds it to the open photo as a new mask; **Paste Mask to Selection** adds it to every selected photo. Neither ever replaces a mask, and a photo that already has eight masks is left alone and counted in the status bar. As with mask presets, gradients and brush strokes are copied as drawn, in proportion to the frame, and Subject, class and Click to Select parts are made again from each photo's own pixels (when the photo is opened in Develop). A part that uses another mask of the source photo is left out, and the status bar says so. Paste Mask is one step in the photo's history; Paste Mask to Selection is undone in one go from the Library, like Paste Settings.

## Seeing the mask

**Show mask** draws the selected mask on the image. **Overlay** chooses how:

- **Colour Overlay** (the default): a tint over the picture, in red, green, blue, yellow, magenta or white, at 25 to 100%.
- **Colour Overlay on B&W**: the same tint over a black-and-white picture, for when the tint and the subject are the same colour.
- **Image on Black** and **Image on White**: only what the mask covers.
- **White on Black**: the mask itself, the way to judge a soft edge.

The overlay is a viewing aid only; exports never show it.

## How to: blend and combine masks

These walkthroughs use the controls described above. Open a photo in Develop and open **Local Adjustments** first. Every step is one edit, so ⌘Z takes it back.

### Warm a sky without brightening it (Colour Only)

1. Choose **Add › Select by Class › Sky**.
2. Move **Temperature** to the right to warm the sky.
3. Set **Blend**, beside the mask's name, to **Colour Only**. The sky keeps its brightness and only its colour changes.

### Brighten a face without making it orange (Lightness Only)

1. Choose **Add › Subject**.
2. Raise **Exposure** a little.
3. Set **Blend** to **Lightness Only**. The face gets brighter, but its colour and saturation stay as they were.

### Darken the sky but not the tree in front of it (Subtract)

1. Choose **Add › Select by Class › Sky** and lower **Exposure**.
2. In the **−** menu beside **Components**, choose **Brush**.
3. Click the new component's row, then paint over the tree. The brush is taken out of the sky mask.
4. If your painting is loose, raise **Edge refine** on the brush component so its edge snaps to the tree's outline.

### Treat only the subject's shadows (Intersect)

1. Choose **Add › Subject**.
2. In the **◎** menu beside **Components**, choose **Luminance Range**.
3. Drag **Low** to 0, then drag **High** down until only the shadows on the subject are selected. Tick **Show mask** to check.
4. Raise **Shadows** or **Exposure**. Only the dark parts of the subject change.

### Build up two soft gradients (Sum) or skip their overlap (Exclusion)

1. Choose **Add › Linear Gradient** and drag it in from the top of the photo.
2. In the **+** menu, add a second **Linear Gradient** from the bottom.
3. Click the mode menu at the start of the second row and choose **Sum**: where the two fades overlap, they add up instead of the stronger one winning.
4. Choose **Exclusion** instead to leave the overlap untouched.

### Change the order

Masks apply one after another, and each component joins what is above it. Drag a mask or a component onto another to move it there, or right-click it and choose **Move Up** or **Move Down**.

### Use one mask in several others (linked masks)

1. Paint a careful sky with a **Brush** mask and name it "Sky".
2. Make a second mask, such as **Subject**.
3. In its **−** menu, choose **Use Mask › Sky**. The row shows a link icon.
4. Now paint more of the "Sky" mask. Every mask that uses it updates too.

### Soften skin or sky inside a mask (Smooth)

1. Make a mask over the area, for example with **Add › Brush**.
2. Raise **Smooth** in the mask's **Detail** sliders. It blurs fine texture but keeps edges sharp.

### Select one colour channel (Channel Range)

1. Choose **Add › Whole Image (range only)**.
2. In the **◎** menu, choose **Channel Range** and pick a channel, such as Lab **b** to select by blue to yellow.
3. Click **Pick Range**, then click a yellow flower. The band is set around its value.
4. **Shift-click** another flower to add a second sample; the band grows to cover both. **Option-click** a sample to take it away.
5. Click the half-filled circle on the row (**Show Channel**) to see what the range reads.

### Save a mask to use again

1. Select the mask.
2. Choose **Presets › Save Selected Mask as Preset…** and give it a name.
3. On another photo, choose the preset from the same **Presets** menu. It is added as a new mask.

To move a mask straight from one photo to others instead, right-click it and use **Copy Mask** and **Paste Mask** or **Paste Mask to Selection** (see [Copying a mask to other photos](#copying-a-mask-to-other-photos)).
