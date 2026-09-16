# Installation

## Requirements

- macOS 15 (Sequoia) or 26 (Tahoe).
- Apple Silicon. Verified on an M4 MacBook Air and an M1 Pro MacBook Pro; any M-series chip should work. The M1 Pro, with its larger GPU, is if anything faster in the editor.

## Download

Version 0.9.0 is a beta, published for review. The [Releases page](https://github.com/Harmanjit/latent-raw/releases) offers it as `Latent-0.9.0.zip`, for macOS 15 or newer on Apple Silicon.

1. Download `Latent-0.9.0.zip` and unzip it.
2. Drag `Latent.app` to Applications.
3. Open it. The first time, Gatekeeper stops it, because the app is not notarised; follow [The Gatekeeper dialog](#the-gatekeeper-dialog).

## Build from source

Building needs, as well as the requirements above:

- **Xcode 16 or newer**, the full application from the App Store, not just the Command Line Tools. The build needs `xcodebuild`, and Xcode must be the active developer directory:

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
scripts/make_app.sh 0.9.0        # release build, assembles build/Latent.app, signs it
open build/Latent.app
```

Drag `build/Latent.app` to Applications if you want it in the Dock.

`scripts/build_libraw.sh` clones LibRaw at a pinned tag, checks that the tag still points at the vetted commit, and refuses to build otherwise. The framework it produces is not committed, so this step runs once per clone.

`scripts/make_app.sh` builds release, precompiles the shaders when the Metal toolchain is installed, strips local symbols from the binaries (roughly halving them), copies these wiki pages into the app for **Help > Latent Help**, and signs the bundle.

## The Gatekeeper dialog

The app is signed ad hoc, not by an Apple Developer ID, and isn't notarised, so Gatekeeper stops it the first time it is opened from a download or a copy on another Mac. The Mac that built it opens it straight away.

1. Try to open the app once and dismiss the dialog.
2. Open **System Settings > Privacy & Security**, scroll to the message about Latent, and click **Open Anyway**.

Since macOS 15, Control-click > Open no longer skips this step. Alternatively, remove the quarantine attribute:

```bash
xattr -dr com.apple.quarantine /Applications/Latent.app
```

This is a one-time step per Mac. The app is sandboxed and hardened regardless of the dialog; see [Security and Privacy](Security-and-Privacy).

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
