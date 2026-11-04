# Library

## The sidebar

The column on the far left lists favourite folders. Add one with **Add Folder…** at its foot, by dragging folders in from Finder, or with **Add to Favourites** on a folder's right-click menu. Each favourite expands into its folder tree; clicking any folder in it opens that folder as the catalog, exactly as Open Folder does. Expanding a folder only lists its subfolders; nothing touches a catalog until you click. Until the folder's images are ready, the grid keeps showing the folder you are leaving; click another folder meanwhile and that one opens instead. From the keyboard, Tab into the sidebar, move with the arrow keys or by typing a name, and press Return or Space to open the selected folder.

The app is sandboxed, so it can read inside favourites and folders you chose in an open panel, and nowhere else. A folder outside every favourite still opens with ⇧⌘O, and the sidebar then offers to add it. A favourite on a disk or network share that isn't mounted shows as not connected and comes back when the volume does; Latent never mounts anything on its own. The sidebar can be collapsed, and stays shown or hidden as you left it.

**Find folder.** Type part of a folder's name in the field above the tree to list every folder inside your favourites whose name contains it, however deep, nearest first, each with the folders above it. Click one to open it. Clear the field (the × or deleting the text) to get the tree back. Disks that aren't connected aren't searched.

**Back and Forward** (the chevrons at the top of the sidebar, or ⌥⌘← and ⌥⌘→) step through the folders you opened in this window and reselect the images you had selected in each.

Dragging thumbnails from the grid onto a folder in the sidebar moves them there; hold ⌥ to copy. See [Moving, copying and renaming](Library#moving-copying-and-renaming).

Opening a subfolder that an enclosing catalog already includes opens that enclosing catalog instead, with a note in the status bar, so the catalog isn't split in two.

Under the folders, the **Collections** section lists the open folder's collections, smart collections and collection sets. Click one to show its photos; drag thumbnails onto one to add them. See [Collections and Keywords](Collections-and-Keywords).

**Add Parent Folder…** on a favourite's right-click menu shows its enclosing folder in Favourites instead, with the favourite inside its tree. An open panel comes up showing that folder; click **Add Parent** to give Latent permission to read it (the sandbox needs you to choose it once). Any other favourites inside it are folded into it too.

**Recently Added**, at the top of the sidebar, narrows the grid to the photos the latest scan of the open folder found new: files copied in from Finder, brought in by Auto Import, or everything, the first time a folder is opened. The number beside it says how many. Click it again, or press ⇧⌘L to clear the filters, to see every photo. A scan that finds nothing new keeps the last batch, so you can come back to it, and it is remembered when the folder is opened again. The filter bar still applies on top of it.

**Volumes**, at the foot of the sidebar, shows a meter for each disk that holds a favourite or the open folder: how full it is and how much is free, counting space macOS can free up the way Finder does. The meter turns orange when a disk has less than a tenth of its space, or under 5 GB, left. It updates every minute and when a disk is connected or ejected.

## The catalog

Each photo folder is one catalog, stored in a `_latent/` directory inside it:

```
_latent/
  catalog.sqlite     the database (a cache; rebuildable)
  xmp/               one sidecar per image (the source of truth)
  thumbnails/        512 px HEIC previews (excluded from Time Machine)
  custom-order.json  your Custom sort arrangement, once you make one
  collections.json   a copy of your collections, once you make one
```

**Reconciliation** runs each time a folder opens, when the open folder changes on disk (see [Watching folders](Library#watching-folders)), and on **File › Refresh Folder** (⌘R). Files are matched by name, size and modification time. A renamed file is recognised by its content hash and keeps its sidecar. Sidecars newer than the database are re-read, so editing a sidecar in another tool is picked up (on the next refresh), and Finder tags are read again. After a move, copy or rename made in Latent, the open folder is re-read by itself.

**Sidecars** are standard XMP. Rating, colour label, keywords, title, caption, creator and copyright are written in the fields Lightroom and others read (`xmp:Rating`, `xmp:Label`, `dc:subject`, `dc:title`, `dc:description`, `dc:creator`, `dc:rights`), keyword hierarchies included (`lr:hierarchicalSubject`). The edit, history and snapshots are under Latent's own namespace. A sidecar written by another application is read for whatever standard fields it has.

**A damaged database** is not a lost catalog. If SQLite reports `catalog.sqlite` as damaged, Latent moves it aside as `catalog.damaged-<date>.sqlite` in the same `_latent/` folder, starts a new one that fills from the sidecars, and tells you. Ratings, keywords and edits come back, and collections come back from `collections.json`; the include-or-separate answers for subfolders were kept only in the database, so they are asked again.

**Network volumes** use SQLite's rollback journal instead of write-ahead logging, which is unreliable over SMB and NFS.

## Supported files

**Raw files:** NEF, NRW, ARW, SRF, SR2, CR2, CR3, CRW, DNG, RAF, ORF, RW2, PEF, SRW, 3FR, FFF, IIQ, MOS, MRW, X3F. Decoding is by LibRaw. Only Bayer-pattern sensors render; see [Limitations](Limitations).

**Pictures:** JPEG, HEIC and HEIF, TIFF and PNG, and WebP and AVIF where this Mac's macOS can read them. They are catalogued, rated, keyworded, filtered and exported like raws, with their camera, lens, exposure and capture time read from their EXIF; a scan or screenshot with no capture time is dated by the file's modification date. Their thumbnails are made from the pictures themselves, turned upright by their orientation tag. They open in Develop too: see [Develop](Develop#jpeg-tiff-and-other-pictures).

### RAW+JPEG pairs

A camera set to RAW+JPEG (or RAW+HEIF) writes two files with one name, such as `DSC_0107.NEF` and `DSC_0107.JPG`. Latent treats the JPEG as part of the raw, as Lightroom does:

- The grid shows the raw only. The JPEG is catalogued but hidden, and the Library panel names it under the raw's file name ("+ DSC_0107.JPG").
- Moving or copying the raw takes the JPEG with it, and renaming the raw renames the JPEG to match ("Sunset.NEF" and "Sunset.JPG"). If the raw gets a number because its name is taken where it goes, the JPEG gets the same one. One ⌘Z puts both back.
- Ratings, keywords and edits belong to the raw. Exports, prints and slideshows use the raw.

A pair is a raw and a JPEG, HEIC or HEIF in the same folder whose names match apart from the extension, ignoring capital letters. A TIFF or PNG beside a raw is never part of a pair: that is usually an edit or an export, a picture of its own. Rename or move one file of a pair in Finder and it simply stops being a pair.

To work with the JPEGs as photos of their own, turn on **Settings › Library › Show JPEGs of RAW+JPEG pairs as separate photos**. They then appear in the grid, and each file moves, copies and renames only when it is chosen itself.

## The grid

Click to select, ⌘-click and ⇧-click for multiple, double-click or Return to open in Develop. With several selected, the image you clicked last (for a ⇧-click, the end you clicked) leads: Loupe, Develop and the left panel show it, and ⌘A keeps it. Rating, flag, label and rotate keys act on every selected image. Selected images that the filter hides are deselected, so these keys, Paste Settings and Export act only on images the grid shows. Badges show a pencil for edited images and ✓ and ✗ for flags, and a coloured dot left of the stars shows the colour label. A virtual copy has a small stacked-squares mark at the bottom-left of its picture (see [Virtual copies](Library#virtual-copies)).

**Reset to Camera Orientation** (Photo menu) takes away the quarter turns you gave the selected images with ⌘[ and ⌘], so each shows the way the camera recorded it. One ⌘Z gives every image its own turns back.

**Flip Horizontal** and **Flip Vertical** (Photo menu, or right-click) mirror every selected image, exactly as Develop's [Transform](Develop#transform-and-upright) flip does, crop and masks included; in Loupe they flip the image shown, and in Develop the open image. The flip is part of each photo's edit, so it shows in Develop's Transform section and in exports, and one ⌘Z takes it back from every image. A photo whose crop or masks were made before Latent measured them on the camera's active area is skipped and named; open it in Develop once (which converts it) and flip it there or again here.

**Mirror Image Mode** (View menu) draws every thumbnail and the Loupe image mirrored left to right, as Lightroom does, for looking at a composition with fresh eyes. It changes nothing in the photos and is off again at the next launch.

**Stars.** Click the stars under a thumbnail to rate it; the empty ones appear when you point at the cell. Clicking a selected image's stars rates the whole selection, clicking another image's selects it first, and clicking the rating it already has clears it.

**Finder tags** show as coloured dots at the end of the name, up to three per image. See [Finder tags](Library#finder-tags).

**Dragging out.** Drag thumbnails to Finder or another app to hand over the original raw files; the other app gets a copy, and the originals stay in the catalog.

**Thumbnail size.** The slider in the filter bar, or ⌘= and ⌘- while the grid shows (View > Larger Thumbnails, Smaller Thumbnails). The size is remembered.

**Right-click** an image for Open in Loupe, Open in Develop, Compare Selected (with exactly two selected), Survey Selected (two to four), Rating, Flag, Label, Rotate Left and Right, Flip Horizontal and Vertical, Create Virtual Copy, Set Copy as Master, Remove Virtual Copy, Copy Settings, Paste Settings, Apply Preset, Export, Reveal in Finder, Rename… (Rename N Images… with several selected, which opens Rename with Template), Rename with Template…, Move to Folder and Copy to Folder, Duplicate, and Add to Quick Collection (B), Add to Collection and, while the grid shows a collection, Remove from it, acting on the selection. Right-click between images for Select All and Reveal Folder in Finder.

**Filter bar** above the grid: rating threshold (click a star for "this many or better"), flag states, colour label, edited-only, camera, lens, keyword, Finder tag, and a search that looks in file names, titles and captions, combined with AND. The Label menu takes any number of labels, plus No Label and Custom Label (a label another application named), and shows images with any one of them. A keyword also finds the photos tagged with keywords inside it (Places finds Places › France › Paris). While a collection is shown, the filter narrows its photos. The count shows how many pass. ⇧⌘L clears the filter. Arrow keys walk only the visible images.

**Sort** (the menu in the filter bar, or View › Sort) by capture time, file name, rating, modified date or Custom, or by Lightroom's other orders:

- **Added order**: the order the photos joined the catalog.
- **Edit time** and **Edit count**: when each photo's edit was last saved, and how many steps its history holds (the history keeps its most recent steps, so a long-edited photo stops counting at that cap). Unedited photos come last.
- **Pick**: picks, then unflagged, then rejects.
- **Label text** (alphabetically by the label's name) and **Label colour** (red, yellow, green, blue, purple, then labels another application wrote).
- **File extension**, and **File type**, which groups every camera raw as Raw and puts DNG, JPEG, HEIF and TIFF on their own.
- **Aspect ratio**, from tall to wide as the photo shows in the grid, after the camera's orientation and your quarter turns. The crop isn't taken into account.
- **Title**, **Caption**, **Camera**, **Lens**, **ISO** and **Focal length**.

Photos with nothing to sort by (no label, no lens, no title) come last in either direction. The arrow beside the menu, or **View › Sort › Reverse Sort Order**, turns the order round. Each key remembers its own direction: the first time, capture time, modified, edit time, edit count, rating and pick start with the newest, the most or the picks, and the rest run front to back (A to Z, smallest first). Latent reopens with the last sort you used, whichever folder you open.

**Custom sort.** Choose Custom, then drag thumbnails to arrange them. The arrangement is saved per folder in `_latent/custom-order.json`, so it survives a rebuilt catalog and moves with the folder. New files appear after your arrangement, by name. Images hidden by a filter keep their places. An image renamed or moved within the folder with Latent's own commands keeps its place, and so does a file renamed in Finder, the next time the folder is opened. ⌘Z undoes a rearrangement.

## Faster culling

**Auto Advance** (Photo › Auto Advance) moves on to the next photo each time you set a star, flag or colour label, so you can go through a shoot with one key per photo. It is remembered between launches. Without it, hold **⇧** with the key (⇧3, ⇧P, ⇧X, ⇧7 and so on) to set it and move on just that once, as in Lightroom; with **Caps Lock** on, every star, flag and label key moves on. In Compare, ⇧X stays Make Select. Moving on works as → does: in the grid the next photo becomes the only one selected, and in Loupe, Compare and Develop the next photo opens.

**Selecting.** Besides ⌘A, the Edit menu has **Select None** (⌘D), **Invert Selection**, **Select by Flag** (Picked, ⌥⌘A; Unflagged; Rejected), **Select by Rating** (exactly that many stars), **Select by Colour Label** (or No Label) and **Deselect Unflagged** (⌥⇧⌘D), which keeps only the picked and rejected photos of the selection. They choose among the photos the grid shows, and work in the grid only.

**Refine Photos** (Photo › Refine Photos…) is Lightroom's second pass: of the photos the grid shows, every unflagged one becomes rejected and every picked one unflagged, ready to pick again. Rejected photos stay rejected. Latent says how many photos will change and asks first, and one ⌘Z puts every flag back.

## Colour labels

Give photos a colour label to sort a shoot beyond stars and flags: red for the client's choices, green for the portfolio, whatever you like. The keys are Lightroom's: **6** red, **7** yellow, **8** green, **9** blue. Purple has no key; use **Photo › Label** or the right-click **Label** menu. Pressing the key of the label a photo already has takes it off. With several photos selected in the grid, the key labels all of them, or takes the label off all of them when the photo the panel shows already has it. In Loupe, Compare and Develop the key labels the photo shown.

The left panel shows the five colours under the stars: click one to label the photo, click it again (or the ⓧ) to take it off. ⌘Z undoes a label like a rating.

Labels are written to the sidecar as `xmp:Label` with the colour's English name ("Red"), the way Lightroom and Bridge write them, so a label set in either shows in Latent and the other way round. A label another application gave a name of its own ("Approved") is kept; it shows as a hollow ring on the thumbnail and by name in the panel, and the filter's Custom Label finds it.

## Title, caption, creator and copyright

The left panel's **Title & Copyright** section edits four fields for the selected photos:

- **Title**: a short name for the photo.
- **Caption**: what it shows. It can run to several lines: Return saves, ⌥Return starts a new line.
- **Creator**: who took it. Separate several names with a semicolon.
- **Copyright**: the notice, such as © 2026 Ann Smith. With a creator and no copyright, a link fills it in from the creator and this year.

Press Return or click away to save a field. With several photos selected, each field shows the value they share, or Mixed when they differ; whatever you type is set on every selected photo, and the other fields keep each photo's own. Leaving a Mixed field empty changes nothing. Each change is one step of ⌘Z.

They go into the sidecar as Dublin Core (`dc:title`, `dc:description`, `dc:creator` and `dc:rights`), where Lightroom, Bridge and Capture One look for them, and Latent reads them from sidecars those applications wrote. Exports carry them too (see [Export](Export)). The filter bar's search finds words in titles and captions.

## Watching folders

**The open folder.** Photos copied into the open folder or into a subfolder it includes, deleted, or renamed in Finder appear and go from the grid by themselves, a second or so after the copying stops: a whole card copied in is one refresh, not hundreds. A renamed photo keeps its rating and edits, as when the folder is opened. Latent doesn't read the folder to notice; macOS tells it what changed, so a quiet folder costs nothing. Changes to Latent's own `_latent` folder, and to files Latent doesn't catalog (text files, say), are ignored. Turn it off under **Settings › Folders › Watch the open folder for changes**. On a network share, changes made from another computer may not be noticed.

**Refresh Folder** (File menu, ⌘R) scans the open folder again at any time, watched or not.

**Auto Import.** Under **Settings › Folders › Auto Import**, choose a **watched folder** (the one your tethering software, card reader or another computer saves into) and a **destination**, and turn on **Import new photos from a watched folder**. Raw files and pictures (JPEG, HEIC, TIFF, PNG) that appear directly in the watched folder (not in its subfolders) are moved into the destination, or copied with **Bring photos in by: Copying them**, which leaves the originals and remembers what it has copied so nothing is copied twice. Latent waits until a file has stopped changing for a couple of seconds, so a photo still being written isn't taken half done. If the destination already has a file of that name, the newcomer gets a number ("DSC_0107 2.NEF"); nothing is overwritten. Pick a **Develop preset** and each imported photo starts with it, as if you had applied the preset yourself (a photo that arrives with settings of its own keeps them). When the destination is the open folder, or inside it, the photos appear in the grid at once and **Recently Added** shows them. The watched folder can't be the destination, or inside it, or contain it. Settings shows what the last import did, and problems also show in the status bar. An import isn't on the Undo list, since undoing it would hand the files straight back to the watcher; use Move to Folder to put a photo elsewhere.

**A photo that disappears.** When a photo is deleted or moved out of the folder outside Latent, it leaves the grid, but its sidecar stays in `_latent/xmp`. Put the file back (under the same name or any other) and its rating, keywords and edit come back with it. Latent has no Locate Missing Photo command: the folder is the catalog, so a photo that isn't in the folder isn't kept as a placeholder.

## Finder tags

Latent shows the tags you set in Finder as coloured dots on thumbnails (up to three) and lists them under the selected image in the left panel, and VoiceOver reads them with the image. The filter bar's Tag menu shows only images with one tag. Latent only reads tags, never writes them. A tag changed in Finder shows within a moment while the open folder is watched, or after **File › Refresh Folder** (⌘R).

## Filmstrip

Loupe and Develop show the grid's visible images along the bottom, in the grid's filter and sort order, with the current image highlighted and kept in view. Click a frame to open that image; it becomes the selection. The film button in the status bar shows or hides the strip, and the choice is remembered. The strip never takes the keyboard.

## Metadata panel

The left panel shows the selected image's name, rating, flag, colour label, keywords and Finder tags, its title, caption, creator and copyright, then its camera, lens, exposure, capture time, dimensions and file size, read from the catalog so changing selection costs nothing. Keywords show as chips; the **Add keywords** field adds to every selected photo, with suggestions from the keywords already in the folder, and a chip's × takes that keyword off them all. The **Keyword List** below lists every keyword in the folder with its count. See [Collections and Keywords](Collections-and-Keywords). Below: history and snapshots, and export.

## Loupe, Compare and Survey

**Loupe** (E, or Space from the grid) shows one image full size with a caption. Arrows step, Z toggles fit and 100%, rating keys act on the image shown. With View › Mirror Image Mode on it is drawn mirrored, and zooming, panning and the magnifier follow the mirrored picture.

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

**Show Loupe on Second Display** (View menu, with two or more displays) fills another display with the image at fit and its caption, clear of that display's menu bar and Dock. It is for looking only: zoom, pan and tools stay in the main window. It shows what Develop, Loupe or Compare's candidate shows, before/after and the mask overlay included; in Survey, the outlined pane; from the grid it shows the selected image. With HDR display on, the image is rendered for the brighter of the two screens, so an ordinary main screen beside an XDR display shows the HDR render with its highlights fitted to it, as an XDR screen at low brightness does. It closes when its display is unplugged or the main window closes.

## Applying edits to many images

With several images selected, ⇧⌘V pastes copied settings onto all of them, and the Apply Preset menu applies a preset to all. Which parts travel is set under Presets and Clipboard in Develop; by default the look travels and masks and crops do not.

A pasted or preset **Touch-up** carries its sliders but not the faces they were found on, so after the paste Latent finds the faces in each of those photos itself: a "Finding faces" job runs in the background, with its progress and a Cancel face search button in the left panel, and writes the faces (and, with Remove blemishes on, the blemishes) back as one undo step, "Find Faces (12 Images)". A photo with no face is left alone and named in the panel's notes. In Loupe, Compare and Survey the job runs for the image shown; in Develop the open image finds its faces on the spot, and the job leaves that one to the editor rather than finding them twice. Opening another folder while the job runs ends it without writing anything, the same as Remove Dust below.

### Remove Dust

**Photo › Remove Dust…** finds sensor dust in every selected photo and heals it, the batch version of Develop's Sensor Dust (see [Develop](Develop#modules)). In the Library it takes the selection; in Loupe, Compare and Survey the image shown; in Develop it works on the open image in memory, where ⌘Z takes it back. The dialog says how many photos it will touch and offers three ways to find the spots:

- **Find spots in each photo** analyses every photo on its own.
- **Use dust map:** looks in each photo for the spots of a saved map, and heals only the ones that are there. The popup lists the maps saved for the selected photos' cameras, newest first; with none it reads "No dust map for Nikon D750 yet".
- **New dust map from reference photo…** makes a map first, from a raw you choose with **Choose File…** (a plain surface such as the sky at f/16 shows the dust best) or from the selected photo with **Use the selected photo**, saves it for that camera, then uses it on the selection.

**Sensitivity** (0–100, 50 to start) and **Spot Size** (Small, Medium or Large) are the detector's settings, the same as in Develop, and are remembered, as is the last method and map. A map belongs to one camera at one sensor size, so a photo from another camera is skipped; the dialog counts them before you start ("3 of 12 photos are from another camera and will be skipped"). **Remove Dust** waits while an export or a merge has the graphics processor.

The job runs in the background, one photo at a time, with "Photo 3 of 12: DSC_0107.NEF" and a Cancel dust removal button in the left panel; quitting stops it and keeps the photos already done. Nothing is written until the job ends, then every photo's spots are saved together as one undo step, "Remove Dust (12 Images)", and the panel reports "Removed dust from 11 photos (412 spots) in 38 s". A photo whose edit changed while the job ran, or that couldn't be read, is left alone and named in the notes. Opening another folder while the job runs gives it nowhere to write, so it ends with "Remove Dust cancelled · the folder changed, so nothing was written" and the first folder's photos are untouched; run it again in that folder. The spots go in as heal patches under Sensor Dust, ahead of any patches of your own, so a photo's existing spot removal is untouched; a spot already under one of your patches is not added twice.

## Background activity

Long jobs run in the background while you keep working: making thumbnails, an export, Remove Dust and Find Faces, a Photo Merge, a print or contact sheet, and a watched-folder import. The left panel shows how far each has got.

**Pause** sits beside Cancel for thumbnails, exports, Remove Dust and Find Faces. Pausing lets the file or photo under way finish, then starts nothing new and shows "Paused"; **Resume** carries on from the next one, with nothing lost or done twice. A paused export or selection job keeps its turn on the graphics processor, so another export or merge can't start until it is resumed or cancelled. Cancel, opening another folder and quitting stop a paused job exactly as they stop a running one: a cancelled Remove Dust or Find Faces still keeps the photos already done. Thumbnails start unpaused in every folder you open; while paused, the grid shows the embedded previews already made.

The **Activity** button in the status bar appears while anything runs in the background (it shows a pause symbol when everything is paused). Click it for a list of each job with its progress, Pause or Resume, and Cancel. A Photo Merge, a print and a watched-folder import are single steps with nothing to pause between, so they have Cancel (where they can be stopped) but no Pause.

## Virtual copies

A virtual copy is another version of a photo: its own edit, rating, flag, colour label, rotation, keywords, history and snapshots, sharing the one raw file. Use one to try a black-and-white version beside the colour one, or a square crop beside the full frame, and keep both. A copy takes no disk space beyond its sidecar and thumbnail.

**Create Virtual Copy** (⌘', the Photo menu or the grid's right-click menu) makes one copy of each selected image; in Loupe and Develop, of the image shown, and the new copy opens in its place. The copy starts as the image looked: the same edit, rating, flag, label, rotation and keywords. Its history and snapshots start empty and are its own from then on. A copy of a copy is another copy of the same photo.

**In the grid** a copy sits right after its photo (the master) when sorted by capture time or file name, with a stacked-squares mark at the bottom-left of its picture. Its name is the master's with the copy's number, "DSC_0107 (Copy 2).NEF", and the left panel says "Virtual copy of DSC_0107.NEF". The filter's file-name search finds copies by that name, so typing "Copy" shows them all.

**Editing, exporting, printing and slideshows** use the copy's own settings with the master's raw file. An export is named from the copy's name, so with the default {name} template the copy of DSC_0107.NEF exports as "DSC_0107 (Copy 2).jpg" and never takes the master's name.

**Set Copy as Master** (Photo menu or right-click, with one copy selected) swaps the settings of the copy and its master: the master takes the copy's edit, rating, flag, label, rotation, keywords, history and snapshots, and the copy takes the master's. Use it when the copy has become the version you want to keep as the photo itself. ⌘Z swaps them back.

**Remove Virtual Copy** (Photo menu or right-click) takes the selected copies out of the catalog. Masters in the selection are left alone, and the raw file is never touched. ⌘Z puts a removed copy back exactly as it was.

**Copies follow their master.** Renaming or moving the master, with Latent's Rename and Move or in Finder, takes its copies along, with everything they hold. If the master's file is deleted or moved to another folder's catalog, its copies leave the catalog with it. Each copy has its own sidecar in `_latent/xmp/.virtual-copies`, so a catalog rebuilt from its sidecars gets its copies back, and so does a master whose file is put back in the folder.

**Moving, copying or duplicating a copy** acts on its master's file: Move to Folder moves the master, with all its copies; Copy to Folder and Duplicate copy the master's file with the master's settings. To get a copy's settings into a file of its own, use Set Copy as Master first, or export it. Rename is not available for a copy, since it has no file of its own.

<!-- RECONCILE: two branches edited this; merge into one text -->
## Verifying files

**Photo › Verify Files…** reads the selected photos' files again, or every file in the folder when nothing is selected, and compares each with the content hash the catalog recorded when it last saw the file change. Lightroom does this for DNGs only (Validate DNG Files); Latent does it for every file it catalogues, raws included. It runs in the background, with its progress and Cancel in the left panel, and reads from the disk rather than from memory, so a file opened a minute ago is still checked on disk. Each file is:

- **Verified**: its content matches.
- **Changed since the last scan**: its size or date differs, so something changed it on purpose (another app saved it, it was replaced). Refresh Folder (⌘R) records the new content.
- **Damaged**: the same size and date, but different content. Nothing changes a file that way on purpose: it is silent corruption from a failing disk, a bad copy or a damaged backup. Restore it from a backup.
- **Missing** or **couldn't be read**.

When the run ends a sheet lists what was not verified, with **Select Damaged Photos** to select them in the grid. A damaged photo has a red warning triangle at the top-left of its thumbnail (its virtual copies too, since they share the file) until the file changes, for example when you restore it. Verify reads each file once: a virtual copy is checked through its master's file. Stopping it, or quitting, keeps the results for the files already checked.

## Finding duplicates

**Photo › Find Duplicates…** lists photos in the folder whose files are byte-for-byte identical, in groups. Virtual copies share their file on purpose and are never counted. A second list, **Same moment, camera and size, different files**, shows photos taken at the same second by the same camera at the same pixel size whose files differ, such as a copy with rewritten metadata; treat those as likely rather than certain duplicates. In each group the first photo is the one to keep: one with an edit, then the higher rating, then the first by path. Click a photo to select it in the grid. **Select All but First** selects the rest of every group, and **Reject All but First** also flags them rejected (⌘Z takes it back); tick **Include same-moment photos** to take in the second list too. Latent never deletes a file, so removing the rejected ones is up to you in Finder.

## Stacks

A stack folds photos that belong together, such as a burst, a bracket or the frames of a panorama, under one thumbnail, so the grid stays tidy while you cull. Everything is in **Photo › Stacking** and the grid's right-click menu, in the Library grid.

**Group into Stack** (⌘G) puts the selected photos in one stack, with the lead photo (the one the left panel shows) on top. A selected photo that is already in a stack brings its whole stack, so grouping two stacks merges them. A new stack starts collapsed. **Unstack** (⇧⌘G) takes apart every stack the selection touches; **Remove from Stack** takes only the selected photos out, and a stack left with one photo stops being a stack.

**Collapsed and expanded.** A collapsed stack shows its top photo alone, with a chip at the top-left of the picture giving the number of photos in it (▤ 3). Expanded, all its photos show, side by side, each numbered 1/3, 2/3 and so on. **S** (or Expand or Collapse Stack) turns the selected stacks the other way; **Expand All Stacks** and **Collapse All Stacks** do every stack in the folder. **Move to Top of Stack** (⇧S) makes the lead photo the one a collapsed stack shows.

**Auto-Stack by Capture Time…** stacks the whole folder by time: photos taken within the number of seconds you give (60 to start, and remembered) of the one before go into one stack, earliest on top. Photos already in a stack, and photos with no capture time, are left alone.

**Sorting and filtering.** A stack's photos stay together, in stack order, where the first of them falls in the sort. Filters, collections and smart collections look at every photo in a stack: when the top photo doesn't match but another does, a collapsed stack shows the highest photo that matches, so a match is never hidden inside a stack. Ratings, labels and the other marks belong to each photo, not to the stack, and commands such as Export act on the photos selected, so selecting a collapsed stack's top exports that photo alone.

Grouping, unstacking, removing, moving to the top and auto-stacking can be undone; expanding and collapsing is a way of looking and can't. Stacks are kept in the folder's catalog, not in sidecars (see [Limitations](Limitations#workflow)). An export can join its original's stack: see Add to this catalog under [The sheet](Export#the-sheet).
<!-- /RECONCILE -->

## Undo

⌘Z and ⇧⌘Z undo and redo what you did in Library, Loupe, Compare and Survey: ratings, picks and rejects, colour labels, titles, captions, creators and copyrights, rotation, keywords (added, removed, renamed or deleted), collections (made, renamed, moved, deleted, photos added or taken out), settings pasted or presets applied, a Custom sort rearrangement, virtual copies made, removed or set as master, stacks grouped, taken apart or auto-stacked, and moves, copies, duplicates and renames. The Edit menu names the step, as in Undo Paste Settings (12 Images). Each image goes back to its own previous value. In Develop, ⌘Z steps through that image's edit history instead, and while you are typing in a field, ⌘Z undoes only the typing. Opening another folder clears the undo of ratings, flags, labels, titles and the other text fields, rotation, keywords, collections, settings and rearrangements; moves, copies and renames can still be undone.

## Moving, copying and renaming

**Move to Folder…** and **Copy to Folder…** (File menu) act on the selection. So do the grid's right-click Move to Folder and Copy to Folder menus, which list the last five folders used and then Choose Folder…. You can also drag thumbnails onto a folder in the sidebar: that moves them, and holding ⌥ copies.

Ratings, flags, keywords, edits, snapshots, history and the thumbnail go with each image. If the destination already has a file of that name, or a sidecar left behind by one, the image gets a number ("DSC_0107 2.NEF") and its old name is kept in the sidecar as its original file name. A folder without a catalog gets a `_latent` folder only when an image brings a sidecar. A subfolder inside the open catalog that is still to be asked about (one just made with New Folder in the panel, say) is asked about first: include it in this catalog, or keep it separate as a catalog of its own. One you chose to keep separate is a catalog of its own.

Progress shows in the status bar with a stop button. Stopping, or quitting, finishes the image under way, so no image is left half-moved; quitting waits up to a minute for it, and an image still being copied then stays where it was. While an export, print, contact sheet or Photo Merge is running, images can't be moved, copied, renamed or dropped on a folder, and those can't be undone. ⌘Z moves images back; undoing a copy puts the copy and its sidecar in the Trash. Nothing is ever overwritten or permanently deleted, apart from thumbnails, which are made again, a moved image's old sidecar, whose contents are already in the new one, and, for a move to another disk, the original once its copy is complete.

**Rename…** (F2, the File menu or the right-click menu) renames one image, keeping its extension; its sidecar and thumbnail follow. A name that differs only in letter case works.

**Rename with Template…** (File menu or right-click; F2 opens it when several photos are selected) names the selection from a filename template, as Lightroom's Rename Photos does. It works for a single photo too. Type the template, or click the token buttons to add tokens to its end:

| Token | Becomes |
|---|---|
| `{name}` | the original name, without extension |
| `{text}` | the custom text typed below the template, such as the name of the shoot |
| `{seq}` | a sequence number from the start number, three digits (001, 002…), in the grid's order |
| `{date}` | the capture date, 2026-06-01 |
| `{date:yyyyMMdd}` | the capture date in a pattern of your own (yyyy year, MM month, dd day) |
| `{time}` | the capture time, 143005 |
| `{title}` | the photo's title |
| `{camera}`, `{rating}`, `{folder}` | the camera model, the stars, the subfolder |

Anything else in the template is used as typed, and the extension is always kept. The template, custom text and start number are remembered, and the template language is the same as the export's file naming.

The sheet lists every photo with its new name before anything happens. Photos whose name wouldn't change are left alone. A photo isn't renamed, and the list says why, when two photos would get the same name (add `{seq}`), when the name belongs to another file, or when two photos would swap names. A photo may take a name another photo of the batch is giving up: they are renamed in an order that frees each name first. The whole rename is one step of ⌘Z, and every photo's original name is kept in its sidecar.

**Duplicate** (File menu or right-click) makes a true copy of each selected file in its own folder, numbered as Copy to Folder numbers it ("DSC_0107 2.NEF"), with its ratings, keywords, edit, history, snapshots and sidecar. It is a second raw file on disk, unlike a [virtual copy](Library#virtual-copies). ⌘Z puts the duplicates in the Trash.

The JPEG of a RAW+JPEG pair goes with its raw in all of these (see [RAW+JPEG pairs](#rawjpeg-pairs)). If the JPEG can't take the raw's new name because a file already has it, the raw is renamed and the JPEG keeps its old name; the status bar says so.

These commands work in the Library grid, and not while an export, print, contact sheet or Photo Merge is running.

## Slideshow

**View > Slideshow** (⌘Return) plays the selected images, or every image the filter shows when one or none is selected, starting at the selected image, in the grid's order. The menu bar and Dock hide during the show.

Slides are the photos with their edits (crop, masks, everything except AI noise reduction), made at the size of the screen, so the first can take a moment. ← and → (also ↑ and ↓, Page Up and Page Down) step, Space pauses, and Esc or a click ends the show. Moving the pointer shows previous, pause, next and end buttons. The display doesn't sleep while the show plays, but may while it is paused. A photo that can't be shown is skipped.

**Settings › Slideshow** sets the seconds per slide (1–60), the transition (Cut, Cross-Fade, Fade Through Black, Push or Zoom) and its length (0.3–3 s), whether to start again after the last slide, the caption (none, file name, name and date, or camera and exposure), and music: songs added from disk, played in order and round again, paused with the show.
