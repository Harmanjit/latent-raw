# Export

Select images in the Library and press ⇧⌘E (File > Export), or right-click the selection and choose Export. To export the image open in the editor, use Export open image… in the left panel's Export section (File > Export Open Image…); that one asks for a file name, uses the panel's format and quality, always writes full size in sRGB, and follows the panel's **Include camera metadata** and **Include location** switches, which work as the sheet's do and are remembered.

## The sheet

**File.** JPEG, HEIC, PNG, or 16-bit TIFF. Quality for the lossy formats. Colour space sRGB or Display P3, tagged with the matching profile. Optional resize to a long edge: the render bins the sensor data towards the target size, then shrinks to the exact size with a Lanczos 3 filter in linear light, so fine detail doesn't alias.

**HDR gain map** (JPEG and HEIC, off by default). Adds a gain map so HDR screens show highlights up to two stops above white, as the editor's HDR display shows them. Every other viewer, and the file's main image, shows the normal SDR export. It costs a second render of the image. PNG and TIFF have nowhere to put one.

**Metadata.** On by default: the file keeps the photo's own camera and lens details, capture time, artist and copyright, and other IPTC and XMP fields from the raw. Latent's keywords are added to the file's own, and its rating replaces the file's when there is one. Tags that only describe the raw's storage (orientation, sensor layout, autofocus points), makers' private data and Camera Raw's edit settings are left out. Turn **Include camera metadata, keywords and rating** off to write none of it.

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

## The queue

Exports run one at a time in the background, since a full-resolution render already saturates the GPU. Progress and any failures show in the left panel; each failure names the file and the reason. A file whose stored edit cannot be read is not exported unedited; it is reported.

Each file is written under a hidden temporary name and moved into place only when complete, so a crash, a full disk or a cancelled export never leaves a half-written file, and a file being replaced stays intact until the new one is ready. A replaced file keeps its Finder tags.

Quitting during an export asks whether to finish the image being written and quit, or keep exporting. An export stopped this way doesn't bring Finder forward. Quitting during Export open image… asks too: let the file finish and quit, or keep working. If a file still isn't done after a minute, quitting goes ahead and removes the unfinished temporary file.

Model-generated masks and AI denoise are recomputed at export time, for the queue and for Export open image alike, so the file matches the screen.
