# Installation

## Requirements

- macOS 15 (Sequoia) or 26 (Tahoe).
- Apple Silicon. Developed and tested on an M4; the project targets M3 or newer. M1 and M2 should work and are untested.
- Xcode 16 or newer to build from source. About 1 GB of disk for the build.

There is no prebuilt download yet. Building takes about ten minutes the first time.

## Build from source

```bash
git clone https://github.com/Harmanjit/latent-raw.git
cd latent-raw
brew install autoconf automake libtool pkg-config
scripts/build_libraw.sh          # builds the LibRaw framework from a pinned commit, once
scripts/make_app.sh 0.7.0        # release build, assembles build/Latent.app, signs it
open build/Latent.app
```

Drag `build/Latent.app` to Applications if you want it in the Dock.

`scripts/build_libraw.sh` clones LibRaw at a pinned tag, checks that the tag still points at the vetted commit, and refuses to build otherwise. The framework it produces is not committed, so this step runs once per clone.

## The Gatekeeper dialog

The app is signed ad hoc, not by an Apple Developer ID, so on any Mac other than the one that built it the first launch shows "cannot verify the developer". Either right-click the app and choose Open once, or run:

```bash
xattr -dr com.apple.quarantine /Applications/Latent.app
```

This is a one-time step per Mac. The app is sandboxed and hardened regardless of the dialog; see [Security and Privacy](Security-and-Privacy).

## Development builds

```bash
swift run latent-app                       # unsigned, unsandboxed, debug
swift run latent-app /path/to/folder       # open a folder straight away
swift test                                 # 125 tests; GPU tests skip without a sample raw
```

Development builds are not sandboxed, which is why they accept a path on the command line and the bundle does not. Some features are much slower in debug builds; judge speed on the bundle.
