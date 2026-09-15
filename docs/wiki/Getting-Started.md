# Getting Started

## Open a folder

⇧⌘O (File > Open Folder…), or the Open Folder button in the left panel. Choose a folder of raw files. Latent creates a `_latent/` directory inside it holding the catalog, one sidecar per image and thumbnails, then shows the grid. Thumbnails come from the cameras' embedded previews and appear within seconds even for thousands of files.

For folders you come back to, add a parent folder to the sidebar on the far left: click **Add Folder…**, or drag folders in from Finder. Every folder inside a favourite then opens with one click, with no open panel. See [Library](Library#the-sidebar).

Subfolders are asked about the first time: include them in this catalog, or keep them as separate catalogs of their own. The answer is remembered per catalog, and a default can be set in Settings.

There is no import step. Copy files into a folder however you like, then open the folder. Opening it again later re-scans by name, size and modification time and decodes nothing unless something changed.

## The five views

Switch with the segmented control in the status bar, the View menu, or the keys.

| View | Key | Purpose |
|---|---|---|
| Library | G | The grid. Select, rate, flag, filter, sort, export. |
| Loupe | E or Space | One image full size, arrows step through the filtered list. |
| Compare | C | Two images side by side, zoom and pan kept together while Sync is on. |
| Survey | N | Two to four selected images side by side, for picking the best of a burst. |
| Develop | D or Return | The editor, with the adjustment panel on the right. |

Loupe and Develop show a filmstrip of the grid's images along the bottom; the film button in the status bar hides it. F shows the image full screen, and ⌘Return plays the selection as a slideshow.

## Rate and flag

0–5 for stars, P to pick, X to reject, U to clear. ⌘[ and ⌘] rotate. In the grid you can also click the stars under a thumbnail. In the Library grid these act on every selected image; in Loupe, Compare and Develop, on the image shown, and in Survey on the outlined pane. Outside Develop, ⌘Z undoes them. Keywords, typed in the left panel, apply only to the image named there (with several selected, the one clicked last). All of these are written to the sidecar immediately and survive a relaunch, a catalog rebuild, or a move of the folder to another Mac.

## Edit

Open an image in Develop. Drag sliders; the image updates as you drag at full quality. Double-click any slider to reset it, or click its value to type one. Edits are saved a second after you stop, or at once when you quit, to the sidecar and the catalog, and the thumbnail regenerates in the background. Press `\` to see the unedited image while held.

## Export

Select one or many images in the Library and press ⇧⌘E. Choose format, size, naming and destination, or pick a saved preset. ⌘P prints, and File > Contact Sheet… lays the selection out on pages. See [Export](Export).

## Help

**Help > Latent Help** (⌘?) opens these pages inside the app, with search. The menu bar lists every command, with its key.

## Where things are

- Your photos: untouched, wherever they were.
- The catalog: `_latent/` inside the photo folder.
- Settings and compiled ML models: `~/Library/Containers/com.latent.app/`.
- Saved edit presets: the same container, under Application Support.
