# Keyboard Shortcuts

<!-- Generated from Sources/latent-app/Shortcuts.swift. Edit the table there, then run
     LATENT_WRITE_SHORTCUTS_PAGE=1 swift test --filter ShortcutsPageTests -->

Single keys do nothing while you type in a text field, such as search, keywords or a slider's value; click the grid or the image to get them back. The menu bar lists these commands too, with a single key after the name, as in Pick (P).

In the Library grid, stars, flags and rotation apply to every selected image. In Loupe, Compare and Develop they apply to the image shown, and in Survey to the focused pane.

## Views and navigation

| Keys | Action |
|---|---|
| G, E, C, D | Library, Loupe, Compare, Develop |
| Space | Grid ↔ Loupe |
| ←, → | Previous / next image (loads it in Loupe, Compare and Develop) |
| Return | Open the selection in Develop |
| ↑, ↓ | Pan a zoomed-in image in Loupe and Develop, and ← → too, when Settings › Library › Arrow keys pan a zoomed-in image is on (at fit ← → still step) |
| Z | Toggle fit / 100% |
| F | Full-screen image (from the grid, in Loupe): the pointer at the left, right or bottom edge brings in the library panel, Develop's adjustments or the filmstrip. F or Esc leaves |
| Two-finger swipe left / right | Next / previous image, at fit in Loupe and Develop (one image per swipe) |
| Pinch, or scroll with ⌥ or ⌘ | Zoom about the pointer |
| Double-click, or double-tap with two fingers | Toggle fit / 100% at the pointer |
| Hold the mouse button on a fitted image | Magnifier: one image pixel per point under the pointer, until you let go (not while a Develop tool is on) |
| ⌘0, ⌘1, ⌘=, ⌘- | Fit, 100%, zoom in, zoom out (in the grid, ⌘= and ⌘- size the thumbnails) |
| ⇧X | Compare: make the candidate the Select |
| N | Survey: the 2 to 4 selected images side by side (in Survey, ← and → move the focus) |
| / | Survey: take the focused image out and deselect it |
| ⇧⌘O | Open folder |
| ⌘Return | Slideshow of the selection, or of every image the filter shows (in the show: ← and → step, Space pauses, Esc ends) |
| ⌥⌘←, ⌥⌘→ | Back / forward through the folders opened, back to the images you had selected |
| ⌘, | Settings |
| ⌘? | Latent Help (these pages) |

## Rating and metadata

| Keys | Action |
|---|---|
| 0–5 | Stars |
| P, X, U | Pick, reject, unflag |
| 6–9 | Red, yellow, green, blue label (the same key again takes it off) |
| ⌘[, ⌘] | Rotate left, right |
| ⇧⌘L | Clear the filter bar |
| B | Add the selection to the target collection (the Quick Collection unless you chose another), or take it out when it is all there already |
| ⌘N | New collection (with the selected photos, if you like) |

## Editing

| Keys | Action |
|---|---|
| ⌘Z, ⇧⌘Z | Undo, redo (in Develop, the image's edit history; elsewhere, what you did in the Library, moves and renames included) |
| `\` | Before / after |
| ⌘U | Auto adjust |
| R | Crop and straighten tool |
| O, ⇧O | While cropping: the next crop guide overlay (thirds, grid, golden ratio, golden spiral, diagonal, triangle, none), and turn the spiral or triangle |
| ⌘-drag in the crop tool | Draw a line along something level or upright to straighten by it |
| H | Spot removal tool |
| Y | Red-eye tool |
| V | Develop: switch the treatment between Color and Black & White |
| W | White Balance Selector: click something neutral in the photo |
| J | Show or hide clipping on the image: highlights red, crushed shadows blue |
| [, ] | Smaller, larger brush or spot (while the mask brush, spot removal or red-eye is on) |
| ⌫ | Delete the selected spot patch or red-eye spot |
| Esc | Leave any on-image tool; with none on, leave the full-screen image |
| ⇧⌘C, ⇧⌘V | Copy / paste settings (to the whole selection in the Library) |
| ⌥⌘V | Previous: paste the settings of the photo selected before this one (all but spot removal, dust and touch-up) |
| Double-click a slider | Reset it |
| Click a slider's value | Type a value: Return or Tab applies it, Esc cancels, ↑ and ↓ step it (with ⇧, ten steps) |
| ⌥-drag the sharpening Masking slider | Show the sharpening mask while dragging: white is sharpened |

## Export

| Keys | Action |
|---|---|
| ⇧⌘E | Export the selection |
| ⌥⇧⌘E | Export with Previous: the selection, with the last export's settings and folder, without the sheet |
| ⌥⌘R | Reveal the selection in Finder |
| ⌘P | Print the selection (in Library) or the image shown |
| ⌘E | Edit in External Editor: a 16-bit TIFF of the open or selected image, opened in the app chosen in Settings |

## Files

| Keys | Action |
|---|---|
| F2 | Rename the selected image (its sidecar and thumbnail follow); with several selected, rename them all from a filename template |
| ⌘R | Refresh the open folder: scan it again for photos added, removed or renamed outside Latent |
| ⌘' | Create a virtual copy of each selected image (in Loupe and Develop, of the image shown): another version of the photo with its own edit, rating and keywords, sharing the file |
| Drag images onto a sidebar folder | Move them there with their edits (hold ⌥ to copy) |

## Photo Merge

| Keys | Action |
|---|---|
| ⌃H | HDR merge of the selected photos into one DNG beside them (see [Photo Merge](Photo-Merge)); not while typing in a text field, where ⌃H deletes backward |
| ⌃⇧H | HDR merge without the dialog, with the options it was last left with; problems show in the status bar |
| ⌃M | Stitch the selected photos into one panorama DNG beside them (see [Photo Merge](Photo-Merge)); not while typing in a text field |
| ⌃⇧M | Merge a bracket at each position and stitch the results into one DNG (experimental; see [Photo Merge](Photo-Merge)); not while typing in a text field |
