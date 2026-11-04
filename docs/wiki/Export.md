# Export

Select images in the Library and press ⇧⌘E (File > Export), or right-click the selection and choose Export. To export the image open in the editor, use Export open image… in the left panel's Export section (File > Export Open Image…); that one asks for a file name, uses the panel's format and quality, always writes full size in sRGB, and follows the panel's **Include camera metadata** and **Include location** switches, which work as the sheet's do and are remembered. Its **Add watermark** switch stamps the watermark last saved from the export sheet; the sheet saves its settings when an export starts.

## The sheet

**Format.** JPEG, HEIC, PNG or TIFF on every Mac; AVIF and JPEG XL as well when the Mac's system can write them (the menu only lists what works). Two more choices don't render an image file at all: **DNG** and **Original + XMP sidecar** (below). Quality for the lossy formats; **Compare…** beside it opens the quality comparison (below) for JPEG and HEIC.

**Limit file size.** For the lossy formats: the quality is lowered, photo by photo, until the file is no bigger than the size given (in KB). A photo that doesn't fit even at the lowest quality is reported and not written; export it smaller.

**TIFF.** 16 bits per channel (smooth gradients for further editing) or 8 (half the size), and compression None, LZW or ZIP. All three are lossless; ZIP is usually smallest, LZW is read by the most software.

**Colour space.** sRGB (safe for the web and anyone's screen), Display P3 (wider, for modern Apple screens), **Adobe RGB (1998)** (what print labs usually ask for), **ProPhoto RGB** (the widest, for 16-bit files going on to another editor), any RGB profile installed on the Mac (a printer or paper profile, listed from the ColorSync folders), or **Other…** to pick a profile file. Every file embeds its profile. Adobe RGB, ProPhoto and installed profiles are made by rendering the photo in Latent's wide working space at 16 bits and converting it with macOS's ColorSync, so nothing bands on the way; a printer or paper profile converts with perceptual intent. ProPhoto in an 8-bit file can band in smooth skies, and the sheet says so. A gain map is written only in sRGB or Display P3.

**HDR gain map** (JPEG and HEIC, off by default). Adds a gain map so HDR screens show highlights above white up to the photo's HDR Limit (two stops unless changed in Develop, see [HDR Limit](Develop#hdr-limit)), as the editor's HDR display shows them. Every other viewer, and the file's main image, shows the normal SDR export. It costs a second render of the image. PNG and TIFF have nowhere to put one.

**Image sizing.** Off, the file is the photo's full cropped size. **Resize to fit** by:

| Fit | Means |
|---|---|
| Long edge | the longer side in pixels |
| Short edge | the shorter side in pixels |
| Width & height | fits inside a box, width across and height down, as given |
| Dimensions | fits inside a box whichever way the photo is turned: the larger number limits the long side |
| Megapixels | the whole picture scaled to that many million pixels |
| Percentage | the whole picture scaled by that share of its full size |

**Don't enlarge** (on by default) writes a photo that is already smaller than the size asked for at its own size. Off, it is enlarged. Either way the render bins the sensor data towards the target size, then sizes it exactly with a Lanczos 3 filter in linear light, so fine detail doesn't alias.

**Resolution.** The pixels per inch written into the file (240, 300 and 360 are a click away). It changes no pixel; it tells other apps and print labs how big the print is, and matte and glossy sharpening use it. Off writes none, as before.

**Sharpen for.** Output sharpening, a last sharpen made for where the file goes, applied after the resize so it suits the file's own pixels: **Screen**, **Matte paper** or **Glossy paper**, at **Low**, **Standard** or **High**. Screen is a light touch. Matte paper gets the most, because ink spreads into uncoated paper; glossy a little less. For paper the radius grows with the resolution (300 ppi when none is set). It sharpens brightness only, so colours don't fringe, and leaves very small differences alone so skies stay smooth. The edit's own sharpening in Develop is unchanged.

**Metadata.** What the file carries besides pixels:

| Choice | Writes |
|---|---|
| All | the photo's own camera and lens details, capture time, artist and copyright and other IPTC and XMP fields from the raw, plus Latent's keywords (added to the file's own), its rating (replacing the file's when there is one), and the title, caption, creator and copyright you gave it |
| All except camera info | the same without the camera's make and model, the lens, the exposure settings, maker notes and serial numbers |
| Copyright and contact | only the copyright notice, the creator and their contact details |
| Copyright only | only the copyright notice |
| None | nothing |

A keyword inside others (Places › France › Paris) is written as each of its levels. The title, caption, creator and copyright you gave the photo in the Library panel's **Title & Copyright** section replace the raw's own: they go in the IPTC fields (Object Name, Caption/Abstract, By-line, Copyright Notice), the TIFF fields (Image Description, Artist, Copyright) and XMP (`dc:title`, `dc:description`, `dc:creator`, `dc:rights`), so photo sites and other catalogs show them. Export Open Image and Edit in External Editor carry them too, unless their **Include camera metadata** switch is off.

Tags that only describe the raw's storage (orientation, sensor layout, autofocus points), makers' private data and Camera Raw's edit settings are never written. **Include location** (off by default, and in presets saved before it existed) also keeps the **GPS position**, place names, and the camera body's and lens's serial numbers, at All and All except camera info; see [Security and Privacy](Security-and-Privacy#location-in-exports).

**Watermark.** Off by default. Switch it on to stamp **Text** or a **Graphic** into a corner of every exported file. Text: one line, where `{year}` becomes the capture year and `{name}` the original file name, in any letter case, in the system font or any font installed on the Mac; its size is a share of the picture's short edge (1–20%) and its colour is picked as sRGB and converted for the file's colour space. Graphic: a PNG logo (up to 4 MB; transparent parts stay transparent), sized by its longer side as a share of the picture's short edge (2–50%). The PNG is kept in the preset, so it still works after the original file moves. Either can be turned 90°, 180° or 270° (270° runs text up the side of the picture), and has an opacity. It is drawn into the file after the resize, never into the photo or its edit, so it looks the same at any export size. In a file with an HDR gain map it is not brightened on HDR screens. Presets remember the watermark even while the switch is off.

**Naming.** A template with tokens, expanded per image. Tokens can be typed in any letter case, or picked from Insert:

| Token | Meaning |
|---|---|
| `{name}` | original file name without extension |
| `{seq}` | position in the batch: from a chosen start, going up by a chosen step, zero-padded to a chosen number of digits |
| `{date}` | capture date, yyyy-MM-dd (the file's date if unknown) |
| `{date:yyyyMMdd}` | capture date in a format of your own, using Unicode date pattern letters |
| `{time}` | capture time, HHmmss; `{time:HH.mm}` takes a format too |
| `{camera}` | camera model, spaces removed |
| `{rating}` | stars as a digit |
| `{folder}` | the image's subfolder, or the catalog name |

Dates are written the same on every Mac, whatever its region or calendar. The whole name can be made lowercase or UPPERCASE, and the extension `.jpg` or `.JPG`. A token the template doesn't know, such as `{nmae}`, is shown in red and Export stays off until it is fixed.

Every file name is planned before anything is written. A line shows the first file's name, and notes say how many images would share a name within the export (after the first, those always get a number: -1, -2…), how many names are already in the destination, and what happens to those: **Add a number**, **Replace**, or **Skip**. Each name is checked against the folder again just before its file is written, and once more as the finished file is moved into place: under Add a number or Skip, a file that took the name while the image rendered is never replaced; the image gets the next free number (and is rendered again) or is skipped.

**Destination.** **Export to** a **chosen folder** (remembered between exports, defaulting to the one in Settings), the **same folder as the original** (each file beside its photo), or **choose folder later**, which asks when the export starts: handy for presets and Export with Previous that shouldn't always land in one place. **Subfolder** puts the files in a folder of that name inside the destination (or inside each photo's folder). Optionally sort into subfolders by capture date.

**After export.** **Show in Finder when done**, and **Open in** an application you choose (Choose App…), which opens the exported files in it, as Lightroom's Open in Other Application does.

**Add to this catalog.** When an export writes into the open folder (or a subfolder it includes, as with Same folder as original), **Add to this catalog** indexes the new files as soon as the export finishes, rather than when the folder watcher next notices them, and selects them in the grid. **Stack** then puts each one in a stack with the photo it was exported from, just **above** or **below** it; the stack is left expanded so the new file shows. Files written elsewhere are left alone, and the status bar says how many. Not for Original + XMP sidecar, which is the same photo again. See [Stacks](Library#stacks).

**Presets.** Save the current sheet under a name; four built-ins cover web at 2048 px, full-size JPEG, print TIFF in P3, and proofs by date. A preset keeps every setting above, including its location.

**Export with several presets** (multi-batch). Open it at the top of the sheet and tick saved presets: one run exports the selection once with each, one preset after another, say a web JPEG and a print TIFF. A preset that writes to a chosen folder writes into a subfolder of the sheet's destination named after the preset; one set to the same folder as the original writes there; one set to choose later asks for its folder when the export starts. The sheet's own settings aren't used while presets are ticked.

**Estimated size.** For image formats, the sheet renders and encodes the first selected image at the current settings and scales that by each other image's pixel count. Crops and detail vary from photo to photo, so a batch total is approximate; for a single image it is the real file size. Changing only the quality or JPEG versus HEIC re-encodes without rendering again. With a size limit the estimate is at most the limit per file.

**Compare qualities.** **Compare…** next to Quality (JPEG and HEIC) opens a window with the first image encoded at two to four qualities side by side at 100%. Drag any pane to pan them all. Each pane shows the size of the whole file at that quality, and **Use** sets the sheet's quality. JPEG panes look exactly as the file will; the edges of HEIC panes can differ slightly. The window closes with the sheet.

## DNG export (Render to DNG)

Choosing **DNG** as the format writes a linear DNG of each photo at full size, cropped, straightened and upright. It keeps raw editing room: the pixels are 16-bit floating point linear light, with highlights above white kept. What is **baked in**: white balance, exposure, highlight recovery, noise reduction (classic and AI), lens and perspective corrections, spot healing, dust spots, red eye, blemishes and masks. What is **left out**: the look (contrast and the tone curve, Highlights to Blacks, colour grading, vibrance, texture, clarity, dehaze, defringe, skin smoothing, sharpening), since those work on finished, display-ready values a raw file doesn't hold. The DNG opens in Latent, Lightroom, Apple Photos and other raw converters with their default look, ready to be graded again; its preview shows that default look.

The DNG keeps the camera's name, its colour matrix, the lens, exposure details and capture time, and records the original it came from. Its white balance is already set, so keep it at **As Shot** when you edit it; Latent doesn't apply lens corrections to it again. Image sizing, colour space, sharpening, metadata choices and the watermark don't apply to DNG. Like merged DNGs it is large, about 6 bytes per pixel.

## Exporting originals

**Original + XMP sidecar** copies each raw file itself, byte for byte, with an `.xmp` file beside it named as Lightroom, Bridge and Capture One look for one (`DSC_0107.xmp` for `DSC_0107.NEF`). The sidecar holds the rating, colour label and keywords, which other apps read, and Latent's edit, snapshots and history. The file keeps its own extension; naming, subfolders and the existing-file choices work as for any export.

## Export with Previous

**File › Export with Previous** (⌥⇧⌘E) exports the selection again with the last export's settings and folder, without opening the sheet. A multi-batch export repeats all its presets. A folder set to choose later, or one that can no longer be reached, is asked for; cancelling stops the export.

## The queue

Exports run one at a time in the background, since a full-resolution render already saturates the GPU. While the queue, Export open image…, Edit in External Editor, a print, a contact sheet or AI noise reduction runs, the Mac doesn't go to sleep on its own; the display still can. Progress and any failures show in the left panel; each failure names the file and the reason. A file whose stored edit cannot be read is not exported unedited; it is reported.

Each file is written under a hidden temporary name and moved into place only when complete, so a crash, a full disk or a cancelled export never leaves a half-written file, and a file being replaced stays intact until the new one is ready. A replaced file keeps its Finder tags.

Quitting during an export asks whether to finish the image being written and quit, or keep exporting. An export stopped this way doesn't bring Finder forward. Quitting during Export open image… asks too: let the file finish and quit, or keep working. If a file still isn't done after a minute, quitting goes ahead and removes the unfinished temporary file. Quitting while a contact sheet is being saved asks whether to stop it (it isn't saved); while a print is rendering, whether to let it reach the printing system and then quit.

Model-generated masks and AI denoise are recomputed at export time, for the queue and for Export open image alike, so the file matches the screen.

## Print

**File > Print…** (⌘P) prints the selection in the Library and Survey, and the image shown in Loupe, Compare and Develop, with its current edit, saved or not.

The print panel's **Photo Layout** section sets photos per page (1, 2, 4, 6, 9, 12, 20 or 30), Fit or Fill, whether to rotate photos to fill their cells, margins, spacing, captions (file name, and optionally date and camera) and colour. The panel's preview updates as you change them, drawn from thumbnails.

Photos are rendered for the printer as an export is: model masks regenerated and AI noise reduction included, at the printer's resolution (150 to 360 dpi) in 16-bit Display P3. If Soft Proof is on in Develop with an ICC profile, Colour starts at that profile and photos are converted into it, so the print matches the proof. **Rendering intent** then sets how colours the profile can't reproduce are handled: **Perceptual** or **Relative Colorimetric** (with black point compensation), as described under [Soft proofing](Develop#soft-proofing). Each print starts from the intent Soft Proof is set to; changing it in the print panel applies to that print. The panel's summary lists the intent under Colour. With Colour set to Display P3, the printer's own colour matching does the conversion and the intent doesn't apply. A photo that can't be rendered (its file was moved or can't be read) prints as an empty cell, and Latent names it once the print is done; Rename, Move and Copy wait while a print or contact sheet renders. The layout settings are remembered, and the paper, orientation, scale and printer carry over to the next print.

## Contact sheets

**File > Contact Sheet…** lays out the selection on one PDF with as many pages as it needs, or on one JPEG or PNG holding every photo.

It sets the page size (A4, A3, US Letter or Tabloid at 300 dpi, a 4K display, or a custom size up to 8192 px) and orientation, background, columns, rows per page (PDF only; 0 puts every photo on one page), spacing and margin in pixels, Fit or Fill, a title (the folder's name to start with), captions and their text size, page numbers (PDF only), and sRGB or Display P3. The preview shows page 1.

**Save** asks where. Photos are rendered at the size of their cells, with AI noise reduction only for cells 1600 px or larger. The file is written under a temporary name and moved into place, so pressing Stop writes nothing and never costs a file you agreed to replace. The status bar names any photos that couldn't be rendered.

## Edit in External Editor

**File > Edit in External Editor…** (⌘E; the menu item carries the application's name once one is chosen) makes a 16-bit Display P3 TIFF of the open image, or in the grid the lead selected image (in Survey, the outlined pane), with its edits, including masks and AI noise reduction. Its metadata and location follow Export open image…'s switches; no watermark is added. The file is named `<name>-Edit.tif`, numbered (`-Edit-2.tif`) rather than replacing anything.

It goes to the folder set in **Settings › External Editor**, else the default export folder, else a folder you are asked for once. It then opens in the application chosen there (by default, the one your Mac opens TIFFs with), and the status bar says where it went. Latent doesn't catalog the TIFF or watch it for changes.
