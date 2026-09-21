# Latent

**A catalog manager and non-destructive RAW editor for macOS, built for Apple Silicon.**

Latent opens a folder of raw files, keeps a catalog inside that folder, and edits every image on the GPU without touching the original. It is in the same family as Lightroom, darktable and RawTherapee, but it targets one platform only and uses everything that platform has: unified memory, Metal compute, and on-device machine learning.

- **Status:** version 0.9, a beta for review. Everything planned is implemented and tested except **DNG export**, which doesn't exist, and **HDR Panorama**, which works but is marked **experimental** because no real bracketed sweep has ever been merged with it. Panoramas are single-row only. Since the first beta build, Develop has gained **Sensor Dust** (spots found and healed, on one photo or a whole selection), **Touch-up** (skin, teeth, eyes and blemishes, per face) and a choice of **subject-selection models**, with more addable from disk; the dust detector has been tested on synthetic dust and only a few real photos. Expect rough edges, and read [Limitations](Limitations) before relying on it. Please report bugs as [issues on GitHub](https://github.com/Harmanjit/latent-raw/issues).
- **Licence:** GPLv3.
- **Platform:** macOS 15 or newer on Apple Silicon. Verified on M1 Pro and M4.

These pages are also in the app: **Help > Latent Help** (⌘?) shows them with search, and nothing is fetched from the network.

## Pages

| | |
|---|---|
| [Motivation](Motivation) | Why another RAW editor, and why only for this hardware |
| [Installation](Installation) | Downloading, building from source, the Gatekeeper dialog |
| [Getting Started](Getting-Started) | First folder, the five views, ratings |
| [Library](Library) | The sidebar, the catalog, the grid, sorting and filtering, Finder tags, Loupe, Compare and Survey, full screen, moving and renaming, undo, the slideshow |
| [Develop](Develop) | Every editing module, typed values, masks, spot and red-eye removal, sensor dust, touch-up, presets, history |
| [Models](Models) | The models behind the masks: what is bundled, choosing one per mask, adding a converted model from disk, what happens when one is missing |
| [Export](Export) | Formats, HDR gain maps, watermark, naming templates, metadata, batch export, printing, contact sheets, external editors |
| [Photo Merge](Photo-Merge) | HDR brackets, single-row panoramas and experimental HDR panoramas: merging photos into one DNG, how to shoot for each, and what to do when one goes wrong |
| [Keyboard Shortcuts](Keyboard-Shortcuts) | The full list |
| [Architecture](Architecture) | Modules, the render pipeline, performance, tests |
| [Security and Privacy](Security-and-Privacy) | Sandbox, isolated decoder, location in exports, what is written where |
| [Accessibility](Accessibility) | VoiceOver, Reduce Motion, Increase Contrast |
| [Limitations](Limitations) | What it does not do, honestly |
| [Troubleshooting](Troubleshooting) | The problems people hit first |
