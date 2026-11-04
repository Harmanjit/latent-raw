# Tutorial: Editing

Four walkthroughs in Develop: a basic edit from start to finish, darkening a sky with a mask, removing a distraction, and blurring a background. Open a photo in Develop first (select it and press D or Return). Every module is described in full on [Develop](Develop) and [Masking](Masking).

Nothing here changes your raw file, and ⌘Z steps back through every change, so feel free to experiment. Press `\` at any time to compare with the photo as it came from the camera.

## A basic edit

The order below follows the panel on the right, top to bottom, which is roughly the order that works best.

**1. Choose a starting look.** At the top of the adjustments, click the **Profile** name (Latent Standard to begin with). **Latent Neutral** or **Latent Flat** give a quieter start with more room to edit; **Vivid**, **Portrait** and **Landscape** are stronger looks with an **Amount** slider. If you have imported your camera maker's profiles, they are listed under your camera. See [Develop](Develop#modules).

**2. Set the white balance.** In **White Balance**, the menu offers **As Shot**, **Auto** and light sources such as **Daylight**, **Cloudy** and **Tungsten**. For an exact result, press **W** (**Develop › White Balance Selector**) and click something in the photo that should be grey or white: a grey card, a white wall, a cloud in shade. Then fine-tune with **Temperature** and **Tint** to taste.

**3. Try Auto.** Press **⌘U** (**Develop › Auto Adjust**). It sets exposure, contrast and white balance from the photo, then Highlights, Shadows, Whites, Blacks, Vibrance and Saturation. Treat it as a starting point; every slider stays yours to move.

**4. Get the tones right.** In **Tone**:

- **Exposure** for overall brightness, **Contrast** for punch.
- **Highlights** down to bring back a bright sky; **Shadows** up to open dark areas.
- **Whites** and **Blacks** set the brightest and darkest points.

Press **J** (**View › Show Clipping**) to see clipped highlights in red and crushed shadows in blue, and adjust until only the parts you accept are marked. You can also drag sideways on the histogram at the top: it moves whichever slider drives that part of it.

**5. Add presence.** **Texture** brings out fine detail such as skin or bark (or softens it, below zero), **Clarity** adds mid-scale contrast, **Dehaze** cuts through haze, and **Vibrance** adds colour while sparing skin and already strong colours.

**6. Crop and straighten.** Press **R** (**Develop › Crop & Straighten**). Pick an **Aspect**, drag the corners, and drag inside to move the crop. **Auto** levels the horizon from the lines in the photo; or hold ⌘ and drag along something that should be level. **O** cycles the composition guides (thirds, golden ratio and more). Press R or Esc to leave the tool.

**7. Fix converging lines.** For buildings shot looking up, open **Transform** under the crop, and set **Upright** to **Auto** or **Vertical**. Keep **Constrain Crop** on so no empty corners show. See [Transform and Upright](Develop#transform-and-upright).

**8. Check the lens corrections.** **Lens Corrections** finds a profile for most lenses by itself and corrects distortion, vignetting and colour fringes. If it found none, pick the lens from the profile menu, or switch on **Remove chromatic aberration (automatic)**.

**9. Sharpen and clean up noise.** Zoom to 100% (⌘1) first. In **Detail**, raise sharpening **Amount**, and hold **⌥** while dragging **Masking** to see where it sharpens: white is sharpened, black is left alone. For a high-ISO photo, raise noise reduction **Luminance**, or click **Denoise** in **AI Noise Reduction**, wait for it to finish (about 11 seconds for 24 MP), and blend it in.

**10. Keep versions and reuse the edit.** In the left panel's history, save a **snapshot** of an edit you like before trying something else. To give other photos the same look, press **⇧⌘C** to copy the settings, select the other photos in the grid and press **⇧⌘V**. In **Presets & Clipboard** you can save the edit as a preset for next time and choose which groups copy and paste carry.

## Mask a sky (or a subject)

A mask limits adjustments to part of the photo. Here, darkening and deepening a bright sky.

**1. Make the mask.** In **Local Adjustments**, choose **Add › Select by Class › Sky**. Latent finds the sky on this Mac, which takes a moment; the status bar says when it is done.

**2. See what it selected.** Tick **Show mask**: the selected area is tinted on the photo. **Overlay** offers other views; **White on Black** is the best for judging the edge. Untick it when you're happy.

**3. Refine the edge.** If a halo of bright sky shows along the treeline, move **Edge** to the right to grow the mask a little; to stop the darkening spilling onto the trees, move it to the left. **Feather** softens the transition.

**4. Adjust.** Use the mask's own sliders: **Exposure** down a little, **Highlights** down, **Temperature** slightly cooler, **Dehaze** and **Saturation** up for a deeper blue. **Amount** turns the whole mask's effect up or down at once.

**5. Take something out of the mask.** If the mask caught a building you want left alone, use the **−** (subtract) menu beside **Components** to add a **Brush**, click its row under Components so the brush paints that part, and paint over the building. See [Components](Masking#components-add-subtract-intersect).

**The subject instead.** **Add › Subject** selects the main subject in one go. To treat the background differently, right-click the mask and choose **Duplicate and Invert**: the copy covers everything but the subject. For anything else, **Add › Click to Select** lets you click the thing you want, and **Add › Select Objects (Box)** lets you drag a box around it.

## Remove a distraction

For taking out a sign, a stray branch, a person in the distance or a power line across plain sky.

**1. Arm the tool.** Press **H** (**Develop › Spot Removal**) and set the mode to **Remove**. Set **Shape** to **Spot** for a small round thing, or to **Brush** for anything longer.

**2. Cover it.** Click on the thing, or brush over it, a little wider than it. When you let go, Latent fills the area from what surrounds it, carrying edges such as a horizon or a fence line through the gap. There is no source to pick.

**3. Let Latent find the object.** Switch on **Detect Objects** under the mode picker and brush roughly over the object again. Latent finds the object's outline under your brush and fills just that, keeping the background your brush also covered. If you move the patch, **Detect Object** finds the outline again; **Use Brush** goes back to filling everything you brushed.

**4. Fix or undo.** Drag the dotted outline to move a patch, press **⌫** to delete the selected one, or ⌘Z. A thin wire right across the frame is better done with **Heal** and **Brush**, since a Remove patch can cover at most 35% of the photo's short side.

Remove builds its fill from the photo itself. It handles sky, grass, water, walls and sand well, but it can't invent something that isn't there to copy, such as the hidden half of a face. See [Remove and Detect Objects](Develop#remove-and-detect-objects).

## Blur the background with Lens Blur

Lens Blur gives a shallow depth of field after the fact, as if the photo had been taken with a fast lens wide open.

**1. Optional: add a depth model.** Lens Blur works best with a depth model, which knows how far away every part of the scene is. None comes with Latent, and Latent never downloads one. Open **Settings › AI › Models**, click **Get…** on **Depth Anything V2 Small** to open its page in your browser, convert it as [Converting Models](Converting-Models) describes, and add it with **Add Model…**. Without one, Latent makes two planes from the subject mask (subject sharp, everything else blurred evenly), which works well for portraits and single objects.

**2. Turn it on.** In the **Lens Blur** panel, move **Amount** up. The first move makes the photo's depth map on this Mac, which takes a moment.

**3. Choose what stays sharp.** Click **Pick Focus**, then click the part of the photo you want sharp: the focus range centres on its distance.

**4. Check the depth.** Switch on **Show Depth** to see the depth map, amber near to blue far, with the sharp range washed light. Drag the edges of **Focus Range** to widen or narrow what stays sharp. Switch Show Depth off again.

**5. Shape the blur.** **Bokeh** sets the shape of out-of-focus highlights (Circle, Bubble or 5-Blade), and **Boost Highlights** turns small lights into visible discs.

Exports, prints and slideshows carry the blur. See [Lens Blur](Develop#lens-blur) for every control.
