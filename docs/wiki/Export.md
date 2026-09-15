# Export

Select images in the Library and press ⇧⌘E (File > Export), or right-click the selection and choose Export. To export the image open in the editor, use Export open image… in the left panel's Export section (File > Export Open Image…); that one asks for a file name, uses the panel's format and quality, always writes full size in sRGB, and follows the panel's **Include camera metadata** and **Include location** switches, which work as the sheet's do and are remembered. Its **Add watermark** switch stamps the watermark last saved from the export sheet; the sheet saves its settings when an export starts.

## The sheet

**File.** JPEG, HEIC, PNG, or 16-bit TIFF. Quality for the lossy formats; **Compare…** beside it opens the quality comparison (below). Colour space sRGB or Display P3, tagged with the matching profile. Optional resize to a long edge: the render bins the sensor data towards the target size, then shrinks to the exact size with a Lanczos 3 filter in linear light, so fine detail doesn't alias.

**HDR gain map** (JPEG and HEIC, off by default). Adds a gain map so HDR screens show highlights up to two stops above white, as the editor's HDR display shows them. Every other viewer, and the file's main image, shows the normal SDR export. It costs a second render of the image. PNG and TIFF have nowhere to put one.

**Metadata.** On by default: the file keeps the photo's own camera and lens details, capture time, artist and copyright, and other IPTC and XMP fields from the raw. Latent's keywords are added to the file's own, and its rating replaces the file's when there is one. Tags that only describe the raw's storage (orientation, sensor layout, autofocus points), makers' private data and Camera Raw's edit settings are left out. Turn **Include camera metadata, keywords and rating** off to write none of it.

**Watermark.** Off by default. Switch it on to stamp one line of text into a corner of every exported file. `{year}` becomes the capture year and `{name}` the original file name, in any letter case. Size is a share of the picture's short edge (1–20%), so the watermark looks the same at any export size; opacity and colour are adjustable, and the colour is picked as sRGB and converted for Display P3 exports. It is drawn into the file after the resize, never into the photo or its edit. In a file with an HDR gain map the text is not brightened on HDR screens. Presets remember the watermark text even while the switch is off.

**Location.** Off by default, and in presets saved before it existed. Turn **Include location** on to also keep the **GPS position**, place names, and the camera body's and lens's serial numbers; see [Security and Privacy](Security-and-Privacy#location-in-exports).

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

**Destination.** A folder, remembered between exports and defaulting to the one in Settings. Optionally sort into subfolders by capture date. Optionally show the results in Finder when done.

**Presets.** Save the current sheet under a name; four built-ins cover web at 2048 px, full-size JPEG, print TIFF in P3, and proofs by date.

**Estimated size.** The sheet renders and encodes the first selected image at the current settings and scales that by each other image's pixel count. Crops and detail vary from photo to photo, so a batch total is approximate; for a single image it is the real file size. Changing only the quality or JPEG versus HEIC re-encodes without rendering again.

**Compare qualities.** **Compare…** next to Quality (JPEG and HEIC) opens a window with the first image encoded at two to four qualities side by side at 100%. Drag any pane to pan them all. Each pane shows the size of the whole file at that quality, and **Use** sets the sheet's quality. JPEG panes look exactly as the file will; the edges of HEIC panes can differ slightly. The window closes with the sheet.

## The queue

Exports run one at a time in the background, since a full-resolution render already saturates the GPU. While the queue, Export open image…, Edit in External Editor, a print, a contact sheet or AI noise reduction runs, the Mac doesn't go to sleep on its own; the display still can. Progress and any failures show in the left panel; each failure names the file and the reason. A file whose stored edit cannot be read is not exported unedited; it is reported.

Each file is written under a hidden temporary name and moved into place only when complete, so a crash, a full disk or a cancelled export never leaves a half-written file, and a file being replaced stays intact until the new one is ready. A replaced file keeps its Finder tags.

Quitting during an export asks whether to finish the image being written and quit, or keep exporting. An export stopped this way doesn't bring Finder forward. Quitting during Export open image… asks too: let the file finish and quit, or keep working. If a file still isn't done after a minute, quitting goes ahead and removes the unfinished temporary file. Quitting while a contact sheet is being saved asks whether to stop it (it isn't saved); while a print is rendering, whether to let it reach the printing system and then quit.

Model-generated masks and AI denoise are recomputed at export time, for the queue and for Export open image alike, so the file matches the screen.

## Print

**File > Print…** (⌘P) prints the selection in the Library and Survey, and the image shown in Loupe, Compare and Develop, with its current edit, saved or not.

The print panel's **Photo Layout** section sets photos per page (1, 2, 4, 6, 9, 12, 20 or 30), Fit or Fill, whether to rotate photos to fill their cells, margins, spacing, captions (file name, and optionally date and camera) and colour. The panel's preview updates as you change them, drawn from thumbnails.

Photos are rendered for the printer as an export is: model masks regenerated and AI noise reduction included, at the printer's resolution (150 to 360 dpi) in 16-bit Display P3. If Soft Proof is on in Develop with an ICC profile, Colour starts at that profile and photos are converted into it (perceptual intent), so the print matches the proof. A photo that can't be rendered (its file was moved or can't be read) prints as an empty cell, and Latent names it once the print is done; Rename, Move and Copy wait while a print or contact sheet renders. The layout settings are remembered, and the paper, orientation, scale and printer carry over to the next print.

## Contact sheets

**File > Contact Sheet…** lays out the selection on one PDF with as many pages as it needs, or on one JPEG or PNG holding every photo.

It sets the page size (A4, A3, US Letter or Tabloid at 300 dpi, a 4K display, or a custom size up to 8192 px) and orientation, background, columns, rows per page (PDF only; 0 puts every photo on one page), spacing and margin in pixels, Fit or Fill, a title (the folder's name to start with), captions and their text size, page numbers (PDF only), and sRGB or Display P3. The preview shows page 1.

**Save** asks where. Photos are rendered at the size of their cells, with AI noise reduction only for cells 1600 px or larger. The file is written under a temporary name and moved into place, so pressing Stop writes nothing and never costs a file you agreed to replace. The status bar names any photos that couldn't be rendered.

## Edit in External Editor

**File > Edit in External Editor…** (⌘E; the menu item carries the application's name once one is chosen) makes a 16-bit Display P3 TIFF of the open image, or in the grid the lead selected image (in Survey, the outlined pane), with its edits, including masks and AI noise reduction. Its metadata and location follow Export open image…'s switches; no watermark is added. The file is named `<name>-Edit.tif`, numbered (`-Edit-2.tif`) rather than replacing anything.

It goes to the folder set in **Settings › External Editor**, else the default export folder, else a folder you are asked for once. It then opens in the application chosen there (by default, the one your Mac opens TIFFs with), and the status bar says where it went. Latent doesn't catalog the TIFF or watch it for changes.
