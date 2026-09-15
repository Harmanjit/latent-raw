# Library

## The sidebar

The column on the far left lists favourite folders. Add one with **Add Folder…** at its foot, by dragging folders in from Finder, or with **Add to Favourites** on a folder's right-click menu. Each favourite expands into its folder tree; clicking any folder in it opens that folder as the catalog, exactly as Open Folder does. Expanding a folder only lists its subfolders; nothing touches a catalog until you click. Until the folder's images are ready, the grid keeps showing the folder you are leaving; click another folder meanwhile and that one opens instead.

The app is sandboxed, so it can read inside favourites and folders you chose in an open panel, and nowhere else. A folder outside every favourite still opens with ⇧⌘O, and the sidebar then offers to add it. A favourite on a disk or network share that isn't mounted shows as not connected and comes back when the volume does; Latent never mounts anything on its own. The sidebar can be collapsed, and stays shown or hidden as you left it.

Opening a subfolder that an enclosing catalog already includes opens that enclosing catalog instead, with a note in the status bar, so the catalog isn't split in two.

## The catalog

Each photo folder is one catalog, stored in a `_latent/` directory inside it:

```
_latent/
  catalog.sqlite     the database (a cache; rebuildable)
  xmp/               one sidecar per image (the source of truth)
  thumbnails/        512 px HEIC previews (excluded from Time Machine)
```

**Reconciliation** runs each time a folder opens; to re-scan the open folder, open it again from the sidebar or with Open Folder. Files are matched by name, size and modification time. A renamed file is recognised by its content hash and keeps its sidecar. Sidecars newer than the database are re-read, so editing a sidecar in another tool is picked up. There is no live file watching; the app never touches the folder while you are not looking.

**Sidecars** are standard XMP. Rating, label and keywords are written in the fields Lightroom and others read. The edit, history and snapshots are under Latent's own namespace. A sidecar written by another application is read for whatever standard fields it has.

**A damaged database** is not a lost catalog. If SQLite reports `catalog.sqlite` as damaged, Latent moves it aside as `catalog.damaged-<date>.sqlite` in the same `_latent/` folder, starts a new one that fills from the sidecars, and tells you. Ratings, keywords and edits come back; the include-or-separate answers for subfolders were kept only in the database, so they are asked again.

**Network volumes** use SQLite's rollback journal instead of write-ahead logging, which is unreliable over SMB and NFS.

## Supported files

Extensions indexed: NEF, NRW, ARW, SRF, SR2, CR2, CR3, CRW, DNG, RAF, ORF, RW2, PEF, SRW, 3FR, FFF, IIQ, MOS, MRW, X3F. Decoding is by LibRaw. Only Bayer-pattern sensors render; see [Limitations](Limitations).

## The grid

Click to select, ⌘-click and ⇧-click for multiple, double-click or Return to open in Develop. With several selected, the image you clicked last (for a ⇧-click, the end you clicked) leads: Loupe, Develop and the left panel show it, and ⌘A keeps it. Rating, flag and rotate keys act on every selected image. Selected images that the filter hides are deselected, so these keys, Paste Settings and Export act only on images the grid shows. Badges show a pencil for edited images, ✓ and ✗ for flags, stars for rating.

**Thumbnail size.** The slider in the filter bar, or ⌘= and ⌘- while the grid shows (View > Larger Thumbnails, Smaller Thumbnails). The size is remembered.

**Right-click** an image for Open in Loupe, Open in Develop, Compare Selected (with exactly two selected), Rating, Flag, Rotate Left and Right, Copy Settings, Paste Settings, Apply Preset, Export and Reveal in Finder, acting on the selection. Right-click between images for Select All and Reveal Folder in Finder.

**Filter bar** above the grid: rating threshold (click a star for "this many or better"), flag states, edited-only, camera, lens, keyword, and file-name search, combined with AND. **Sort** by capture time, name, rating or modified date. The count shows how many pass. ⇧⌘L clears the filter. Arrow keys walk only the visible images.

## Filmstrip

Loupe and Develop show the grid's visible images along the bottom, in the grid's filter and sort order, with the current image highlighted and kept in view. Click a frame to open that image; it becomes the selection. The film button in the status bar shows or hides the strip, and the choice is remembered. The strip never takes the keyboard.

## Metadata panel

The left panel shows the selected image's name, rating, flag and keywords, then its camera, lens, exposure, capture time, dimensions and file size, read from the catalog so changing selection costs nothing. Keywords typed there apply to that one image, not the whole selection. Below: history and snapshots, and export.

## Loupe and Compare

**Loupe** (E, or Space from the grid) shows one image full size with a caption. Arrows step, Z toggles fit and 100%, rating keys act on the image shown.

**Compare** (C) pins a "Select" on the left and walks a "Candidate" on the right with the arrows. While **Sync** (in the Compare bar) is on, zoom and pan stay matched by position in each picture, so images with different crops, rotations or sizes show the same region, and a candidate stepped in while zoomed keeps the zoom. ⇧X promotes the candidate to Select; Swap exchanges them. Rating keys act on the candidate. Sync is on at each launch.

## Applying edits to many images

With several images selected, ⇧⌘V pastes copied settings onto all of them, and the Apply Preset menu applies a preset to all. Which parts travel is set under Presets and Clipboard in Develop; by default the look travels and masks and crops do not.
