# Latent

**A catalog manager and non-destructive RAW editor for macOS, built for Apple Silicon.**

Latent opens a folder of raw files, keeps a catalog inside that folder, and edits every image on the GPU without touching the original. It is in the same family as Lightroom, darktable and RawTherapee, but it targets one platform only and uses everything that platform has: unified memory, Metal compute, and on-device machine learning.

- **Status:** beta. Every planned feature except DNG export is implemented and tested; expect rough edges, and read [Limitations](Limitations) before relying on it.
- **Licence:** GPLv3.
- **Platform:** macOS 15 or newer on Apple Silicon. Verified on M1 Pro and M4.

These pages are also in the app: **Help > Latent Help** (⌘?) shows them with search, and nothing is fetched from the network.

## Pages

| | |
|---|---|
| [Motivation](Motivation) | Why another RAW editor, and why only for this hardware |
| [Installation](Installation) | Building from source, the Gatekeeper dialog |
| [Getting Started](Getting-Started) | First folder, the five views, ratings |
| [Library](Library) | The sidebar, the catalog, the grid, sorting and filtering, Finder tags, Loupe, Compare and Survey, full screen, moving and renaming, undo, the slideshow |
| [Develop](Develop) | Every editing module, typed values, masks, spot and red-eye removal, presets, history |
| [Export](Export) | Formats, HDR gain maps, watermark, naming templates, metadata, batch export, printing, contact sheets, external editors |
| [Photo Merge](Photo-Merge) | HDR: merging a bracket into one DNG, and how to shoot one |
| [Keyboard Shortcuts](Keyboard-Shortcuts) | The full list |
| [Architecture](Architecture) | Modules, the render pipeline, performance, tests |
| [Security and Privacy](Security-and-Privacy) | Sandbox, isolated decoder, location in exports, what is written where |
| [Accessibility](Accessibility) | VoiceOver, Reduce Motion, Increase Contrast |
| [Limitations](Limitations) | What it does not do, honestly |
| [Troubleshooting](Troubleshooting) | The problems people hit first |
