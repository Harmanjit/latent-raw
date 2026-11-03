# Latent

**A catalog manager and non-destructive RAW editor for macOS, built for Apple Silicon.**

Latent opens a folder of raw files, keeps a catalog inside that folder, and edits every image on the GPU without touching the original. It is in the same family as Lightroom, darktable and RawTherapee, but it targets one platform only and uses everything that platform has: unified memory, Metal compute, and on-device machine learning.

- **Status:** version 0.9, a beta for review. **HDR Panorama** works but is marked **experimental**, because no real bracketed sweep has ever been merged with it, and panoramas are single-row only. Since the first beta build Latent has gained a great deal: collections and keywords, colour labels, virtual copies, JPEG and HEIC support, profiles, colour grading, Upright, masks built from several parts, Remove, Lens Blur, DNG export and soft proofing among them; [What's New](Whats-New) lists it all. Expect rough edges, and read [Limitations](Limitations) before relying on it. Please report bugs as [issues on GitHub](https://github.com/Harmanjit/latent-raw/issues); see [Report an issue or get help](FAQ#report-an-issue-or-get-help).
- **Licence:** GPLv3. The code, data and models Latent carries from other projects, and their licences, are on [Licences](Licences).
- **Platform:** macOS 15 or newer on Apple Silicon. Verified on M1 Pro and M4.

These pages are also in the app: **Help > Latent Help** (⌘?) shows them with search, and nothing is fetched from the network.

**New to Latent?** Start with [Getting Started](Getting-Started), then try a tutorial. **Coming from Lightroom?** Read [Coming from Lightroom](Coming-from-Lightroom).

## Help and learning

| | |
|---|---|
| [Getting Started](Getting-Started) | First launch, choosing a folder, the Library → Develop → Export loop, where the help is |
| [What's New](Whats-New) | Everything added since the 0.9.0 beta, by area |
| [Tutorial: Culling and Organising](Tutorial-Culling-and-Organising) | Cull and rate a shoot; organise it with collections, smart collections and keywords |
| [Tutorial: Editing](Tutorial-Editing) | A basic edit, masking a sky, removing a distraction, Lens Blur |
| [Tutorial: Printing and Sharing](Tutorial-Printing-and-Sharing) | Soft proofing and printing or exporting for a lab; exporting for the web with a watermark |
| [Coming from Lightroom](Coming-from-Lightroom) | How Lightroom's ideas map onto Latent, the keys that match, and what Latent doesn't have |
| [Glossary](Glossary) | Raw, demosaic, sidecar, virtual copy, rendering intent, depth map and more, in plain terms |
| [FAQ](FAQ) | Short answers to common questions, and how to report an issue |
| [Troubleshooting](Troubleshooting) | The problems people hit first |

## Reference

| | |
|---|---|
| [Motivation](Motivation) | Why another RAW editor, and why only for this hardware |
| [Installation](Installation) | Downloading, building from source, the Gatekeeper dialog |
| [Library](Library) | The sidebar, the catalog, folder watching and Auto Import, the grid, sorting and filtering, colour labels, titles and copyright, Finder tags, virtual copies, Loupe, Compare and Survey, full screen, moving and renaming, undo, the slideshow |
| [Collections and Keywords](Collections-and-Keywords) | Collections, smart collections, collection sets and hierarchical keywords |
| [Develop](Develop) | Every editing module, profiles, typed values, masks, spot removal and Remove, red-eye, sensor dust, touch-up, Lens Blur, Upright, soft proofing, presets, history |
| [Masking](Masking) | Local adjustments: making masks, components, Feather and Edge, the mask sliders |
| [Models](Models) | The models behind the masks: what is bundled, choosing one per mask, adding a converted model from disk, what happens when one is missing |
| [Converting Models](Converting-Models) | Fetching a model from its source, converting it to Core ML and checking it, so Add Model… will take it |
| [Export](Export) | Formats, colour spaces, sizing, output sharpening, DNG, HDR gain maps, watermark, naming templates, metadata, batch export, printing, contact sheets, external editors |
| [Photo Merge](Photo-Merge) | HDR brackets, single-row panoramas and experimental HDR panoramas: merging photos into one DNG, how to shoot for each, and what to do when one goes wrong |
| [Keyboard Shortcuts](Keyboard-Shortcuts) | The full list |
| [Architecture](Architecture) | Modules, the render pipeline, performance, tests |
| [Security and Privacy](Security-and-Privacy) | Sandbox, isolated decoder, location in exports, what is written where |
| [Accessibility](Accessibility) | VoiceOver, Reduce Motion, Increase Contrast |
| [Limitations](Limitations) | What it does not do, honestly |
| [Licences](Licences) | The licences of the code, data and models Latent carries |
