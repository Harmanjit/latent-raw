#!/bin/bash
# Builds rawhead.app from the SwiftPM release binary.
#
# SwiftPM produces a bare executable plus resource bundles; macOS wants an
# .app folder with an Info.plist so it can sit in the Dock, remember its
# windows, and be code-signed. This script assembles that:
#
#   build/rawhead.app/
#     Contents/Info.plist
#     Contents/MacOS/rawhead            <- the release binary
#     Contents/Resources/*.bundle       <- shaders, Lensfun DB, Core ML models
#
# Ad-hoc signed so Gatekeeper on this Mac runs it; a notarized build for
# other Macs needs a Developer ID (DESIGN.md, non-goals: no App Store).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
echo "Building release…"
swift build -c release --product rawhead-app 2>&1 | tail -1

APP="build/rawhead.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/rawhead-app "$APP/Contents/MacOS/rawhead"
# Resource bundles: every *.bundle SwiftPM produced next to the binary.
for b in .build/release/*.bundle; do
  [ -d "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>               <string>rawhead</string>
  <key>CFBundleDisplayName</key>        <string>rawhead</string>
  <key>CFBundleIdentifier</key>         <string>com.rawhead.app</string>
  <key>CFBundleVersion</key>            <string>${VERSION}</string>
  <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
  <key>CFBundleExecutable</key>         <string>rawhead</string>
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

codesign --force --deep --sign - "$APP" 2>/dev/null && echo "Signed (ad hoc)"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"
echo "Run: open $APP     — or drag it to /Applications"
