# Masking

Local adjustments change part of the picture: a mask says where, and the mask's sliders say what. They live in the **Local Adjustments** panel in Develop. Up to eight masks per photo; each applies in order, on top of the global edit.

## Making a mask

**Add** in the panel's header starts a new mask:

- **Linear Gradient**: drag on the image from where the effect is full to where it fades out.
- **Radial**: drag from the centre outward. **Width** and **Height** stretch it into an ellipse and **Feather** softens its edge. Click **Place or move** and drag from inside the ellipse to move it; drag from outside to draw a new one. While the tool is armed or the mask is shown, its outline is drawn on the image (dashed where the feather begins).
- **Brush**: paint with **Size**, **Feather**, **Flow** and **Density**; Erase takes paint away. Flow is how much each dab adds; Density is the most a stroke can build up to, however often you go over it. **[** and **]** change the size.
- **Whole Image**: everywhere, for use with a range.
- **Subject** selects the main subject in one go with BiRefNet Lite (bundled) or Apple Vision.
- **Click to Select** uses Segment Anything 2.1: click the thing you want, option-click to leave something out.
- **Select Objects (Box)** also uses Segment Anything: drag a rectangle around the object and it is selected. You can add clicks to the same selection afterwards with **Click to select**, and **Draw box** draws the box again.
- **Select by Class** picks sky, people, vegetation, water, buildings, ground, mountains, animals or vehicles.
- **Colour Range** selects colours you pick from the image (below).
- **Luminance Range** selects a band of tones, from **Low** to **High**, with a **Feather**.

Model masks (subject, class, selection) are made again from the photo when needed rather than stored, and each records the model that made it; see [Models](Models).

## Components: add, subtract, intersect

A mask can be built from several parts. Under **Components**, the first row is the mask's own shape; the **+**, **−** and **◎** menus beside the heading add another part that is combined with everything above it:

- **Add** joins it on. Where two soft edges overlap the stronger wins, so nothing doubles up.
- **Subtract** takes it out: a radial on a face minus a brush over the eyes, say.
- **Intersect** keeps only what is in both: a subject mask intersected with a luminance range brightens only the subject's shadows.

Any shape, a colour range, a luminance range or a model mask can be a component, up to six per mask. Click a component's row to point the tools at it (a brush component is painted, a radial component is placed), change its mode from the menu at the start of the row, tick **Invert** to flip just that part, or remove it with ✕. **Invert mask** under the sliders flips the whole combination.

## Feather and Edge for model masks

When a subject, class or selection mask (or component) is selected, two sliders refine the model's edge:

- **Edge** grows the mask outward (to the right) or shrinks it inward (to the left), by up to 3% of the frame's short side. Use it to take in a halo the model missed, or to stop a sky mask spilling onto the treeline.
- **Feather** softens the edge by up to the same distance.

Both work on the mask itself, before the adjustments, and are stored with the edit, so a regenerated mask gets the same treatment.

## Colour Range

Add a Colour Range mask (or component) and the eyedropper is armed: click a colour on the image. Each click adds a colour, up to five; the swatches show what is picked and **Clear** starts over. **Refine** sets how far from the picked colours the selection reaches. Colours are judged as the mask sees them, before any mask changes the picture, by hue and saturation together, so pale and vivid versions of a colour are close but not the same, and greys can be picked too.

The older **Hue range** tickbox under the sliders still narrows any mask to a band of hues by centre and width.

## The sliders

Each mask has an **Amount** (how strongly all its sliders apply, from 0 to full) and four groups:

- **Light**: Exposure, Contrast, Highlights, Shadows, Whites and Blacks. The last four are the global sliders of the same name, working inside the mask.
- **Colour**: Temperature (cooler or warmer), Tint (greener or more magenta), Hue (turns every colour round the colour wheel, ±180°) and Saturation.
- **Effects**: Texture, Clarity and Dehaze, as the Presence sliders, inside the mask.
- **Detail**: Sharpness (sharpens fine detail; below zero, softens), Noise (smooths luminance grain in flat areas and leaves edges alone) and Defringe (removes purple and green fringes on edges).

Effects and Detail open once used. They need a look at each pixel's neighbourhood, so they run in a stage of their own after the global Presence; a photo whose masks don't use them never runs it.

## Looking after masks

- Click a mask's eye to **hide** it: it keeps its settings and changes nothing until shown again.
- **Rename** it in the name field at the top of its controls.
- **Masks ▸ Duplicate** copies the selected mask; **Duplicate and Invert** copies it turned inside out, the quick way to treat a subject and its background differently. Model masks are copied with their pixels, so nothing is made again.
- **Masks ▸ Delete Empty Masks** removes every mask with nothing in it: a brush never painted, a selection never clicked, a gradient never dragged out.
- Right-click a mask in the list for the same commands.

All of these are ordinary edits: ⌘Z undoes them, and they travel in copy, paste and presets with the Local Adjustments group.

## Seeing the mask

**Show mask** draws the selected mask on the image. **Overlay** chooses how:

- **Colour Overlay** (the default): a tint over the picture, in red, green, blue, yellow, magenta or white, at 25 to 100%.
- **Colour Overlay on B&W**: the same tint over a black-and-white picture, for when the tint and the subject are the same colour.
- **Image on Black** and **Image on White**: only what the mask covers.
- **White on Black**: the mask itself, the way to judge a soft edge.

The overlay is a viewing aid only; exports never show it.
