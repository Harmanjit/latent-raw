# Export

Select images in the Library and press ⌘⇧E, or export the open image from the left panel in Develop.

## The sheet

**File.** JPEG, HEIC, PNG, or 16-bit TIFF. Quality for the lossy formats. Colour space sRGB or Display P3, tagged with the matching profile. Optional resize to a long edge; resized exports bin the sensor data on the GPU rather than resampling a full render, which is both faster and a correct box filter. A toggle strips camera metadata, keywords and rating.

**Naming.** A template with tokens, expanded per image:

| Token | Meaning |
|---|---|
| `{name}` | original file name without extension |
| `{seq}` | position in the batch, from a chosen start, zero-padded |
| `{date}` | capture date, yyyy-MM-dd |
| `{time}` | capture time, HHmmss |
| `{camera}` | camera model |
| `{rating}` | stars as a digit |
| `{folder}` | the image's subfolder, or the catalog name |

A live line shows the first file's name. If a file already exists: add a number, replace, or skip.

**Destination.** A folder, remembered between exports and defaulting to the one in Preferences. Optionally sort into subfolders by capture date. Optionally show the results in Finder when done.

**Presets.** Save the current sheet under a name; four built-ins cover web at 2048 px, full-size JPEG, print TIFF in P3, and proofs by date.

## The queue

Exports run one at a time in the background, since a full-resolution render already saturates the GPU. Progress and any failures show in the left panel; each failure names the file and the reason. A file whose stored edit cannot be read is not exported unedited; it is reported.

Model-generated masks and AI denoise are recomputed at export time so the file matches the screen.
