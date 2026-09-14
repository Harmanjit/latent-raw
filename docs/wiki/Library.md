# Library

## The catalog

Each photo folder is one catalog, stored in a `_latent/` directory inside it:

```
_latent/
  catalog.sqlite     the database (a cache; rebuildable)
  xmp/               one sidecar per image (the source of truth)
  thumbnails/        512 px HEIC previews (excluded from Time Machine)
```

**Reconciliation** runs when a folder opens or you click Refresh. Files are matched by name, size and modification time. A renamed file is recognised by its content hash and keeps its sidecar. Sidecars newer than the database are re-read, so editing a sidecar in another tool is picked up. There is no live file watching; the app never touches the folder while you are not looking.

**Sidecars** are standard XMP. Rating, label and keywords are written in the fields Lightroom and others read. The edit, history and snapshots are under Latent's own namespace. A sidecar written by another application is read for whatever standard fields it has.

**Network volumes** use SQLite's rollback journal instead of write-ahead logging, which is unreliable over SMB and NFS.

## Supported files

Extensions indexed: NEF, NRW, ARW, SRF, SR2, CR2, CR3, CRW, DNG, RAF, ORF, RW2, PEF, SRW, 3FR, FFF, IIQ, MOS, MRW, X3F. Decoding is by LibRaw. Only Bayer-pattern sensors render; see [Limitations](Limitations).

## The grid

Click to select, ⌘-click and ⇧-click for multiple, double-click or Return to open in Develop. Badges show a pencil for edited images, ✓ and ✗ for flags, stars for rating.

**Filter bar** above the grid: rating threshold (click a star for "this many or better"), flag states, edited-only, camera, lens, keyword, and file-name search, combined with AND. **Sort** by capture time, name, rating or modified date. The count shows how many pass. ⌘⇧L clears the filter. Arrow keys walk only the visible images.

## Metadata panel

The left panel shows the selected image's camera, lens, exposure, capture time, dimensions and file size, read from the catalog so changing selection costs nothing. Below it: history and snapshots, and export.

## Loupe and Compare

**Loupe** (E, or Space from the grid) shows one image full size with a caption. Arrows step, Z toggles fit and 100%, rating keys work.

**Compare** (C) pins a "Select" on the left and walks a "Candidate" on the right with the arrows. Zoom and pan on either pane are mirrored to the other. ⇧X promotes the candidate to Select; Swap exchanges them. Rating keys act on the candidate.

## Applying edits to many images

With several images selected, ⌘⇧V pastes copied settings onto all of them, and the Apply Preset menu applies a preset to all. Which parts travel is set under Presets and Clipboard in Develop; by default the look travels and masks and crops do not.
