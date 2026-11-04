# Getting Started

Latent works in a simple loop: look through your photos in the **Library**, edit the ones you want in **Develop**, then **Export** files to share or print. This page walks you through your first session. For step-by-step jobs, see the tutorials: [Culling and Organising](Tutorial-Culling-and-Organising), [Editing](Tutorial-Editing) and [Printing and Sharing](Tutorial-Printing-and-Sharing).

## Before you start

Latent runs on Apple Silicon Macs with macOS 15 or newer. [Installation](Installation) explains how to get it.

The first time you open it, macOS stops it, because Latent isn't notarised by Apple. Try to open it once, then open **System Settings › Privacy & Security**, find the message about Latent and click **Open Anyway**. You only do this once per Mac. See [Installation](Installation#the-gatekeeper-dialog).

## First launch

The window has four parts:

- The **sidebar** on the far left: your favourite folders, then **Collections**, and at the foot **Volumes**, a meter for each disk.
- The **left panel**: the open folder, the **Open Folder…** button, then the selected photo's details, its history and export.
- The **grid** (or the picture, in the other views) in the middle.
- The **status bar** along the bottom, with the switch between the five views and messages about what Latent is doing.

The first time, no folder is open and the left panel says so. After that, Latent opens the last folder you used each time it starts.

## Choose a folder: that is your catalog

Latent has no import step and no single big catalog. **Each folder of photos is its own catalog.** You keep your photos wherever you like, organised in Finder however you like, and Latent keeps its notes in a `_latent` folder inside each one.

1. Choose **File › Open Folder…** (⇧⌘O), or click **Open Folder…** in the left panel, and pick a folder of raw files. JPEG, HEIC, TIFF and PNG pictures in it are catalogued too, and the JPEG of a RAW+JPEG pair stays tucked behind its raw (see [Library](Library#rawjpeg-pairs)).
2. If the folder has subfolders, Latent asks once whether to include them in this catalog or keep them as catalogs of their own. A default can be set in Settings.
3. Thumbnails appear within seconds, even for thousands of files, because they come from the previews your camera already stored in each file.

For folders you come back to, add a parent folder to the sidebar: click **Add Folder…** at its foot, or drag a folder in from Finder. Every folder inside a favourite then opens with one click. See [Library](Library#the-sidebar).

**Adding new photos.** Copy them into the folder with Finder. While a folder is open, Latent notices new, renamed and deleted files by itself; **File › Refresh Folder** (⌘R) checks again at any time. **Recently Added** at the top of the sidebar shows what the latest scan found. To have photos moved in automatically from the folder a card reader or tethering app saves into, set up **Auto Import** in **Settings › Folders** (see [Library](Library#watching-folders)).

**One file on its own.** **File › Open File…** opens a single photo in Develop without its folder. It isn't in a catalog, so its edits aren't saved; export what you want to keep before you open another.

## The five views

Switch with the control in the status bar, the View menu, or a key.

| View | Key | Purpose |
|---|---|---|
| Library | G | The grid. Select, rate, flag, filter, sort, export. |
| Loupe | E or Space | One image full size; the arrow keys step through the photos the grid shows. |
| Compare | C | Two images side by side, zoom and pan kept together while Sync is on. |
| Survey | N | Two to four selected images side by side, for picking the best of a burst. |
| Develop | D or Return | The editor, with the adjustment panel on the right. |

Loupe and Develop show a filmstrip of the grid's photos along the bottom; the film button in the status bar hides it. F shows the image full screen, and ⌘Return plays the selection as a slideshow.

## The loop: Library, Develop, Export

### 1. Library: look, rate and sort

- **Stars**: press 0 to 5. **Flags**: P to pick, X to reject, U to clear. **Colour labels**: 6 red, 7 yellow, 8 green, 9 blue (purple is in **Photo › Label**).
- In the grid these act on every selected photo; in Loupe, Compare and Develop on the photo shown; in Survey on the outlined pane. ⌘Z undoes them.
- The **filter bar** above the grid narrows what you see: by stars, flags, colour label, keyword, camera, lens and more. ⇧⌘L clears it.
- **Keywords** go in the **Add keywords** field in the left panel, onto every selected photo. **Collections** in the sidebar gather photos without moving them. See [Collections and Keywords](Collections-and-Keywords).

Everything you set is written to the photo's sidecar at once, so it survives a relaunch, a catalog rebuild, or moving the folder to another Mac.

### 2. Develop: edit

Select a photo and press D (or Return). The adjustments are on the right, in the order they are applied.

- Drag a slider and the picture updates as you drag, at full quality. Double-click a slider to reset it, or click its number to type a value.
- **Auto Adjust** (⌘U) is a good first step: it sets exposure, contrast and white balance from the photo.
- Press `\` to see the photo without your edits, and again to go back.
- ⌘Z and ⇧⌘Z step back and forward through the photo's edit history.

Your original file is never changed. Edits are saved a second after you stop, to the sidecar and the catalog, and the thumbnail updates in the background. See [Develop](Develop) for every module, and [Masking](Masking) for local adjustments.

### 3. Export: make files

Select one or many photos in the Library and press ⇧⌘E (**File › Export**). Choose the format, size, colour space, naming and destination, or pick a saved preset. **File › Export with Previous** (⌥⇧⌘E) repeats the last export without the sheet. ⌘P prints, and **File › Contact Sheet…** lays the selection out on pages. See [Export](Export).

## Where your work is saved

- **Your photos**: untouched, wherever they were.
- **The catalog**: `_latent/` inside the photo folder: a database, one sidecar per photo (the part that matters) and thumbnails. Back up the folder and you back up the catalog with it.
- **Settings and compiled models**: `~/Library/Containers/com.latent.app/`.
- **Saved develop presets, dust maps, imported camera profiles and models you add**: the same container, under Application Support. See [Models](Models).

## Where the help is

- **Help › Latent Help** (⌘?) opens these pages inside the app, with search. They ship with the app, so they work with no internet connection.
- Point at a control and wait a moment: most buttons and sliders explain themselves in a tooltip.
- The menu bar lists every command with its key, and [Keyboard Shortcuts](Keyboard-Shortcuts) lists them all. **Settings › Keyboard** changes any of them.
- New here from Lightroom? Read [Coming from Lightroom](Coming-from-Lightroom). A word you don't know? Try the [Glossary](Glossary). A question? The [FAQ](FAQ). Something went wrong? [Troubleshooting](Troubleshooting).
- What changed in this release: [What's New](Whats-New).
- To report a bug or ask for help, see [Report an issue or get help](FAQ#report-an-issue-or-get-help).
