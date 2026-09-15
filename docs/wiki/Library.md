# Library

## The sidebar

The column on the far left lists favourite folders. Add one with **Add Folder…** at its foot, by dragging folders in from Finder, or with **Add to Favourites** on a folder's right-click menu. Each favourite expands into its folder tree; clicking any folder in it opens that folder as the catalog, exactly as Open Folder does. Expanding a folder only lists its subfolders; nothing touches a catalog until you click. Until the folder's images are ready, the grid keeps showing the folder you are leaving; click another folder meanwhile and that one opens instead. From the keyboard, Tab into the sidebar, move with the arrow keys or by typing a name, and press Return or Space to open the selected folder.

The app is sandboxed, so it can read inside favourites and folders you chose in an open panel, and nowhere else. A folder outside every favourite still opens with ⇧⌘O, and the sidebar then offers to add it. A favourite on a disk or network share that isn't mounted shows as not connected and comes back when the volume does; Latent never mounts anything on its own. The sidebar can be collapsed, and stays shown or hidden as you left it.

**Back and Forward** (the chevrons at the top of the sidebar, or ⌥⌘← and ⌥⌘→) step through the folders you opened in this window and reselect the images you had selected in each.

Dragging thumbnails from the grid onto a folder in the sidebar moves them there; hold ⌥ to copy. See [Moving, copying and renaming](Library#moving-copying-and-renaming).

Opening a subfolder that an enclosing catalog already includes opens that enclosing catalog instead, with a note in the status bar, so the catalog isn't split in two.

## The catalog

Each photo folder is one catalog, stored in a `_latent/` directory inside it:

```
_latent/
  catalog.sqlite     the database (a cache; rebuildable)
  xmp/               one sidecar per image (the source of truth)
  thumbnails/        512 px HEIC previews (excluded from Time Machine)
  custom-order.json  your Custom sort arrangement, once you make one
```

**Reconciliation** runs each time a folder opens; to re-scan the open folder, open it again from the sidebar or with Open Folder. Files are matched by name, size and modification time. A renamed file is recognised by its content hash and keeps its sidecar. Sidecars newer than the database are re-read, so editing a sidecar in another tool is picked up, and Finder tags are read again. There is no live file watching; the app never touches the folder while you are not looking. After a move, copy or rename made in Latent, the open folder is re-read by itself.

**Sidecars** are standard XMP. Rating, label and keywords are written in the fields Lightroom and others read. The edit, history and snapshots are under Latent's own namespace. A sidecar written by another application is read for whatever standard fields it has.

**A damaged database** is not a lost catalog. If SQLite reports `catalog.sqlite` as damaged, Latent moves it aside as `catalog.damaged-<date>.sqlite` in the same `_latent/` folder, starts a new one that fills from the sidecars, and tells you. Ratings, keywords and edits come back; the include-or-separate answers for subfolders were kept only in the database, so they are asked again.

**Network volumes** use SQLite's rollback journal instead of write-ahead logging, which is unreliable over SMB and NFS.

## Supported files

Extensions indexed: NEF, NRW, ARW, SRF, SR2, CR2, CR3, CRW, DNG, RAF, ORF, RW2, PEF, SRW, 3FR, FFF, IIQ, MOS, MRW, X3F. Decoding is by LibRaw. Only Bayer-pattern sensors render; see [Limitations](Limitations).

## The grid

Click to select, ⌘-click and ⇧-click for multiple, double-click or Return to open in Develop. With several selected, the image you clicked last (for a ⇧-click, the end you clicked) leads: Loupe, Develop and the left panel show it, and ⌘A keeps it. Rating, flag and rotate keys act on every selected image. Selected images that the filter hides are deselected, so these keys, Paste Settings and Export act only on images the grid shows. Badges show a pencil for edited images and ✓ and ✗ for flags.

**Stars.** Click the stars under a thumbnail to rate it; the empty ones appear when you point at the cell. Clicking a selected image's stars rates the whole selection, clicking another image's selects it first, and clicking the rating it already has clears it.

**Finder tags** show as coloured dots at the end of the name, up to three per image. See [Finder tags](Library#finder-tags).

**Dragging out.** Drag thumbnails to Finder or another app to hand over the original raw files; the other app gets a copy, and the originals stay in the catalog.

**Thumbnail size.** The slider in the filter bar, or ⌘= and ⌘- while the grid shows (View > Larger Thumbnails, Smaller Thumbnails). The size is remembered.

**Right-click** an image for Open in Loupe, Open in Develop, Compare Selected (with exactly two selected), Survey Selected (two to four), Rating, Flag, Rotate Left and Right, Copy Settings, Paste Settings, Apply Preset, Export, Reveal in Finder, Rename… (one image), and Move to Folder and Copy to Folder, acting on the selection. Right-click between images for Select All and Reveal Folder in Finder.

**Filter bar** above the grid: rating threshold (click a star for "this many or better"), flag states, edited-only, camera, lens, keyword, Finder tag, and file-name search, combined with AND. The count shows how many pass. ⇧⌘L clears the filter. Arrow keys walk only the visible images.

**Sort** by capture time, file name, rating, modified date or Custom. Each key remembers its own direction: the first time, capture time and modified run newest first, rating most stars first, and file name and Custom front to back. Latent reopens with the last sort you used, whichever folder you open.

**Custom sort.** Choose Custom, then drag thumbnails to arrange them. The arrangement is saved per folder in `_latent/custom-order.json`, so it survives a rebuilt catalog and moves with the folder. New files appear after your arrangement, by name. Images hidden by a filter keep their places. An image renamed or moved within the folder with Latent's own commands keeps its place, and so does a file renamed in Finder, the next time the folder is opened. ⌘Z undoes a rearrangement.

## Finder tags

Latent shows the tags you set in Finder as coloured dots on thumbnails (up to three) and lists them under the selected image in the left panel, and VoiceOver reads them with the image. The filter bar's Tag menu shows only images with one tag. Latent only reads tags, never writes them. A tag changed in Finder shows the next time the folder is opened.

## Filmstrip

Loupe and Develop show the grid's visible images along the bottom, in the grid's filter and sort order, with the current image highlighted and kept in view. Click a frame to open that image; it becomes the selection. The film button in the status bar shows or hides the strip, and the choice is remembered. The strip never takes the keyboard.

## Metadata panel

The left panel shows the selected image's name, rating, flag, keywords and Finder tags, then its camera, lens, exposure, capture time, dimensions and file size, read from the catalog so changing selection costs nothing. Keywords typed there apply to that one image, not the whole selection. Below: history and snapshots, and export.

## Loupe, Compare and Survey

**Loupe** (E, or Space from the grid) shows one image full size with a caption. Arrows step, Z toggles fit and 100%, rating keys act on the image shown.

**Compare** (C) pins a "Select" on the left and walks a "Candidate" on the right with the arrows. While **Sync** (in the Compare bar) is on, zoom and pan stay matched by position in each picture, so images with different crops, rotations or sizes show the same region, and a candidate stepped in while zoomed keeps the zoom. ⇧X promotes the candidate to Select; Swap exchanges them. Rating keys act on the candidate. Sync is on at each launch.

**Survey** (N, View > Survey, or Survey Selected in the grid's right-click menu) shows two to four selected images side by side, in a row or a grid, whichever shows each image larger. The pane with the blue outline has the keyboard: it is the selected image the left panel shows, and stars, flags, rotation, pasted settings and presets apply to it. Click a pane, or press ← and →, to move the outline. Point at a pane and click its ✕, or press /, to take it out of the survey; that also deselects it, and with one image left Survey becomes Loupe. With Sync on (the default), zooming or panning any pane shows the same part of the scene in every pane, even when the photos differ in size, crop or rotation; turn Sync off to look at each pane on its own. The zoom buttons and ⌘0, ⌘1, ⌘= and ⌘- act on the focused pane. Survey only shows images: to edit one, press D or Return.

## Looking closely

These work in Loupe and Develop; zooming and the magnifier work in Compare too.

- **Trackpad.** At fit, a two-finger swipe left shows the next image and right the previous, one per swipe; momentum does nothing. There is no swipe navigation in Compare, or while a crop, spot or mask tool is on. Zoomed in, two-finger scrolling pans. Pinch, or scroll with ⌥ or ⌘, to zoom about the pointer. A two-finger double-tap toggles fit and 100% at the pointer, like a double-click.
- **Magnifier.** On a fitted image, hold the mouse button, or start dragging, to get a round loupe showing one image pixel per point (100%, or 200% on a Retina screen). Move it around; let go to close it. It sharpens in a moment, from a small full-resolution render of the area under the pointer. Edits and before/after (`\`) show in it. It is off while a Develop tool is on.
- **Square pixels.** Past 200% the pixels are drawn as crisp squares, so demosaic, sharpening and noise-reduction artefacts can be judged pixel by pixel.
- **Arrow keys.** With **Settings › Library › Arrow keys pan a zoomed-in image** on (it is off by default), ← → ↑ ↓ move around an image zoomed past fit, an eighth of the view per press. At fit ← and → still step, and Previous and Next Image in the View menu always step.

## Full screen and a second display

**Full-screen image** (View > Full-Screen Image, F) fills the screen with the image alone, in Loupe, or in Develop when you start there; the menu bar still appears at the top edge. Move the pointer to the left edge for the library panel, to the right edge for Develop's adjustments (in Develop), or to the bottom edge for the filmstrip. One panel shows at a time and closes when the pointer leaves it. F or Esc leaves, and so does switching to the grid, Compare or Survey.

**Show Loupe on Second Display** (View menu, with two or more displays) fills another display with the image at fit and its caption, clear of that display's menu bar and Dock. It is for looking only: zoom, pan and tools stay in the main window. It shows what Develop, Loupe or Compare's candidate shows, before/after and the mask overlay included; from the grid it shows the selected image. With HDR display on, the image is rendered for the brighter of the two screens, so an ordinary main screen beside an XDR display shows the HDR render with its highlights fitted to it, as an XDR screen at low brightness does. It closes when its display is unplugged or the main window closes.

## Applying edits to many images

With several images selected, ⇧⌘V pastes copied settings onto all of them, and the Apply Preset menu applies a preset to all. Which parts travel is set under Presets and Clipboard in Develop; by default the look travels and masks and crops do not.

## Undo

⌘Z and ⇧⌘Z undo and redo what you did in Library, Loupe, Compare and Survey: ratings, picks and rejects, rotation, keywords, settings pasted or presets applied, a Custom sort rearrangement, and moves, copies and renames. The Edit menu names the step, as in Undo Paste Settings (12 Images). Each image goes back to its own previous value. In Develop, ⌘Z steps through that image's edit history instead, and while you are typing in a field, ⌘Z undoes only the typing. Opening another folder clears the undo of ratings, flags, rotation, keywords, settings and rearrangements; moves, copies and renames can still be undone.

## Moving, copying and renaming

**Move to Folder…** and **Copy to Folder…** (File menu) act on the selection. So do the grid's right-click Move to Folder and Copy to Folder menus, which list the last five folders used and then Choose Folder…. You can also drag thumbnails onto a folder in the sidebar: that moves them, and holding ⌥ copies.

Ratings, flags, keywords, edits, snapshots, history and the thumbnail go with each image. If the destination already has a file of that name, or a sidecar left behind by one, the image gets a number ("DSC_0107 2.NEF") and its old name is kept in the sidecar as its original file name. A folder without a catalog gets a `_latent` folder only when an image brings a sidecar. A subfolder inside the open catalog that is still to be asked about (one just made with New Folder in the panel, say) is asked about first: include it in this catalog, or keep it separate as a catalog of its own. One you chose to keep separate is a catalog of its own.

Progress shows in the status bar with a stop button. Stopping, or quitting, finishes the image under way, so no image is left half-moved; quitting waits up to a minute for it, and an image still being copied then stays where it was. While an export is running, images can't be moved, copied, renamed or dropped on a folder, and those can't be undone. ⌘Z moves images back; undoing a copy puts the copy and its sidecar in the Trash. Nothing is ever overwritten or permanently deleted, apart from thumbnails, which are made again, a moved image's old sidecar, whose contents are already in the new one, and, for a move to another disk, the original once its copy is complete.

**Rename…** (F2, the File menu or the right-click menu) renames one image, keeping its extension; its sidecar and thumbnail follow. A name that differs only in letter case works.

These commands work in the Library grid, and not while an export is running.

## Slideshow

**View > Slideshow** (⌘Return) plays the selected images, or every image the filter shows when one or none is selected, starting at the selected image, in the grid's order. The menu bar and Dock hide during the show.

Slides are the photos with their edits (crop, masks, everything except AI noise reduction), made at the size of the screen, so the first can take a moment. ← and → (also ↑ and ↓, Page Up and Page Down) step, Space pauses, and Esc or a click ends the show. Moving the pointer shows previous, pause, next and end buttons. The display doesn't sleep while the show plays, but may while it is paused. A photo that can't be shown is skipped.

**Settings › Slideshow** sets the seconds per slide (1–60), the transition (Cut, Cross-Fade, Fade Through Black, Push or Zoom) and its length (0.3–3 s), whether to start again after the last slide, the caption (none, file name, name and date, or camera and exposure), and music: songs added from disk, played in order and round again, paused with the show.
