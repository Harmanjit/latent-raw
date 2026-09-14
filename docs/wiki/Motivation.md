# Motivation

The established RAW editors are portable. Lightroom runs on Windows and macOS with a shared engine; darktable and RawTherapee run on Linux, Windows and macOS with OpenCL or CPU paths. Portability is a virtue, and it has a cost: the code cannot assume anything about the machine, so it copies image data between CPU and GPU memory, schedules its own thread pools against the operating system's, and treats the GPU as an optional accelerator.

Apple Silicon is different in a way these editors cannot exploit without becoming different programs. The CPU, GPU and Neural Engine share one pool of memory. A 24-megapixel sensor plane can be uploaded once and processed in place by every stage. Metal compute kernels launch in microseconds. Core ML runs segmentation and denoising networks on the same chip. Latent is what you get when you design for exactly that machine and nothing else.

## What that buys

| | Latent, M4 MacBook Air |
|---|---|
| Fit-to-window preview re-render after a slider move | 2–4 ms |
| Full-resolution tile at 100% zoom | 4–11 ms |
| Export, 24 MP JPEG, GPU pack and encode | ~130 ms plus ~220 ms decode |
| Segment Anything click-to-select | ~40 ms per click |
| Neural denoise, 24 MP | ~11 s |

Every slider is live at full quality. There is no "draft mode" and no waiting for a final render. The whole pipeline, from sensor data to the screen, runs in one Metal command buffer per frame, and stage results are cached so an exposure change re-runs only the stages after demosaic.

## Design principles

- **Non-destructive, always.** Originals are never modified. Edits are a small JSON document stored beside the image.
- **No master catalog.** Each folder is its own catalog, kept inside the folder in a `_latent/` directory. Move the folder and the catalog moves with it. Delete the directory and the photos are untouched.
- **Sidecars are the truth.** An XMP sidecar per image holds ratings, keywords, the edit, history and snapshots. The database is a cache that can be rebuilt from them.
- **Minimum compute.** Nothing runs on a timer. When you are not interacting, the app draws nothing. Only the visible scope is computed. Thumbnails come from the camera's embedded preview unless the image was edited.
- **Everything on device.** The machine-learning models are bundled and the app has no network access at all. See [Security and Privacy](Security-and-Privacy).

## What it is not

Latent is not trying to replace the cross-platform editors for people who need Windows or Linux, tethering, printing, or a plugin ecosystem. It is a focused tool for one kind of machine, built to be the fastest thing you can run on it.
