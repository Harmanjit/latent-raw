# Troubleshooting

**"Latent cannot be opened because the developer cannot be verified."**
Right-click the app and choose Open once, or `xattr -dr com.apple.quarantine /path/to/Latent.app`. The app is not notarised; see [Installation](Installation).

**I changed the code and the app looks the same.**
`build/Latent.app` is a snapshot. Run `scripts/make_app.sh` again after any change. `swift run latent-app` always reflects the current source but is slower and unsandboxed.

**The bundle won't open the folder I pass on the command line.**
Sandboxed apps cannot read arbitrary paths. Use ⌘⇧O, or a `swift run` build for development.

**A red line in the status bar.**
A catalog write or read failed and the app is telling you instead of dropping it. The message names the operation; the usual causes are a read-only volume, a full disk, or a folder that moved. Click ✕ to dismiss.

**"Raw decoder connection lost."**
A file crashed the isolated decoder. The app is unaffected; the file is likely corrupt or unsupported. If a valid file does this reproducibly, please open an issue with the camera model.

**A folder opens with no thumbnails.**
Thumbnails come from the cameras' embedded previews; a few cameras write none, and those images get a rendered thumbnail instead, which takes longer. The status bar reports thumbnails failed if a file could not be read.

**AI features are slow the first time.**
Models compile on first use, once, into the app container. Subsequent runs are fast.

**Everything went back to defaults after updating.**
Preferences moved into the app container when the sandbox was introduced. Set them again once in ⌘,.

**Build fails with a linker error after pulling.**
Stale objects in `.build/release`. Run `rm -rf .build/release` and build again.

**Build fails at `scripts/build_libraw.sh`.**
Install the autotools with `brew install autoconf automake libtool pkg-config`. If it says the tag resolves to an unexpected commit, LibRaw's tag has moved; that is deliberate protection, and the pin in the script needs a human to review the new commit.
