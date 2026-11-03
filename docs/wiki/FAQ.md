# FAQ

Short answers to the questions people ask first, with links to the long ones. For error messages and things that went wrong, see [Troubleshooting](Troubleshooting).

## Installing and opening

### Why does macOS say Latent can't be opened?

Latent is signed *ad hoc*, without an Apple developer account, and isn't notarised by Apple, so Gatekeeper stops it the first time it opens on a Mac. It is a one-time step:

1. Try to open Latent once, and dismiss the dialog.
2. Open **System Settings › Privacy & Security**, scroll to the message about Latent, and click **Open Anyway**.

On older versions of macOS, Control-click (or right-click) › **Open** did the same, but since macOS 15, which Latent needs, only **Open Anyway** in Privacy & Security works. See [Installation](Installation#the-gatekeeper-dialog).

### Which Macs does it run on?

Apple Silicon Macs (any M-series chip) with macOS 15 or newer. There is no Intel, Windows or Linux version.

### Does it cost anything?

No. Latent is free and open source, under the GPLv3 licence. See [Licences](Licences).

## Privacy and network

### Does Latent connect to the internet?

No. Latent makes no network requests at all: no telemetry, no analytics, no crash reports, no update check. The app doesn't have the permission to open a network connection, so macOS itself enforces this. The help pages ship inside the app; a web link in them opens in your browser. See [Security and Privacy](Security-and-Privacy#no-network).

### Are my photos uploaded for the AI features?

No. Subject and sky masks, Detect Objects, Lens Blur's depth, AI noise reduction, red-eye and Touch-up all run on your Mac.

### Does Latent download models?

Never. Some models come with the app. Others you add yourself: **Settings › AI › Models** lists them, and **Get…** only opens the model's page in your browser. You download and convert the model (see [Converting Models](Converting-Models)), then bring it in with **Add Model…**, which checks it before keeping it. See [Models](Models).

### Can I use Select by Class for paid work?

Select by Class uses the bundled SegFormer model, whose licence allows research and evaluation use only, not commercial use. Settings › AI › Models marks it **Research use only**, as it does IS-Net, a subject model you can add. The other masks don't use it: Subject (BiRefNet Lite or Apple Vision), Click to Select, Select Objects, brushes, gradients and ranges. Read the licence itself on [Licences](Licences) and decide for your own work; this page isn't legal advice.

## Files and catalogs

### Does Latent change my raw files?

No. Edits, ratings and keywords are kept in Latent's catalog and sidecars, never written into your files. Latent moves, copies or renames a file only when you ask it to, and never writes over or permanently deletes a photo; undoing a copy puts the copy in the Trash.

### Where is my catalog?

In a `_latent` folder inside each photo folder. Each folder is its own catalog. Back up the folder and you back up its catalog; move it to another disk or Mac and the catalog goes with it. See [The catalog](Library#the-catalog).

### Can I import my Lightroom catalog?

No. Latent can't read Lightroom catalogs, presets or edits, or the `.xmp` files Lightroom writes beside raws. See [Coming from Lightroom](Coming-from-Lightroom).

### How do I get photos off my memory card?

Copy them into a folder with Finder, then open that folder in Latent. If the folder is already open, they appear by themselves. To have photos brought in automatically from the folder a card reader or tethering app saves into, use **Auto Import** in **Settings › Folders**. See [Watching folders](Library#watching-folders).

### What's the difference between a virtual copy and Duplicate?

A **virtual copy** (⌘') is another version of a photo in the catalog, with its own edit, sharing the same raw file; it takes almost no space. **Duplicate** makes a real second raw file on disk. See [Virtual copies](Library#virtual-copies).

### Which cameras work?

Raw files from most cameras with a Bayer sensor, read by LibRaw. Fujifilm X-Trans and Sigma Foveon files show their details but don't render. JPEG, HEIC, TIFF and PNG work too. See [Supported files](Library#supported-files).

## Editing

### Why is Detect Objects, or Click to Select, greyed out?

They need a click-to-select model. SAM 2.1 Small comes with Latent; if it was removed, add a click-to-select model in **Settings › AI › Models**. See [Models](Models).

### Lens Blur blurs everything evenly behind my subject. Why?

Without a depth model, Lens Blur makes just two planes from the subject mask: sharp subject, evenly blurred background. A depth model gives every part of the scene its own distance. None is bundled; Depth Anything V2 Small can be converted and added. See [Lens Blur](Develop#lens-blur).

### Can Remove invent what's behind something?

No. Remove fills from the photo itself, without a generative model. It is good at sky, grass, water, walls and sand, but can't make up a hidden face or lettering. See [Remove and Detect Objects](Develop#remove-and-detect-objects).

### Why does my print look darker than the screen?

A screen glows, paper reflects. Soft proof the photo with the paper's profile and **Simulate Paper & Ink**, and adjust before printing. See [Tutorial: Printing and Sharing](Tutorial-Printing-and-Sharing#soft-proof-and-export-for-print).

## Report an issue or get help

Latent has no support desk, but bug reports and questions are welcome on GitHub.

1. Look first in [Troubleshooting](Troubleshooting) and [Limitations](Limitations): your problem may be known, with a way round it.
2. Search the existing reports on GitHub: [github.com/Harmanjit/latent-raw/issues](https://github.com/Harmanjit/latent-raw/issues). If yours is there, add what you know to it.
3. Otherwise open a new issue there. A free GitHub account is needed. Include:
   - Latent's version (**Latent › About Latent**), your Mac's model and chip, and the macOS version.
   - What you did, what you expected, and what happened instead, step by step.
   - The exact wording of any message in the status bar.
   - For a raw that won't open or looks wrong, the camera model; attach a sample file if you are happy to share it publicly.

Nothing is ever sent from inside the app, so a report only reaches the project if you write one.
