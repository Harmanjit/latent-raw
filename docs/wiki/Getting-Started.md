# Getting Started

## Open a folder

⌘⇧O, or the Open Folder button in the left panel. Choose a folder of raw files. Latent creates a `_latent/` directory inside it holding the catalog, one sidecar per image and thumbnails, then shows the grid. Thumbnails come from the cameras' embedded previews and appear within seconds even for thousands of files.

Subfolders are asked about the first time: include them in this catalog, or keep them as separate catalogs of their own. The answer is remembered per catalog, and a default can be set in Preferences.

There is no import step. Copy files into a folder however you like, then open the folder. Opening it again later re-scans by name, size and modification time and decodes nothing unless something changed.

## The four views

Switch with the segmented control in the status bar or the keys.

| View | Key | Purpose |
|---|---|---|
| Library | G | The grid. Select, rate, flag, filter, sort, export. |
| Loupe | E or Space | One image full size, arrows step through the filtered list. |
| Compare | C | Two images side by side, zoom and pan locked together. |
| Develop | D or Return | The editor, with the adjustment panel on the right. |

## Rate and flag

With any image selected, in any view: 0–5 for stars, P to pick, X to reject, U to clear. ⌘[ and ⌘] rotate. These are written to the sidecar immediately and survive a relaunch, a catalog rebuild, or a move of the folder to another Mac.

## Edit

Open an image in Develop. Drag sliders; the image updates as you drag at full quality. Double-click any slider to reset it. Edits are saved a second after you stop, to the sidecar and the catalog, and the thumbnail regenerates in the background. Press `\` to see the unedited image while held.

## Export

Select one or many images in the Library and press ⌘⇧E. Choose format, size, naming and destination, or pick a saved preset. See [Export](Export).

## Where things are

- Your photos: untouched, wherever they were.
- The catalog: `_latent/` inside the photo folder.
- Preferences and compiled ML models: `~/Library/Containers/com.latent.app/`.
- Saved edit presets: the same container, under Application Support.
