# Photo Merge

**Photo › Photo Merge** combines two or more photos into one new photo file. This version does **HDR**: several shots of the same scene at different exposures become one photo with the shadows of the bright shots and the highlights of the dark ones. Panorama and HDR Panorama are coming.

## What HDR merge does

A camera can't record the whole range of light in some scenes. Point it out of a window, or at a sunset behind trees, and either the sky turns pure white or the shadows turn black. When a part of the photo has hit the sensor's maximum it is *clipped*: the detail there is gone, and no slider brings it back.

A *bracket* is the answer: the same scene shot several times, each at a different exposure. The bright shots see into the shadows; the dark shots keep the highlights. Latent's HDR merge reads the raw files of the bracket and, pixel by pixel, takes the light from the shots that recorded it best. The result is one raw-like photo with far more range than any single shot, which you then edit as usual: pull the highlights down, lift the shadows, and nothing is clipped.

*EV* (exposure value) counts exposure in *stops*. One stop is double or half the light, so a shot at +2 EV has four times the light of the one at 0 EV.

## Shooting a bracket

- **Use a tripod if you can.** Handheld brackets work too, because **Auto Align** lines the shots up (see below), but a tripod gives the cleanest result. Handheld, use your camera's continuous shooting so the bracket takes a fraction of a second, and keep the shutter speed of the brightest shot fast enough to hold steady (1/60 s or faster).
- **Focus manually,** or focus once and switch autofocus off, so the focus doesn't move between shots.
- **Use aperture priority (A or Av) or manual,** so the aperture, and with it the depth of field, stays the same. Let the shutter speed change the exposure. Keep the ISO fixed.
- **Turn on your camera's auto exposure bracketing (AEB)** if it has one, and set it to **2 EV steps** with **3 or 5 frames**: for example −2, 0 and +2 EV. Five frames at 2 EV cover very bright scenes; three are enough for most.
- **Use the self-timer or a remote,** so pressing the button doesn't shake the camera.
- **Avoid moving things** where you can: people, cars, leaves in wind, waves and clouds move between shots. **Deghost** (see below) can keep each one to a single shot, but it works best when little moves.
- **Shoot raw.** Photo Merge reads raw files only (Bayer sensors; not Fujifilm X-Trans).

## Merging

1. In the Library grid, select the photos of one bracket (click the first, Shift-click the last).
2. Choose **Photo › Photo Merge › HDR…**, or press **⌃H**. It needs two or more selected photos. In Loupe, Compare, Survey and Develop it merges the photos you selected in the grid, as Export does.
3. The **HDR Merge** dialog reads the photos for a moment, then shows a **preview** of the merged photo at the top and lists the photos below it, brightest first. Each row shows the shutter speed, aperture and ISO, and how many stops brighter or darker it is than the **Reference** photo. The reference is the frame with the fewest clipped and black pixels, chosen for you; the merged photo opens looking like it.
4. Beside the list are the options and the merged photo's size in pixels and megapixels, roughly how large the file will be, and its name.
5. Choose the options: **Auto Align** (on unless you turned it off), **Deghost** (None unless you chose a level) with **Show Deghost Overlay**, and **Auto Settings** (off unless you turned it on). The dialog remembers Auto Align, Deghost and Auto Settings for next time. Turning Auto Align on or off reads the photos again.
6. To use another photo as the reference, **click its row**. The stops, the preview and the file name follow. (With VoiceOver, the row's **Use as reference** action does the same.) The choice is for this merge only.
7. Read any note or warning. When Auto Align moved the photos by a pixel or more, a note says by how much ("Photo Merge aligned these photos (up to 17 px)"). A warning says when a photo couldn't be aligned. If there are several, they scroll.
8. Press **Merge** (Return). The dialog closes and the merge runs in the background. Its progress shows in the left panel's **Export** section, with a **Cancel** button. Esc or **Cancel** in the dialog closes it without merging.

If the photos can't be merged (they are from different cameras, different sizes, or all the same exposure, say) the dialog says why and offers only **Close**.

When the merge finishes, the new photo is selected in the grid, and VoiceOver says "HDR merge finished" with its name. If a filter would hide it, the filter is cleared. If something goes wrong, the reason shows in the status bar and nothing is left behind.

A merge takes turns with exports: Export waits while a merge runs, and a merge can't start during an export. Quitting during a merge asks first; quitting stops the merge, and neither a half-made photo nor its sidecar is left.

### The preview

The preview is the merge itself, made small: the same exposures, alignment, deghosting and weighting, opened as the merged photo will open, with default settings. It is made from reduced copies of the photos that Latent keeps in memory while the dialog is open (about 80 MB for six 21 MP photos, freed when the dialog closes), so changing Deghost, the reference or the overlay updates it in about a tenth of a second, a moment after you stop clicking. Changing Auto Align reads the photos again first; the old preview stays, dimmed, until the new one is ready.

Because it is small, fine detail differs a little from the full-size merge, and on cameras over about 36 MP deghosting in the preview is a rougher guide to what the merge will take from one shot.

### HDR Merge Without Dialog

**Photo › Photo Merge › HDR Merge Without Dialog** (**⌃⇧H**) merges the selected photos straight away, with the options the dialog was last left with (Auto Align, Deghost, Auto Settings) and the reference chosen automatically. The photos are read and merged in the background; progress shows in the Export section as usual. If the photos can't be merged, the reason shows in the status bar. When it finishes, any warning the dialog would have shown (a photo that couldn't be aligned or was left out, say) shows in the status bar too.

## Auto Align

Between the shots of a bracket the camera moves a little, even on a tripod when the mirror or the wind shakes it, and a lot when you hold it. Merged as they are, the shots give doubled edges: two copies of every branch and window frame, a few pixels apart.

**Auto Align** measures how each shot moved compared with the reference photo and moves it back before merging. It handles shifts, a slight turn of the camera and the small change of perspective that comes with it. It compares each shot with its neighbour in brightness (the neighbours share the most detail) and checks the answer before using it. Shots that didn't move are left exactly as they are.

- **Leave it on.** Measuring the movement takes a fraction of a second per photo, and a tripod bracket that didn't move comes out the same as without it.
- **The merged photo keeps the reference photo's full frame.** Along the edges, where another shot moved out of the picture, that shot simply doesn't contribute; nothing is cropped or stretched.
- **When a shot can't be aligned** (too little detail it shares with its neighbour, as in a nearly black shot of a night sky), the dialog says so. If it looks within a pixel or so of the others it is merged where it is; if it looks further out it is left out of the merge, because doubled edges look worse than the few highlights or shadows it would have added. Its warning says which.
- **Turn it off** only if you want to see a bracket exactly as shot, or to compare. With it off, the dialog warns when the shots don't line up.
- **It can't fix everything that moved.** It moves each whole shot, so things at different distances that shift against each other (a pole close to a handheld camera against the street behind it) and things that moved by themselves still differ between shots. Deghost is for those.

## Deghost

A *ghost* is something that moved between the shots: a person walking, leaves in the wind, a wave. Merged as it is, it shows up several times, half transparent, or smeared. **Deghost** finds the parts of the picture that changed between the shots and takes each of them from one shot only (the reference photo wherever it shows that part well), so the moving thing appears once.

The cost is noise and range in those parts: they come from one shot instead of several, so shadows there can look noisier and very bright or very dark parts of the moving thing may clip. That is why it starts at **None**, as in Lightroom.

| Level | What it catches | Use it for |
|---|---|---|
| **None** | Nothing | Still scenes: architecture, interiors, landscapes on a calm day. |
| **Low** | Only large, clear changes, such as a dark coat crossing a pale wall | A person or car passing through an otherwise still scene. |
| **Medium** | Most movement, including leaves and water that change the brightness noticeably | Trees in a breeze, waves, busy streets. A good first try when something moved. |
| **High** | Faint changes too: ripples, thin branches | Scenes where Medium still leaves soft or doubled patches, if you accept more noise in them. |

What to expect:

- **Deghost compares brightness, not colour.** Something that moved in front of a background just as bright (a blond head in front of a sunlit wall) can go unnoticed and still look doubled or transparent. Try a higher level; if that doesn't help, a merge without it may look softer but more natural.
- **Deghost takes a little longer**: each shot is read once more to look for movement.
- **Use Auto Align with it.** Without alignment, a shot that moved differs from the reference everywhere, and Deghost would take almost the whole picture from one shot.

### Show Deghost Overlay

With a Deghost level chosen, **Show Deghost Overlay** marks the preview where deghosting took the picture from a single shot. Each such area is **outlined** (a white line with a black line inside it, visible on bright skies and dark streets alike) and **tinted** in the colour of the shot it now comes from; the same colour shows as a dot beside that shot in the list, and VoiceOver reads it with the row ("overlay colour orange"). Where two such areas meet, the line between them is drawn too.

The colours are orange, sky blue, bluish green, yellow, blue, vermillion and reddish purple, in that order down the list (starting again after the seventh). They are the Okabe–Ito colours, chosen to stay distinguishable for the common kinds of colour blindness, and since every area is outlined, the shapes read even without telling the colours apart. The tint is translucent, so the picture shows through.

## The merged photo

**Where it goes.** Into the reference photo's folder, named after it: `DSC_0107.NEF` gives `DSC_0107-HDR.dng`. If that name is taken, by a file or by a sidecar left behind by one, the next free name is used: `DSC_0107-HDR-2.dng`, `-HDR-3` and so on. Nothing is ever overwritten.

**What it is.** A DNG, the open raw format. It holds the merged light itself, not a finished picture: white balance, exposure, highlights and every other adjustment still work on it as on a camera raw, with the extra range to use. It opens in Latent like any photo, and in Lightroom and Apple Photos too.

**Your edits.** The merge starts from the original raw files; edits you made to the bracket's photos aren't used. The merged photo starts unedited, at the reference photo's exposure and white balance, and the original photos are left as they were.

**Auto Settings.** With **Auto Settings** on, the merged photo opens with Develop's **Auto Adjust** (⌘U) already applied: the same exposure, contrast and white balance you would get by opening it and pressing ⌘U. It is stored as the photo's first edit, in its sidecar beside the merge's record, so Develop's history starts at "Original" and **Undo** takes it back to the merge as it came out.

**Lens corrections.** They are not baked in. The merged photo keeps the lens's identity, so Develop's lens corrections (distortion, vignetting, chromatic aberration) apply to it once, as they would to the reference photo.

**Size.** The file is uncompressed half floats, about 6 bytes per pixel: a merge of 24 MP photos is roughly 145 MB, of 45 MP photos about 270 MB. Latent checks the disk has room before writing.

**What made it.** The photo's sidecar and the DNG itself record which photos were merged (by path and fingerprint), when they were taken, and how: the Deghost level, whether Auto Align was on, how far it moved each shot and which shots it left out. That is a record only: Latent can't yet re-run a merge from it.

## Current limits

- **Auto Align moves whole shots.** Near and far things that shifted against each other in a handheld bracket (parallax) still show slightly doubled edges, and a shot it can't align is merged as it is or left out.
- **Deghost compares brightness only,** so movement against an equally bright background can slip through, and deghosted parts come from one shot, with that shot's noise.
- **HDR only.** Panorama and HDR Panorama are coming.
- **Raw files only,** from Bayer sensors. X-Trans, monochrome and already-merged files can't be merged, and all photos must come from the same camera at the same size and orientation.
- **The preview is small,** about 1,000 pixels across; to judge fine detail, merge and look at the result.
- **On Macs with 8 GB of memory,** a merge takes at most 5 photos.

See also [Limitations](Limitations) and [Keyboard Shortcuts](Keyboard-Shortcuts).
