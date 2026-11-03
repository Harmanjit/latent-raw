# Collections and Keywords

Folders hold photos where they live on disk. Collections and keywords let you gather and label them however you like, without moving a file.

## Collections

The **Collections** section sits in the sidebar under your folders. It lists the collections of the folder that is open: each folder is its own catalog, so each has its own collections, and a collection holds photos from that folder (and the subfolders it includes).

There are three kinds:

- **Collection**: photos you put there by hand. A photo can be in any number of collections, and the file stays where it is.
- **Smart collection** (the gear icon): photos that match rules you set, such as "rating is at least 4 and keyword is Places › France". It keeps itself up to date: rate a photo 4 stars and it appears at once.
- **Collection set** (the folder icon): holds other collections, smart collections and sets, to keep a long list tidy.

**Showing a collection.** Click it, and the grid shows only its photos. The filter bar still works on top, so you can show the picks in a collection, say. Click the collection again, or **All Photographs** at the top of the list, to see the whole folder. The number beside each collection is how many photos it holds; for a set, how many are in the collections inside it.

**Making one.** Click the **+** at the right of the Collections heading, or choose **File › New Collection…** (⌘N), **New Smart Collection…** or **New Collection Set…**. A new collection can start with the photos selected in the grid, and can go inside a set. Right-click a set for **New Collection Inside…** and the like.

**Adding photos.**

- Drag thumbnails from the grid onto a collection in the sidebar.
- Right-click the selection in the grid and choose **Add to Collection**, then the collection. A tick shows the ones every selected photo is already in.
- Right-click a collection and choose **Add Selected Photos**.
- Press **B** to add the selection to the **target collection**. Until you choose one, that is the **Quick Collection**, which Latent makes the first time you press B. Press B again with the same photos selected to take them out. To make another collection the target, right-click it and choose **Set as Target Collection**; it shows a **+** after its name.

**Taking photos out.** While the grid shows a collection, choose **Photo › Remove from Collection**, or right-click and choose **Remove from** and the collection's name. Right-clicking a collection in the sidebar offers **Remove Selected Photos** too. Taking a photo out of a collection never touches the file, its edits or its other collections.

**Renaming, moving and deleting.** Right-click a collection for **Rename…**, **Move to** (another set, or the top level) and **Delete Collection**. Deleting a set deletes the collections inside it. Photos are never deleted with a collection.

Every one of these can be undone with ⌘Z (outside Develop), and redone with ⇧⌘Z.

### Smart collections

A smart collection has a name and a list of rules. Choose whether a photo must match **all** of them or **any** of them, then for each rule a field, a comparison and a value. The + and − at the end of each rule add another below it or take it away. The sheet shows how many photos in the folder match as you go.

| Field | Comparisons |
|---|---|
| Rating, ISO, Focal length, Aperture | is at least, is at most, is, is not |
| Flag | is or is not picked, unflagged or rejected |
| Edited | is yes or no |
| Keyword | is, is not (a keyword counts the keywords inside it), contains, doesn't contain |
| Camera, Lens, File name, Finder tag | contains, doesn't contain, is, is not, starts with, ends with |
| File type | is, is not (NEF, DNG and so on) |
| Colour label | is, is not (labels read from sidecars written by other applications) |
| Capture date | is in the last so many days, is, is before, is after |

Text comparisons ignore upper and lower case and accents. A photo with no value for a field (no capture time, say) doesn't match that rule, except under "is not" and "doesn't contain".

**Save the filter bar as a smart collection.** Set up the filter bar the way you want, then choose **File › Save Filter as Smart Collection…** (or from the Collections + menu). The sheet opens with a rule for each thing the filter bar is doing; name it and click Create.

To change a smart collection's rules, right-click it and choose **Edit Smart Collection…**.

### Where collections are kept

Collections live in the folder's catalog, in `_latent/catalog.sqlite`, with a copy in `_latent/collections.json` beside it. Sidecars hold each photo's own ratings, keywords and edits, but a collection belongs to no one photo, so the copy is what brings collections back if the database is ever rebuilt: Latent reads it when it finds a catalog with no collections, and finds the photos again by their names. Moving or renaming a photo with Latent keeps it in its collections. A photo that leaves the folder (moved elsewhere, or deleted in Finder) leaves its collections too.

## Keywords

Keywords are words you attach to photos to find them later: who is in them, where they were taken, what they show. They are written to each photo's sidecar in the standard fields Lightroom and other applications read, and exported files carry them as IPTC keywords.

### Adding keywords

The left panel shows the selected photos' keywords as small chips, under the rating and flag. With several photos selected, a chip with an asterisk (\*) is on only some of them.

- **Add**: type in the **Add keywords** field and press Return. Separate several keywords with commas. With several photos selected, the keywords go on every one of them, and each keeps the keywords it already had.
- **Suggestions**: as you type, keywords already used in the folder that start with or contain what you typed appear below the field. Click one to use it.
- **Remove**: click the × on a chip to take that keyword off every selected photo.
- Click a chip's name to show every photo in the folder with that keyword.

In Loupe and Develop the field acts on the photo shown, as the rating keys do.

### Keywords inside keywords

Keywords can be arranged in a hierarchy, as Lightroom does: **Paris** inside **France** inside **Places**. Type the levels with **>** between them:

```
Places > France > Paris
```

A photo tagged Paris counts as tagged France and Places too: clicking Places in the Keyword List, or filtering on it, shows every photo of every place inside it.

In the sidecar, the keyword is written the way Lightroom Classic writes it: the whole path in `lr:hierarchicalSubject` ("Places|France|Paris"), and each level on its own in `dc:subject` (Places, France, Paris), which is what applications that know nothing of hierarchies read. A Latent sidecar (in `_latent/xmp`) that carries `lr:hierarchicalSubject` is read back with its hierarchy; Lightroom's own sidecars beside the raws are not read, and a keyword added to `dc:subject` alone by another application is kept as a keyword of its own. Exported files get each level as an IPTC keyword.

### The Keyword List

Open **Keyword List** in the left panel to see every keyword in the folder, arranged in its hierarchy, each with how many photos carry it or a keyword inside it. Click the triangle to open a level.

- **Click a keyword's name** to show only the photos with it (the filter bar's Keyword menu shows the same thing). Click it again to show everything.
- **The checkbox** puts the keyword on every selected photo, or, when every selected photo already has it (a tick), takes it off them all. A dash means some of the selected photos have it.
- **Find keyword** at the top narrows the list to keywords whose name contains what you type, keeping the levels above them.
- **Right-click** a keyword for **Rename…** and **Delete Keyword**. Renaming changes the keyword on every photo in the folder that has it; type a path such as `Places > France > Paris` to move it into another keyword, and everything inside it moves too. Deleting takes the keyword, and the keywords inside it, off every photo. Both can be undone with ⌘Z.

The list shows the keywords photos carry: a keyword taken off its last photo leaves the list.

### Filtering

The filter bar's **Keyword** menu lists every keyword in the folder; choosing a keyword shows the photos with it or with any keyword inside it. Smart collections can use keywords as well (see above).
