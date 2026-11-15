# Tone Equalizer

The Tone Equalizer brightens or darkens the photo one brightness level at a time. It comes from darktable. Use it to bring a bright window and a dark room closer together, or to lift shadows without making them look grey and flat.

It is in Develop's right panel, below **Tone Curve**. Click **Tone Equalizer** to open it. The full reference is in [Develop](Develop#tone-equalizer); this page shows how to use it.

## What it does

The photo's brightness is split into nine **bands**, one stop apart. The darkest band is −8 EV (deep shadow) and the brightest is 0 EV (the sensor's white). Each band has a slider. Move a band up and every part of the photo at that brightness gets brighter. Move it down and those parts get darker.

The bands don't read each pixel on its own. They read a **mask**: a smoothed copy of the photo's brightness that follows edges. A whole sky, or a whole shadowed face, gets one value in the mask. So when you move a band, the whole area moves together and the texture inside it keeps its contrast. A tone curve would flatten that texture.

The Tone Equalizer only changes brightness, never colour. It does nothing until a band leaves 0.

## The three tabs

- **Simple** shows the nine bands as vertical sliders, from −3 to +3 EV. Drag up to brighten, down to darken. Double-click a slider to put it back to 0.
- **Advanced** shows the same nine values as a curve over a histogram of the mask. Drag a node up or down to move its band. The line under it, **Mask histogram spread**, says where the middle 90% of the mask lies.
- **Masking** controls how the mask is made: **Mask Exposure**, **Mask Contrast**, **Smoothing** and **Edge Refinement**.

Under every tab are **On Image**, **Show Mask** and **Reset**. **Reset** puts every band back to 0 and the mask settings back to their defaults.

## The live histogram

On the **Simple** tab, grey bars stand behind the sliders. A tall bar means that band covers a lot of the photo. A slider with no bar has nothing to change, so moving it does nothing.

On the **Advanced** tab, the histogram behind the curve shows the same thing.

Both follow **Mask Exposure** and **Mask Contrast** while you drag them, so you can watch the photo's tones slide across the bands.

## Fit Mask and Auto Align

Many photos only use three or four of the nine bands. Then a few sliders do all the work, and the rest do nothing. Two buttons fix this by setting **Mask Exposure** and **Mask Contrast** for you. Neither one moves a band.

- **Fit Mask** (on the Advanced and Masking tabs) spreads the middle 90% of the mask across the bands.
- **Auto Align** (on every tab) spreads the photo's whole tonal range across the bands. Its darkest tones land on the −8 EV band and its brightest on the 0 EV band.

Try **Auto Align** first. Use **Fit Mask** if a few very dark or very bright spots make Auto Align spread things too thinly.

## The on-image tool

**On Image** lets you work on the photo itself instead of the sliders.

1. Click **On Image**.
2. Point at a part of the photo you want to change, such as a dark doorway.
3. Scroll up to brighten that tone, or scroll down to darken it. You can also drag up or down on the photo.
4. Press Esc when you are done.

Each scroll gesture or drag is one step in History, so ⌘Z takes it back. While the tool is on, scrolling changes the band instead of moving the view. Hold ⌥ or ⌘ while scrolling to zoom.

While the panel is open, the colour readout under the histogram also shows **Mask**: the mask's value under the pointer. It tells you which band you are about to move.

## Show Mask

Tick **Show Mask** to see the mask in place of the photo, in grey. Black is −8 EV and white is 0 EV. Use it to check that the areas you want to treat as one (a sky, a wall) really are one even grey. Untick it to see the photo again. It only changes the screen, never the edit or an export.

If the mask looks blotchy, raise **Smoothing**. If a change spills across an edge as a bright or dark halo, raise **Edge Refinement**.

## Presets

Three built-in presets use the Tone Equalizer and nothing else, so they leave the rest of your edit alone:

- **Compress Shadows and Highlights (Soft)**
- **Compress Shadows and Highlights (Strong)**
- **Lift Shadows**

Find them in the preset menu in **Presets & Clipboard**. The **Amount** slider under that menu sets how strongly the next preset you choose is applied, blending its bands in more or less. Your own presets can include the Tone Equalizer too: it is a group called **Tone Equalizer** in copy, paste and presets. See [Presets and clipboard](Develop#presets-and-clipboard).

## How to: a bright window and a dark room

1. Open the photo in Develop and open **Tone Equalizer**.
2. Click **Auto Align** so the photo's tones cover all nine bands.
3. On the **Simple** tab, look at the grey bars. The window is in the bands on the right; the room is in the bands on the left.
4. Drag the two or three right-hand bands down a little, about −1 EV, until the view outside has detail again.
5. Drag the left-hand bands up, about +1 EV, until the room opens up.
6. Tick **Show Mask** if you see a halo round the window frame. Raise **Edge Refinement** on the **Masking** tab until it goes, then untick **Show Mask**.

## How to: lift one shadow with the on-image tool

1. Open **Tone Equalizer** and click **On Image**.
2. Point at the shadow you want to lift, such as a face under a hat.
3. Scroll up a few clicks. Only that tone gets brighter, all of it together.
4. If too much of the photo brightens, scroll down to undo it and try a darker or lighter part of the shadow instead.
5. Press Esc to put the tool away.

## How to: start from a preset

1. Open **Presets & Clipboard**.
2. Leave **Amount** at 100% for now.
3. Choose **Compress Shadows and Highlights (Soft)** from the preset menu.
4. If it is too strong or too weak, press ⌘Z, move **Amount** (say 50% or 150%) and choose the preset again.
5. Open **Tone Equalizer** to fine-tune any band by hand.
