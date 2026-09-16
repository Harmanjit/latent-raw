# Photo Merge

**Photo › Photo Merge** combines two or more photos into one new photo file. It does three kinds of merge:

- **HDR** (**⌃H**): several shots of the same scene at different exposures become one photo with the shadows of the bright shots and the highlights of the dark ones.
- **Panorama** (**⌃M**): overlapping shots taken while turning the camera become one wide photo.
- **HDR Panorama** (**⌃⇧M**, **experimental**): a bracket at each position of a sweep — every bracket merged to HDR, then the results stitched.

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

- **Deghost compares brightness and colour,** and takes each moving thing whole from one photo, so a person walking through the scene appears once. What it still can't fix is *parallax*: when the camera itself moved, near objects shift against the background and no single photo matches, so edges there can stay doubled. A tripod avoids this.
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

## Panorama

A **panorama** is made from several photos taken while turning the camera, each overlapping the one before. Latent works out where the camera was pointing for every shot, warps them all onto one curved surface and blends them into a single wide photo.

Choose **Photo › Photo Merge › Panorama…**, or press **⌃M**, with two or more photos selected.

### Shooting a sweep

- **Overlap about 30%.** Each shot should share roughly a third of its frame with the one before. Too little overlap and Latent can't tell how two shots fit together; much more and you are making work for nothing. Overlap is what a panorama is built from — it matters more than anything else here.
- **Turn the camera, don't walk it sideways.** Turn about the camera itself (ideally about the lens, not your shoulder). When the camera moves sideways instead, near things shift against far things — that is *parallax*, and no stitcher can make near and far line up at once. Edges close to the camera then look doubled. A tripod, turned on the spot, gives the cleanest sweep; handheld, keep your feet still and turn your body.
- **Set the exposure by hand** (manual, or lock it) and keep the same aperture and ISO for the whole sweep. If the camera meters each shot, the sky changes brightness across the panorama; Latent evens the shots out and still warns you when they were too far apart.
- **Focus once, then switch autofocus off,** so the focus doesn't hunt between shots.
- **Keep the camera level** and turn steadily, one direction only. Portrait orientation gives a taller panorama for the same number of shots.
- **Avoid moving things** in the overlaps where you can — a person walking through the seam is the hardest thing to hide.
- **Shoot raw.** Photo Merge reads raw files only (Bayer sensors; not Fujifilm X-Trans). All the shots must come from the same camera, at the same focal length.

### Merging a panorama

1. Select the photos of one sweep in the grid. The order doesn't matter: Latent sorts them by the time they were taken.
2. Press **⌃M**. The **Panorama** dialog reads the photos and works out the layout — on a long sweep this takes a little while.
3. The dialog shows a **preview** of the stitch at the top, and below it the photos **in the order they were taken**. Each row gives the shutter speed, aperture and ISO, **where that photo points** across the panorama ("36° left", "centre", "12° right") and **how much its brightness is corrected** to match the others ("−0.3 EV"). A photo that couldn't be joined is dimmed and marked **Left out**.
4. Beside the list: the **Projection**, **Auto Crop** and **Auto Settings**, and then the size the panorama will really be, how wide and tall the sweep is in degrees, roughly how large the file will be, and its name.
5. Press **Merge** (Return). The dialog closes and the stitch runs in the background, with its progress and a **Cancel** button in the left panel's **Export** section.

The merge starts from the original raw files; edits you made to the photos aren't used.

If the photos don't form a panorama — they don't overlap, or they come from different cameras — the dialog says why and offers only **Close**.

### Projection

A panorama covers directions, not a flat rectangle, so it has to be flattened somehow. That choice is the **projection**, and it changes the shape of the whole picture.

| Projection | What it does | Use it for |
|---|---|---|
| **Automatic** | Latent picks: Perspective for a narrow sweep, Cylindrical for a wide one | Leave it here unless you want a particular look. |
| **Perspective** | Straight lines stay straight | Narrow sweeps, buildings. Stretches badly past about 70° across. |
| **Cylindrical** | Wraps around like a label on a can; upright things stay upright | Most panoramas: landscapes, streets. |
| **Spherical** | Bends both ways | Very tall sweeps, or a full circle. Horizons curve. |

Changing the projection measures the photos again, so the preview, the size and the warnings all follow it.

### Auto Crop

A stitched panorama has ragged, empty edges: the shots don't line up into a neat rectangle. **Auto Crop** (on unless you turn it off) finds the largest rectangle with no empty edge in it and opens the panorama cropped to it.

It is an ordinary **crop edit**, not a cut: the whole stitch is in the file. **Undo** in Develop takes the crop off, and the crop tool (**R**) drags it out again — useful when you would rather fill a corner by hand than lose the rest of the sky.

### Photos that were left out

Latent joins the photos pair by pair. When a photo shares too little with its neighbours — a gap in the sweep, a blurred frame, a shot of your feet between two sweeps — it can't be placed, and it is **left out**: marked in the list and named in a warning. The panorama is made from the rest. If a photo you wanted is left out, the usual reason is too little overlap; reshoot that part with more.

The result is named after the **first photo that was joined**: `HSB_6554.NEF` gives `HSB_6554-Pano.dng`, then `-Pano-2` and so on if that name is taken. Nothing is ever overwritten.

### Why a big panorama is made smaller

Seventeen 24 MP photos across 186° can add up to a canvas of 29,195 × 7,664 pixels — 224 megapixels, several times what any Mac can hold in memory while you edit it with a brush and a history.

**Latent never refuses a panorama for its size.** Instead the dialog tells you exactly what will happen, in the panorama's own numbers:

> This panorama would be 29,195 × 7,664 pixels (224 MP). The largest this Mac can edit is 12,482 × 3,276 (41 MP), limited by memory, so the photos will be merged at 43%.

Turn on **Merge at 43%** to agree, and the button becomes **Merge at 43%** too, so it says what it is about to do. The limit is worked out for *this* Mac — its memory, and the largest picture its graphics processor can hold — so the same sweep may merge whole on a bigger machine and smaller on a laptop. Latent never offers a size it couldn't then edit.

What you lose is resolution, not field of view: the whole sweep is there, at 43% of the pixels along each edge, which is still a photo far wider than any single frame. What you gain is a panorama you can actually work on.

Agreeing is asked for every time, and again whenever the size changes (after switching projection, say).

### The stitched photo

**What it is.** A DNG, as an HDR merge is: the merged light itself, not a finished picture, so white balance, exposure and every other adjustment work on it as on a camera raw. It opens in Latent, Lightroom and Apple Photos.

**Lens corrections are baked in.** A panorama has to be lens-corrected before it can be stitched, so distortion, vignetting and chromatic aberration are already taken out and Develop doesn't apply them again.

**Its first edit.** With **Auto Crop** on, the crop is stored as the panorama's first edit; with **Auto Settings** on, Develop's **Auto Adjust** (⌘U) is stored too. Both are one edit, so a single **Undo** in Develop takes you back to the stitch exactly as it came out.

**What made it.** The panorama's sidecar and the DNG record which photos were stitched (by path and fingerprint) and how. That is a record only: Latent can't yet re-run a merge from it.

## HDR Panorama (experimental)

**Photo › Photo Merge › HDR Panorama… (Experimental)**, **⌃⇧M**.

Shoot a bracket at each position of a sweep — say −2, 0 and +2 EV, then turn the camera and do it again — select the lot, and Latent merges each position to HDR and stitches those results into one panorama.

> **Experimental, and this is what that means.** Nobody has shot a real HDR panorama for Latent to be tested against, and no freely licensed set exists, so every test is either synthetic or built by cutting overlapping windows out of a real bracket. The pieces it is made of — the HDR merge and the panorama stitch — are each well tested on real photos, and the two stages together are tested end to end on those stand-ins. What has **not** been checked is a real bracketed sweep: light that changes while you turn, parallax between near and far things across several positions, and brackets whose frames drift from position to position. Look at the result before you trust it, and tell Harman how it went.

### How the positions are worked out

Latent has to decide which photos belong together before it can merge anything. It uses three kinds of evidence, in this order:

1. **The repeating exposures.** A bracketed sweep is the same bracket over and over: −2, 0, +2, −2, 0, +2… The shortest run of different exposures that repeats through the whole selection is the bracket. This is the strongest evidence there is.
2. **The gaps between shots.** A bracket is shot in a burst; turning to the next position takes seconds. When the gaps fall into two clear groups, the long ones are the moves. (Cameras stamp whole seconds, so a burst's gaps are often all zero — that is still a clear split.)
3. **How much consecutive photos overlap.** Asked for only when the first two say nothing, because it means reading every photo: a bracket's frames show nearly the same view, a new position is a big jump.

If the exposures and the timing disagree, the exposures win, and the dialog says so.

**What it copes with:**

- Any number of exposures at any number of positions, as long as each position has the same ones.
- **Uneven brackets:** a position with more or fewer exposures than the rest, when the timing makes the positions clear. The dialog warns; that position simply has less range.
- **A stray single photo** with no bracket around it: it becomes a position of its own and goes into the panorama as it is, since there is nothing to merge it with.
- **Photos you merged earlier.** An HDR you made before (a `-HDR.dng`) counts as a finished position, and can sit beside brackets that are merged now, as in Lightroom. Auto Align and Deghost don't apply to it: it was merged with whatever settings it was merged with.

If none of the evidence can tell, Latent refuses rather than guessing: *"These don't look like brackets: each position needs the same exposures."* Shoot the same bracket at every position, or merge each bracket with **HDR…** first and then stitch the results with **Panorama…**.

### The dialog

It lists the positions it found, the photos at each one and the exposures they were shot at, and where each position points. Above the list it says what it decided — "3 exposures at each of 5 positions, from the repeating exposures and the gaps between shots" — so you can see at a glance whether it read your sweep correctly.

The options are both parents' put together:

- **Auto Align** and **Deghost** apply to every position's own merge (see [Auto Align](#auto-align) and [Deghost](#deghost) above).
- **Projection**, **Auto Crop** and **Auto Settings** apply to the stitch (see [Panorama](#panorama)).
- If the result would be bigger than this Mac can edit, the same agreement appears as for a panorama: Latent says what it will make instead and waits for you to agree. It never refuses a panorama for its size.

There is **no preview**. The HDR dialog previews reduced frames and the Panorama dialog previews the real stitch of reduced frames; an HDR panorama's preview would have to merge every position first, which is most of the work. Rather than show a picture that isn't what you will get, the dialog shows what it found and what it will do.

### While it runs

The merge happens in the background, like the other two, and the library panel shows both stages: "Merging bracket 2 of 5", then the stitch. It takes one GPU job slot, so exports and other merges wait.

**It needs room on disk.** Each position is merged to a temporary DNG first, and those are handed to the stitcher — the same path an HDR you merged earlier takes, so nothing new happens to your pixels. Five positions of 24 MP photos need about 725 MB of temporary space, which the dialog tells you about beforehand and which is given back when the merge ends, however it ends.

### The result

**`<first photo>-HDRPano.dng`**, beside the first photo, and it is a panorama in every other way: lens corrections baked in, Auto Crop as an undoable first edit, the full merged range of light in the pixels. Its recipe records **every photo you selected** — not the temporary merges — which positions they fell into, and both stages' settings.

## Current limits

- **Auto Align moves whole shots.** Near and far things that shifted against each other in a handheld bracket (parallax) still show slightly doubled edges, and a shot it can't align is merged as it is or left out.
- **Deghost compares brightness only,** so movement against an equally bright background can slip through, and deghosted parts come from one shot, with that shot's noise.
- **Panoramas are one row.** A single sweep left to right (or right to left). Several rows stacked into a grid, and full 360° panoramas that join back to their start, aren't there yet.
- **Parallax.** Neither merge can fix near things shifting against far things when the camera itself moved. Turn the camera on the spot.
- **HDR Panorama is experimental** and has never been checked on a real bracketed sweep (see above). It also inherits every limit of both its parents, and adds one: the positions must be told apart from the exposures, the timing or the overlap, so a sweep shot with a different bracket at each position can't be read.
- **Raw files only,** from Bayer sensors. X-Trans, monochrome and already-merged files can't be merged, and all photos must come from the same camera at the same size and orientation.
- **The preview is small,** about 1,000 pixels across; to judge fine detail, merge and look at the result.
- **On Macs with 8 GB of memory,** a merge takes at most 5 photos.

See also [Limitations](Limitations) and [Keyboard Shortcuts](Keyboard-Shortcuts).
