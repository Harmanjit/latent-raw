# Troubleshooting

**macOS says Latent can't be opened, or can't be checked for malware.**
Try to open it once, then click **Open Anyway** in System Settings > Privacy & Security. Since macOS 15, Control-click > Open no longer skips this step. Alternatively, run `xattr -dr com.apple.quarantine /path/to/Latent.app`. The app is not notarised; see [Installation](Installation).

**I changed the code and the app looks the same.**
`build/Latent.app` is a snapshot. Run `scripts/make_app.sh` again after any change. `swift run latent-app` always reflects the current source but is slower and unsandboxed.

**The bundle won't open the folder I pass on the command line.**
Sandboxed apps cannot read arbitrary paths. Use ⇧⌘O, or a `swift run` build for development.

**"Latent doesn't have permission to open" a folder.**
The sandbox lets the app into folders you chose with Open Folder and folders inside a sidebar favourite, nothing else. Choose Open Folder… and select the folder, or add a folder that contains it to the sidebar. See [Library](Library#the-sidebar).

**A favourite shows as not connected, or a folder "is on a disk or network share that isn't connected".**
Mount the disk or connect to the share, then click the folder again. Latent doesn't mount volumes by itself.

**A folder "is on a read-only disk".**
The catalog lives inside the folder, so Latent can't open a folder it can't write to. Copy the files to a writable folder first, or unlock the card.

**A folder's catalog "was damaged and has been rebuilt".**
SQLite couldn't read `catalog.sqlite`. Latent kept the damaged file as `catalog.damaged-<date>.sqlite` in the folder's `_latent/` directory and rebuilt the catalog from the sidecars, so ratings, keywords and edits are back. Answer the subfolder question again. The damaged file can be deleted once you are satisfied.

**A warning in the status bar.**
A catalog write or read failed, or a folder couldn't be opened, and the app is telling you instead of dropping it. The message names the operation; the usual causes are a read-only volume, a full disk, or a folder that moved. Click the ✕ beside it to dismiss.

**"Raw decoder connection lost."**
A file crashed the isolated decoder. The app is unaffected; the file is likely corrupt or unsupported. If a valid file does this reproducibly, please open an issue with the camera model.

**A folder opens with no thumbnails.**
Thumbnails come from the cameras' embedded previews; a few cameras write none, and those images get a rendered thumbnail instead, which takes longer. The status bar reports thumbnails failed if a file could not be read.

**Rename, Move to Folder or Copy to Folder is greyed out.**
They work in the Library grid, not in Loupe, Compare, Survey or Develop, and not while an export, a print, a contact sheet, a Photo Merge or another move or copy is running. Rename needs exactly one selected image.

**A moved or copied image came out as "DSC_0107 2.NEF".**
The destination already had a file of that name, or a sidecar a file had left behind, and Latent never writes over one. The name the image had is kept in its sidecar.

**A hidden `.latent-transfer-…` file is in a folder.**
Latent crashed or was force-quit during a copy into that folder, or a move into it from another disk. The original is where it was; the hidden file is an incomplete copy and can be deleted.

**Undoing a copy says the copy "was left where it is".**
The copy had changed or been replaced since Latent made it, so Latent didn't put it in the Trash. Remove it yourself if you don't want it.

**A Finder tag I just set doesn't show.**
Tags are read when a folder opens. Open the folder again from the sidebar.

**A trackpad swipe doesn't go to the next image.**
Swipes step only at fit, in Loupe and Develop, with no crop, spot or mask tool on. Zoomed in, a swipe pans instead; a mouse wheel never steps. The arrow keys always do, unless Settings › Library › Arrow keys pan a zoomed-in image is on and the image is zoomed in.

**Holding the mouse button doesn't show the magnifier.**
It works on a fitted image in Loupe, Compare or Develop with no tool on. Zoomed in, a drag pans instead.

**Show Loupe on Second Display is greyed out.**
It needs a second display connected. It closes by itself when that display is unplugged.

**The slideshow's first slide takes a moment.**
Slides are rendered from the raw with their edits at the size of the screen, and the first one has nothing ready ahead of it. Later slides are prepared while the one before is showing.

**Edit in External Editor says the application "can't be found".**
The application was moved or deleted after you chose it. The TIFF was still written; the message says where. Choose the application again in Settings › External Editor.

**AI features are slow the first time.**
Models compile on first use, once, into the app container. Subsequent runs are fast. If macOS ran short of memory, a model is loaded again from that compiled copy, which takes well under a second, and AI noise reduction may run again.

**Quitting takes a few seconds.**
Latent saves the last edit and waits for catalog writes to reach the sidecars before it quits, for at most 10 seconds, or up to a minute while a move or copy finishes the image under way. During an export (a batch or Export open image…) it first asks whether to finish the image being written; that can take up to a minute for a large image with AI noise reduction.

**The Help window is empty or out of date.**
Help shows the pages copied into the app by `scripts/make_app.sh`; rebuild the app after changing `docs/wiki`. A `swift run` build reads `docs/wiki` directly.

**Everything went back to defaults after updating.**
Settings moved into the app container when the sandbox was introduced. Set them again once in ⌘,.

**Build fails with a linker error after pulling.**
Stale objects in `.build/release`. Run `rm -rf .build/release` and build again.

**Build fails saying `xcodebuild` is missing, although Xcode is installed.**
The active developer directory is pointing at the Command Line Tools. Fix it once:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

**`make_app.sh` says the Metal toolchain is not installed.**
Harmless: the shaders compile the first time the app launches instead, which adds about half a second to that launch. To precompile them on Xcode 26, install the toolchain with `xcodebuild -downloadComponent MetalToolchain` and run the script again.

**Build fails at `scripts/build_libraw.sh`.**
Install the autotools with `brew install autoconf automake libtool pkg-config`. If it says the tag resolves to an unexpected commit, LibRaw's tag has moved; that is deliberate protection, and the pin in the script needs a human to review the new commit.
