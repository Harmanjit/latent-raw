#!/bin/bash
# Builds latent.app from the SwiftPM release binary.
#
# SwiftPM produces a bare executable plus resource bundles; macOS wants an
# .app folder with an Info.plist so it can sit in the Dock, remember its
# windows, and be code-signed. This script assembles that:
#
#   build/Latent.app/
#     Contents/Info.plist
#     Contents/MacOS/Latent            <- the release binary
#     Contents/Resources/*.bundle       <- shaders, Lensfun DB, Core ML models
#
# Ad-hoc signed so Gatekeeper on this Mac runs it; a notarized build for
# other Macs needs a Developer ID (DESIGN.md, non-goals: no App Store).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
# --dev: skip the sandbox entitlements so the bundle accepts a folder
# argument (open build/Latent.app --args <folder>); for testing only.
DEV=0
for arg in "$@"; do [ "$arg" = "--dev" ] && DEV=1; done
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
# shows "cannot verify the developer" until the user right-clicks > Open
# once (or removes the quarantine attribute). See README.
SCRIPTS="$(dirname "$0")"
if [ "$DEV" = "1" ]; then
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
