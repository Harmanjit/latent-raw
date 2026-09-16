#!/bin/bash
# Builds Latent.app from the SwiftPM release binaries.
#
#   scripts/make_app.sh [version] [--dev]     # version defaults to 0.9.0
#
# SwiftPM produces a bare executable plus resource bundles; macOS wants an
# .app folder with an Info.plist so it can sit in the Dock, remember its
# windows, and be code-signed. This script assembles that:
#
#   build/Latent.app/
#     Contents/Info.plist
#     Contents/MacOS/Latent            <- the release binary
#     Contents/Resources/*.bundle       <- shaders, Lensfun DB, Core ML models
#     Contents/Resources/Help/*.md      <- docs/wiki, shown by Help > Latent Help
#     Contents/Resources/AppIcon.icns   <- Assets/AppIcon.icns, made from Assets/Latent.pdf
#                                        by scripts/make_icon.swift
#     Contents/XPCServices/LatentRawDecoder.xpc  <- the sandboxed raw decoder
#                                        (scripts/LatentRawDecoder.entitlements)
#
# Signed ad hoc and not notarised, as there is no Apple developer account;
# the signing step at the end says what that means on other Macs.
set -euo pipefail
cd "$(dirname "$0")/.."

# The version goes into both Info.plists and the Software tag of merged
# DNGs, so arguments are told apart by shape, not position (--dev may come
# first), and anything unrecognised stops the build rather than landing
# in a plist.
# --dev: skip the sandbox entitlements so the bundle accepts a folder
# argument (open build/Latent.app --args <folder>); for testing only.
VERSION=""
DEV=0
for arg in "$@"; do
  case "$arg" in
    --dev) DEV=1 ;;
    -*) echo "make_app.sh: unknown option $arg (usage: scripts/make_app.sh [version] [--dev])" >&2; exit 2 ;;
    *)
      if [ -n "$VERSION" ]; then
        echo "make_app.sh: more than one version given ($VERSION, $arg)" >&2; exit 2
      fi
      VERSION="$arg" ;;
  esac
done
VERSION="${VERSION:-0.9.0}"
echo "Building release…"
swift build -c release --product latent-app 2>&1 | tail -1
swift build -c release --product latent-rawdecoder 2>&1 | tail -1

APP="build/Latent.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/latent-app "$APP/Contents/MacOS/Latent"
if [ "$DEV" = "1" ]; then
  # Dev builds carry the CLI inside the bundle, so `latent-cli render`
  # exercises the XPC decoder exactly as the app does.
  swift build -c release --product latent-cli 2>&1 | tail -1
  cp .build/release/latent-cli "$APP/Contents/MacOS/latent-cli"
fi
# Resource bundles: this package's own (latent_*) plus dependencies'.
# Stale bundles from an earlier package name are skipped.
for b in .build/release/latent_*.bundle .build/release/GRDB_*.bundle; do
  [ -d "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

# Shaders, precompiled into default.metallib when the Metal toolchain is
# installed: GPUContext loads it in milliseconds, where compiling the
# sources costs about 0.4 s the first time a build's shaders are seen.
# Xcode 26 ships the toolchain as a separate component
# (xcodebuild -downloadComponent MetalToolchain) and `xcrun -f metal`
# finds a stub without it, so the test is whether the compiler runs.
# Metal 3.0 and macOS 15 keep the library loadable on Sequoia; fast math
# is the compiler's default, as it is for runtime compilation. The sources
# stay in the bundle, so without a metallib, or with one the system
# refuses, the app compiles them at launch as `swift run` does.
precompile_shaders() {
  local dir="$1" air f
  air=$(mktemp -d)
  for f in "$dir"/*.metal; do
    xcrun metal -c -std=metal3.0 -mmacosx-version-min=15.0 -I "$dir" "$f" \
      -o "$air/$(basename "$f" .metal).air" || { rm -rf "$air"; return 1; }
  done
  xcrun metallib "$air"/*.air -o "$dir/default.metallib" || { rm -rf "$air" "$dir/default.metallib"; return 1; }
  rm -rf "$air"
}
SHADERS="$APP/Contents/Resources/latent_PixelEngine.bundle"
if ! xcrun metal --version >/dev/null 2>&1; then
  echo "Metal toolchain not installed: shaders will compile at first launch (to precompile on Xcode 26: xcodebuild -downloadComponent MetalToolchain)"
elif precompile_shaders "$SHADERS"; then
  echo "Shaders precompiled"
else
  echo "WARNING: precompiling shaders failed (see above); the app will compile them at launch"
fi

# Help pages, read from here by Help > Latent Help. Copied from docs/wiki
# so the wiki stays the one copy in the repository; `swift run` reads them
# from docs/wiki directly. _Sidebar.md orders the pages; README.md is the
# wiki's publishing notes, not a page.
mkdir -p "$APP/Contents/Resources/Help"
cp docs/wiki/*.md "$APP/Contents/Resources/Help/"
rm -f "$APP/Contents/Resources/Help/README.md"

# The app icon, used by Finder, the Dock, the About window and alerts.
# It is committed ready-made, so building needs no drawing step; after
# changing Assets/Latent.pdf, run `swift scripts/make_icon.swift`.
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# The raw decoder XPC service: its own bundle, its own (tighter) sandbox.
XPC="$APP/Contents/XPCServices/LatentRawDecoder.xpc"
mkdir -p "$XPC/Contents/MacOS"
cp .build/release/latent-rawdecoder "$XPC/Contents/MacOS/LatentRawDecoder"
cat > "$XPC/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>               <string>LatentRawDecoder</string>
  <key>CFBundleIdentifier</key>         <string>com.latent.app.rawdecoder</string>
  <key>CFBundleExecutable</key>         <string>LatentRawDecoder</string>
  <key>CFBundlePackageType</key>        <string>XPC!</string>
  <key>CFBundleVersion</key>            <string>${VERSION}</string>
  <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>     <string>15.0</string>
  <key>XPCService</key>
  <dict>
    <key>ServiceType</key>              <string>Application</string>
  </dict>
</dict>
</plist>
PLIST

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>               <string>Latent</string>
  <key>CFBundleDisplayName</key>        <string>Latent</string>
  <key>CFBundleIdentifier</key>         <string>com.latent.app</string>
  <key>CFBundleVersion</key>            <string>${VERSION}</string>
  <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
  <key>CFBundleExecutable</key>         <string>Latent</string>
  <key>CFBundleIconFile</key>           <string>AppIcon</string>
  <key>CFBundlePackageType</key>        <string>APPL</string>
  <key>LSMinimumSystemVersion</key>     <string>15.0</string>
  <key>NSHighResolutionCapable</key>    <true/>
  <key>NSHumanReadableCopyright</key>   <string>GPLv3</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key> <string>Raw image</string>
      <key>CFBundleTypeRole</key> <string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array><string>public.camera-raw-image</string><string>public.folder</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Ad-hoc signature carrying the App Sandbox entitlements and the hardened
# runtime. No developer account is involved: the sandbox and the runtime
# hardening are enforced from the signature on this machine regardless.
# What ad-hoc cannot give is notarisation, so on another Mac Gatekeeper
# stops the first launch until the user clicks Open Anyway in System
# Settings > Privacy & Security (Control-click > Open no longer works
# since macOS 15), or removes the quarantine attribute. See README.
SCRIPTS="scripts"   # relative to the repository root, the working directory
# Local symbols serve only the debugger; stripping them roughly halves the
# binaries, and crash reports still name the global symbols. It has to
# happen before signing, which seals each binary as it is.
strip -x "$APP/Contents/MacOS/Latent" "$XPC/Contents/MacOS/LatentRawDecoder"
if [ "$DEV" = "1" ]; then
  strip -x "$APP/Contents/MacOS/latent-cli"
  codesign --force --options runtime --sign - "$APP/Contents/MacOS/latent-cli"
  codesign --force --options runtime --sign - "$XPC"
  codesign --force --options runtime --sign - "$APP" && echo "Signed (ad hoc, DEV: no sandbox)"
else
  # The service first, with its own entitlements; then the app without
  # --deep, so the app's entitlements never leak into the service.
  codesign --force --options runtime --entitlements "$SCRIPTS/LatentRawDecoder.entitlements" --sign - "$XPC"
  codesign --force --options runtime --entitlements "$SCRIPTS/Latent.entitlements" --sign - "$APP" \
    && echo "Signed (ad hoc, sandboxed, hardened runtime)"
  codesign -d --entitlements - "$APP" 2>/dev/null | grep -q app-sandbox && echo "App sandbox entitlement present"
  codesign -d --entitlements - "$XPC" 2>/dev/null | grep -q app-sandbox && echo "Decoder sandbox entitlement present"
fi
codesign --verify --deep --strict "$APP" && echo "Signature verifies"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"
echo "Run: open $APP     — or drag it to /Applications"
