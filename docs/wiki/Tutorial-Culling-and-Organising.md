# Tutorial: Culling and Organising

Two walkthroughs for the Library: getting from a full card to a handful of keepers, then organising them so you can find them again. They assume you have read [Getting Started](Getting-Started). Every key here is also in the menus, and on [Keyboard Shortcuts](Keyboard-Shortcuts).

## Cull and rate a shoot

The aim: one pass to throw out the obvious misses, one to choose between near-identical frames, and stars for what is left.

**1. Get the photos in.** Copy the card into a folder of its own with Finder, say `Pictures/2026/2026-10-12 Coast`. In Latent, click that folder in the sidebar (if it is inside a favourite), or choose **File › Open Folder…** (⇧⌘O). If Latent is already showing the folder, the new files appear by themselves; **Recently Added** in the sidebar shows just them.

**2. Look at each photo big.** Click the first thumbnail and press E (or Space) for Loupe. ← and → step through the photos. Press Z, or double-click, to check focus at 100%, and Z again to go back. On a fitted photo you can also hold the mouse button down for a magnifier under the pointer.

**3. First pass: pick or reject.** For each photo press **P** to pick it or **X** to reject it, then →. Leave the ones you're unsure of unflagged. U clears a flag. Don't agonise: this pass is about speed.

**4. Hide the rejects.** Press G for the grid. In the filter bar above it, the three flag buttons, ✓ (picked), – (unflagged) and ✗ (rejected), choose which photos show. Click ✓ and – so that picks and unflagged photos show and rejects are hidden. The count beside the filter says how many are left.

**5. Choose between similar frames.** Select two to four photos of the same moment (click one, ⌘-click the others) and press **N** for Survey. Each photo is as large as the window allows. Click a pane, or press ← and →, to move the blue outline. Press **/** to drop the outlined photo from the survey (it is deselected, not deleted), and **P** to pick the winner. With one photo left, Survey becomes Loupe.

To go through a long burst two at a time, use **Compare** (C) instead: the photo on the left is the "Select", and ← and → walk the "Candidate" on the right. When a candidate is better, press **⇧X** to make it the Select. With Sync on, zoom and pan stay matched in both.

**6. Give stars.** Click – in the filter bar again so only ✓ is on and only picks show, then go through them with **1** to **5**. A common scheme: 3 for good, 4 for the best of the shoot, 5 for portfolio. **0** clears the stars.

**7. Add colour labels if you need a second dimension.** **6** red, **7** yellow, **8** green, **9** blue; purple is in **Photo › Label**. For example, red for the client's choices and green for photos to print. Pressing the same key again takes the label off.

**8. Deal with the rejects.** Latent never deletes photos. To clear them out, click the flag buttons so only ✗ is on, select them all (⌘A) and choose **File › Move to Folder…** to put them in a "Rejects" folder, or delete them in Finder later.

**9. Clear the filter** with ⇧⌘L to see everything again. Anything you did here can be undone with ⌘Z, step by step.

## Organise with collections, smart collections and keywords

Folders say where photos are on disk. Collections and keywords say what they are, without moving a file. Full details are on [Collections and Keywords](Collections-and-Keywords).

**1. Add keywords.** Select the photos (in the grid, click and ⇧-click), then in the left panel type in **Add keywords** and press Return. Separate keywords with commas, and put **>** between levels for a hierarchy:

```
Places > France > Brittany, coast, sunset
```

The keywords go on every selected photo. As you type, keywords you have used before are suggested below the field.

**2. Use the Keyword List.** Open **Keyword List** in the left panel to see every keyword in the folder, with how many photos carry it. Click a keyword's name to show only its photos; tick its checkbox to put it on the selected photos. Right-click a keyword to rename or delete it everywhere.

**3. Collect quickly with B.** Press **B** to put the selection in the **Quick Collection**, which Latent makes the first time. Press B again with the same photos selected to take them out. It is a scratch pile: for photos to send someone, or to look at together.

**4. Make a collection.** Select the photos and press **⌘N** (**File › New Collection…**). Name it, say "Portfolio candidates", and leave **Include the selected photos** ticked. Later, drag more thumbnails onto it in the sidebar, or right-click a selection and choose **Add to Collection**.

**5. Group collections in a set.** **File › New Collection Set…** makes a set, say "Clients"; drag collections into it, or right-click a set for **New Collection Inside…**.

**6. Make a smart collection.** **File › New Smart Collection…** opens the rules. For "my best Brittany photos": choose **all** rules must match, then **Rating** is at least **4**, and **Keyword** is **Places › France › Brittany**. The sheet shows how many photos match as you build it. It keeps itself up to date: rate another Brittany photo 4 stars and it appears.

A shortcut: set up the filter bar the way you want, then choose **File › Save Filter as Smart Collection…**.

**7. Keep two versions of one photo.** To have a colour and a black and white version side by side, select the photo and press **⌘'** (**Photo › Create Virtual Copy**). The copy shares the raw file but has its own edit, rating and keywords. Open it in Develop and press **V** for black and white. See [Virtual copies](Library#virtual-copies).

**8. Add a title, caption and copyright.** In the left panel's **Title & Copyright** section, type a title and caption, your name as **Creator**, and a copyright notice. With several photos selected, what you type goes on all of them. Exports carry these, so photo sites show them. See [Library](Library#title-caption-creator-and-copyright).

**9. Rename the files.** Select the keepers and choose **File › Rename with Template…** (or press F2 with several selected). A template such as `{date}_{text}_{seq}`, with "Brittany" as the custom text, names them `2026-10-12_Brittany_001.NEF` and on. The sheet lists every new name before anything changes, and one ⌘Z puts them all back. See [Library](Library#moving-copying-and-renaming).
