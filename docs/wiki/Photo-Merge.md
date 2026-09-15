# Photo Merge

**Photo › Photo Merge** combines two or more photos into one new photo file. This version does **HDR**: several shots of the same scene at different exposures become one photo with the shadows of the bright shots and the highlights of the dark ones. Panorama and HDR Panorama are coming.

## What HDR merge does

A camera can't record the whole range of light in some scenes. Point it out of a window, or at a sunset behind trees, and either the sky turns pure white or the shadows turn black. When a part of the photo has hit the sensor's maximum it is *clipped*: the detail there is gone, and no slider brings it back.

A *bracket* is the answer: the same scene shot several times, each at a different exposure. The bright shots see into the shadows; the dark shots keep the highlights. Latent's HDR merge reads the raw files of the bracket and, pixel by pixel, takes the light from the shots that recorded it best. The result is one raw-like photo with far more range than any single shot, which you then edit as usual: pull the highlights down, lift the shadows, and nothing is clipped.

*EV* (exposure value) counts exposure in *stops*. One stop is double or half the light, so a shot at +2 EV has four times the light of the one at 0 EV.

## Shooting a bracket

- **Use a tripod.** The shots must line up exactly. This version doesn't align handheld shots yet (see Current limits, below).
- **Focus manually,** or focus once and switch autofocus off, so the focus doesn't move between shots.
- **Use aperture priority (A or Av) or manual,** so the aperture, and with it the depth of field, stays the same. Let the shutter speed change the exposure. Keep the ISO fixed.
- **Turn on your camera's auto exposure bracketing (AEB)** if it has one, and set it to **2 EV steps** with **3 or 5 frames**: for example −2, 0 and +2 EV. Five frames at 2 EV cover very bright scenes; three are enough for most.
- **Use the self-timer or a remote,** so pressing the button doesn't shake the camera.
- **Avoid moving things** where you can: people, cars, leaves in wind and clouds move between shots. This version doesn't remove the ghosts they leave.
- **Shoot raw.** Photo Merge reads raw files only (Bayer sensors; not Fujifilm X-Trans).

## Merging

1. In the Library grid, select the photos of one bracket (click the first, Shift-click the last).
2. Choose **Photo › Photo Merge › HDR…**, or press **⌃H**. It needs two or more selected photos. In Loupe, Compare, Survey and Develop it merges the photos you selected in the grid, as Export does.
3. The **HDR Merge** dialog reads the photos for a moment, then lists them brightest first. Each row shows the shutter speed, aperture and ISO, and how many stops brighter or darker it is than the **Reference** photo. The reference is the frame with the fewest clipped and black pixels, chosen for you; the merged photo opens looking like it.
4. Below the list are the merged photo's size in pixels and megapixels, roughly how large the file will be, and its name.
5. Read any warning. The most common is that the photos don't line up exactly, which usually means the camera moved.
6. Press **Merge** (Return). The dialog closes and the merge runs in the background. Its progress shows in the left panel's **Export** section, with a **Cancel** button. Esc or **Cancel** in the dialog closes it without merging.

If the photos can't be merged (they are from different cameras, different sizes, or all the same exposure, say) the dialog says why and offers only **Close**.

When the merge finishes, the new photo is selected in the grid, and VoiceOver says "HDR merge finished" with its name. If a filter would hide it, the filter is cleared. If something goes wrong, the reason shows in the status bar and nothing is left behind.

A merge takes turns with exports: Export waits while a merge runs, and a merge can't start during an export. Quitting during a merge asks first; quitting stops the merge, and neither a half-made photo nor its sidecar is left.

## The merged photo

**Where it goes.** Into the reference photo's folder, named after it: `DSC_0107.NEF` gives `DSC_0107-HDR.dng`. If that name is taken, by a file or by a sidecar left behind by one, the next free name is used: `DSC_0107-HDR-2.dng`, `-HDR-3` and so on. Nothing is ever overwritten.

**What it is.** A DNG, the open raw format. It holds the merged light itself, not a finished picture: white balance, exposure, highlights and every other adjustment still work on it as on a camera raw, with the extra range to use. It opens in Latent like any photo, and in Lightroom and Apple Photos too.

**Your edits.** The merge starts from the original raw files; edits you made to the bracket's photos aren't used. The merged photo starts unedited, at the reference photo's exposure and white balance, and the original photos are left as they were.

**Lens corrections.** They are not baked in. The merged photo keeps the lens's identity, so Develop's lens corrections (distortion, vignetting, chromatic aberration) apply to it once, as they would to the reference photo.

**Size.** The file is uncompressed half floats, about 6 bytes per pixel: a merge of 24 MP photos is roughly 145 MB, of 45 MP photos about 270 MB. Latent checks the disk has room before writing.

**What made it.** The photo's sidecar and the DNG itself record which photos were merged (by path and fingerprint), when they were taken, and how. That is a record only: Latent can't yet re-run a merge from it.

## Current limits

- **No alignment.** Shots that moved, even slightly, give doubled edges. Use a tripod; the dialog warns when the photos don't line up.
- **No deghosting.** Anything that moved between shots appears semi-transparent.
- **HDR only.** Panorama and HDR Panorama are coming.
- **Raw files only,** from Bayer sensors. X-Trans, monochrome and already-merged files can't be merged, and all photos must come from the same camera at the same size and orientation.
- **The reference is chosen automatically;** you can't pick another yet.
- **On Macs with 8 GB of memory,** a merge takes at most 5 photos.

See also [Limitations](Limitations) and [Keyboard Shortcuts](Keyboard-Shortcuts).
