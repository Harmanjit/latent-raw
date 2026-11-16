# Installation

## Requirements

- macOS 15 (Sequoia) or newer. Verified on macOS 15, 26 (Tahoe) and 27.
- Apple Silicon. Verified on an M4 MacBook Air and an M1 Pro MacBook Pro; any M-series chip should work. The M1 Pro, with its larger GPU, is if anything faster in the editor.

## Download

The [Releases page](https://github.com/Harmanjit/latent-raw/releases) offers each version as `Latent-<version>.zip` under **Assets**, for macOS 15 or newer on Apple Silicon. Version 1.0.0 is the first public release; the release notes give the zip's SHA-256 if you want to check your download with `shasum -a 256 Latent-<version>.zip`.

1. Download `Latent-<version>.zip` from under **Assets** and unzip it (double-click it in Finder).
2. Drag `Latent.app` to Applications.
3. Open it. The first time, Gatekeeper stops it, because the app is not notarised; follow [The Gatekeeper dialog](#the-gatekeeper-dialog).

## Build from source

Building needs, as well as the requirements above:

- **Xcode 16.3 (Swift 6.1) or newer**, the full application from the App Store, not just the Command Line Tools. The build needs `xcodebuild`, and Xcode must be the active developer directory:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Without that step the build fails with errors about missing tools even though Xcode is installed. Run it once after installing Xcode.

- Optionally, Xcode's Metal toolchain, so `make_app.sh` can precompile the shaders. Xcode 26 ships it as a separate download (`xcodebuild -downloadComponent MetalToolchain`). Without it the app compiles its shaders the first time it launches, which takes about half a second longer.

- About 1 GB of disk for the build.

Building takes about ten minutes the first time.

```bash
git clone https://github.com/Harmanjit/latent-raw.git
cd latent-raw
brew install autoconf automake libtool pkg-config
scripts/build_libraw.sh          # builds the LibRaw framework from a pinned commit, once
scripts/make_app.sh 1.0.0        # release build, assembles build/Latent.app, signs it
open build/Latent.app
```

Drag `build/Latent.app` to Applications if you want it in the Dock.

`scripts/build_libraw.sh` clones LibRaw at a pinned tag, checks that the tag still points at the vetted commit, and refuses to build otherwise. The framework it produces is not committed, so this step runs once per clone.

`scripts/make_app.sh` builds release, precompiles the shaders when the Metal toolchain is installed, strips local symbols from the binaries (roughly halving them), copies these wiki pages into the app for **Help > Latent Help**, and signs the bundle.

## The Gatekeeper dialog

The app is signed ad hoc, not by an Apple Developer ID, and isn't notarised, so Gatekeeper stops it the first time it is opened from a download or a copy on another Mac. The Mac that built it opens it straight away. On macOS 15, 26 and later:

1. Double-click Latent in Applications. macOS says it can't open it, or can't check it for malicious software. Click **Done** (not Move to Trash).
2. Open **System Settings › Privacy & Security** and scroll down to **Security**. A line says Latent was blocked; click **Open Anyway** beside it. The line shows for about an hour after the blocked launch, so if it isn't there, try to open Latent again first.
3. Confirm with your password or Touch ID, then click **Open Anyway** in the dialog that follows. Latent opens.

Since macOS 15, Control-click (or right-click) › Open no longer skips this step: only **Open Anyway** in Privacy & Security does. Alternatively, if you are comfortable in Terminal, remove the quarantine attribute that marks the app as downloaded:

```bash
xattr -dr com.apple.quarantine /Applications/Latent.app
```

This is a one-time step per Mac and per downloaded version: a newer zip is a new download, and macOS asks once more for it. The app is sandboxed and hardened regardless of the dialog; see [Security and Privacy](Security-and-Privacy).

## Upgrading from 0.9

Quit Latent, unzip the new version and drag it to Applications, replacing the old one. Your settings, presets, favourite folders and the other folders you gave Latent access to carry over, because they live in the app's container, which keeps the same name.

The first time 1.0.0 opens a folder catalogued by 0.9, it updates the catalog in `_latent/` to the new format. This is one way: going back to 0.9 with that folder afterwards isn't supported. Before changing anything Latent saves a copy of the old catalog in that folder's `_latent/backups/` (see [Backups](Library#the-catalog)). Thumbnails are made again once, in the background, in a new format. Edits, ratings, keywords and sidecars are untouched.

## Development builds

```bash
swift run latent-app                       # unsigned, unsandboxed, debug
swift run latent-app /path/to/folder       # open a folder straight away
scripts/fetch_test_assets.sh               # downloads the public-domain raw the golden tests render
scripts/fetch_test_assets.sh --merge       # also the Photo Merge brackets (about 390 MB)
swift test                                 # tests needing the author's own samples skip
```

Development builds are not sandboxed, which is why they accept a path on the command line and the bundle does not. Defaults overrides such as `-AppleLanguages (en)` may come before the path. Some features are much slower in debug builds; judge speed on the bundle.

Debug builds also honour switches that release builds ignore. `LATENT_SNAPSHOT_DIR=.build/snapshots swift run latent-app` runs a harness that saves a picture of the window in each main view and quits; the other `LATENT_SNAPSHOT_*` variables are listed in `Sources/latent-app/SnapshotHarness.swift`. `LATENT_RAW_INPROCESS=1` makes a debug-built bundle decode in its own process rather than in the isolated service; `swift run` does that anyway, and every bundle `scripts/make_app.sh` makes is a release build, which ignores the switch.
