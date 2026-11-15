# Filter Bar

The filter bar sits above the Library grid. It hides the photos you don't want to see right now, so you can find the ones you do. It never moves, changes or deletes a photo.

Everything you set in the bar must be true at once: "4 stars or more" and "Nikon" shows only 4-star-or-better photos from a Nikon. The count in the bar says how many photos pass. **View › Clear Filters** (⇧⌘L) clears everything and shows every photo again.

While a collection is shown, the filter narrows that collection's photos. The full reference is in [Library](Library#the-grid); this page shows how to use it.

## What is in the bar

From left to right:

- **Stars**: click a star for "this many or more". The small arrow after the stars opens the rating range.
- **Flags**: show only picks, unflagged photos or rejects, or any mix of them.
- **Label**: the colour labels to show. Choose several to show photos with any of them.
- **Edited**: show only photos you have edited.
- **Camera**, **Lens**, **Keyword** and **Tag** (Finder tag) menus.
- **Kind**, **Ranges** and the date button.
- The **search box**, with a magnifying glass before it.
- The **Sort** menu and the thumbnail size slider.
- The **filter presets** button at the right end.

## Searching

Type in the search box. By default it looks for the text in the file name, title and caption, as one piece.

For more, click the magnifying glass before the box and choose **All Searchable Fields**. Now the search looks in the name, folder path, title, caption, creator, copyright, camera, lens and keywords, and it understands three rules:

- **Every word must match** (AND). `beach sunset` shows only photos that have both words somewhere.
- **"Quoted phrases"** match as one. `"blue hour"` finds those two words side by side, not anywhere.
- **-word leaves photos out.** `beach -dog` shows beach photos without the word dog.

You can mix them: `nikon "blue hour" -raw`. Upper and lower case don't matter.

Choose **File Name, Title and Caption** from the same menu to go back to the simple search.

## Rating ranges

Click the small arrow after the stars. The popover offers:

- **At least**: this many stars or more (what clicking a star does).
- **Exactly**: only this many stars. **Exactly** with no stars shows the unrated photos.
- **At most**: this many stars or fewer.
- **Between**: a range with two ends, such as 2 to 4 stars.

## The Ranges histograms

**Ranges** opens a popover with four small histograms: **ISO**, **Focal length**, **Aperture** and **Exposure time**. Each bar is how many of the folder's photos have that value. Under each histogram is a range with two thumbs.

- **Drag a thumb** to narrow the range.
- **Click a bar** to show just that bar's photos.
- **Shift-click** another bar to stretch the range to it.
- **Double-click** to clear that range.

A photo that doesn't record the value is hidden while its range is set. **Clear Ranges** clears all four.

## Date range

Click the date button. Set **From** and **To** dates for when the photos were taken, or click **Today**, **Last 7 Days**, **This Month** or **This Year**. **Any Date** clears it. Photos without a capture date are hidden while a range is set.

## Kinds

The **Kind** menu has three sections:

- **File**: **Raw** (camera raws and DNG), **Not Raw**, or **RAW+JPEG Pair**.
- **Copies**: **Masters**, **Virtual Copies**, or masters that **Has Virtual Copies**.
- **File Integrity**: **Damaged Files**, **Verified OK** or **Not Verified**, from what Verify Files last found.

## Unedited and No Keywords

- **Unedited**: hold ⌥ (Option) and click **Edited**. Now only photos without an edit show. Click it again to show everything.
- **No Keywords**: choose it at the top of the **Keyword** menu to find photos you haven't keyworded yet. The Keyword List in the left panel has it too, with a count.

To hide a colour label instead of showing it, ⌥-click it in the **Label** menu. It shows as "−Red" on the button.

## Filter presets

The filter presets button at the right end of the bar keeps filters you use often.

- **Save Current Filter…** saves the bar's settings under a name.
- Click a saved preset to apply it.
- **Rename** and **Remove** look after them.

Presets belong to the app, so every folder can use them.

## Remember Filter per Source

In the same filter presets menu, tick **Remember Filter per Source**. Now each folder, and each collection, keeps its own filter. When you come back to it, its filter comes back too. A folder or collection you have never filtered shows everything. It is off to start with.

## Similar to This Photo

Select one photo and choose **View › Similar to This Photo** (or right-click the photo). The filter now shows photos taken with the same camera and lens, within a day of it.

A **Similar to …** chip appears in the bar. Click it to switch off **Same camera**, **Same lens** or **Within a day of …**, which widens the search. Click its ✕ to stop. Choosing a camera, lens or date yourself, or ⇧⌘L, also ends it.

## Save Filter as Smart Collection

**File › Save Filter as Smart Collection…** turns the filter into a smart collection that keeps itself up to date. The sheet opens with one rule for each thing the bar is doing. Name it and click **Create**.

Not every setting can become a rule yet: the ranges, the date range, the kinds (except File Integrity), Unedited, No Keywords, excluded labels and the rating's Exactly, At most and Between are left out. Save those as a filter preset instead. See [Limitations](Limitations) and [Smart collections](Collections-and-Keywords#smart-collections).

## How to: find your best photos from one lens

1. Click the fourth star in the bar to show photos with 4 stars or more.
2. Choose your lens from the **Lens** menu.
3. To keep this view, choose **File › Save Filter as Smart Collection…**, name it ("Best of the 85mm") and click **Create**.

## How to: find unedited, unkeyworded raws from last week

1. Click the date button and click **Last 7 Days**.
2. Choose **Kind › Raw**.
3. ⌥-click **Edited** to show only unedited photos.
4. Choose **No Keywords** in the **Keyword** menu.
5. Open the filter presets menu, choose **Save Current Filter…** and call it "To do". Next week, one click brings it back.

## How to: search for a phrase but leave some photos out

1. Click the magnifying glass before the search box and choose **All Searchable Fields**.
2. Type `"golden hour" beach -crop`.
3. The grid shows photos that mention "golden hour" and beach, but not crop.

## How to: find your low-light shots

1. Click **Ranges**.
2. On the **ISO** histogram, click the bar for ISO 3200.
3. Shift-click the highest bar to include everything above it.
4. Double-click the histogram when you want to clear it again.

## How to: find more photos like this one

1. Select a photo in the grid.
2. Choose **View › Similar to This Photo**.
3. To see photos from any day, click the **Similar to …** chip and switch **Within a day of …** off.
