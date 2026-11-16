#!/bin/bash
# Checks the layout of a bundle built by scripts/make_app.sh.
#
#   scripts/check_app_bundle.sh [build/Latent.app] [--version 1.0.0]
#
# With --version, both Info.plists must carry exactly that version (the
# release script passes the one it built). Without it, the version of a
# tag pointing exactly at HEAD is expected when there is one; otherwise the
# two plists need only agree with each other.
#
# CI runs it after make_app.sh, so a change that breaks packaging (a binary
# or resource bundle not found, the XPC service missing, a signature that
# does not verify, the licence texts left out) fails there rather than at
# release time. It prints a line per check and exits non-zero if any fails.
set -uo pipefail
cd "$(dirname "$0")/.."
APP=""
EXPECTED=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version) EXPECTED="${2:-}"; shift 2 || { echo "check_app_bundle.sh: --version needs a value" >&2; exit 2; } ;;
    --version=*) EXPECTED="${1#--version=}"; shift ;;
    -*) echo "check_app_bundle.sh: unknown option $1" >&2; exit 2 ;;
    *) APP="$1"; shift ;;
  esac
done
APP="${APP:-build/Latent.app}"
if [ -z "$EXPECTED" ]; then
  TAG=$(git describe --tags --exact-match 2>/dev/null || true)
  EXPECTED="${TAG#v}"
fi
RES="$APP/Contents/Resources"
XPC="$APP/Contents/XPCServices/LatentRawDecoder.xpc"
failed=0

check() {   # check <label> <command...>
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "  ok    $label"; else echo "  FAIL  $label"; failed=1; fi
}

check "the app binary" test -x "$APP/Contents/MacOS/Latent"
check "the raw decoder service" test -x "$XPC/Contents/MacOS/LatentRawDecoder"
check "the shader sources" test -n "$(find "$RES/latent_PixelEngine.bundle" -name Common.h -print -quit 2>/dev/null)"
check "the Lensfun database" test -n "$(find "$RES" -path '*lensfun-db*' -name '*.xml' -print -quit 2>/dev/null)"
check "the bundled models" test -n "$(find "$RES" -name '*.model.json' -print -quit 2>/dev/null)"
check "the Help pages" test -f "$RES/Help/Home.md"
check "the Licences Help page" test -f "$RES/Help/Licences.md"
check "the icon" test -f "$RES/AppIcon.icns"
check "Latent's own licence" cmp -s LICENSE "$RES/LICENSE"
# Every licence text in the repository, and the ones the notices require
# by name, so an empty or renamed licences/ folder cannot pass.
for text in licences/*.txt; do
  check "Licences/$(basename "$text")" cmp -s "$text" "$RES/Licences/$(basename "$text")"
done
check "LibRaw's LGPL text" grep -q "LESSER GENERAL PUBLIC LICENSE" "$RES/Licences/LibRaw-LGPL-2.1.txt"
check "GRDB's MIT text" grep -q "Gwendal Rou" "$RES/Licences/GRDB-MIT.txt"
check "the Apache text for SAM 2.1" grep -q "Apache License" "$RES/Licences/Apache-2.0.txt"
check "NVIDIA's licence for SegFormer" grep -q "NVIDIA Source Code License" "$RES/Licences/SegFormer-NVIDIA.txt"
check "the BSD notice for LibRaw's DCB/FBDD code" grep -q "Jacek Gozdz" "$RES/Licences/LibRaw-DCB-FBDD-BSD.txt"
check "the BSD notice for LibRaw's X3F code" grep -q "Roland Karlsson" "$RES/Licences/LibRaw-X3F-BSD.txt"
check "the Lensfun CC-BY-SA notice" grep -q "Attribution-ShareAlike 3.0" "$RES/Help/Licences.md"
# Open With and Dock drops: raw images and folders are claimed, as a
# Viewer, and AppDelegate handles the request (see make_app.sh).
check "raw images claimed for Open With" bash -c "/usr/libexec/PlistBuddy -c 'Print :CFBundleDocumentTypes:0:LSItemContentTypes' '$APP/Contents/Info.plist' | grep -q public.camera-raw-image"
check "folders claimed for Open With" bash -c "/usr/libexec/PlistBuddy -c 'Print :CFBundleDocumentTypes:0:LSItemContentTypes' '$APP/Contents/Info.plist' | grep -q public.folder"

# Info.plist keys: the version, the system floor, the decoder's identifier
# (the app looks the service up by it), the copyright notice and the Finder
# category.
plist() {   # plist <file> <key>: the value, or nothing
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}
INFO="$APP/Contents/Info.plist"
XINFO="$XPC/Contents/Info.plist"
APP_VERSION=$(plist "$INFO" CFBundleShortVersionString)
if [ -n "$EXPECTED" ]; then
  check "the app's version is $EXPECTED (CFBundleShortVersionString $APP_VERSION)" test "$APP_VERSION" = "$EXPECTED"
  check "the app's CFBundleVersion is $EXPECTED" test "$(plist "$INFO" CFBundleVersion)" = "$EXPECTED"
else
  check "the app has a version ($APP_VERSION)" test -n "$APP_VERSION"
fi
check "the decoder's version matches the app's" test "$(plist "$XINFO" CFBundleShortVersionString)" = "$APP_VERSION"
check "the app's LSMinimumSystemVersion is 15.0" test "$(plist "$INFO" LSMinimumSystemVersion)" = "15.0"
check "the decoder's LSMinimumSystemVersion is 15.0" test "$(plist "$XINFO" LSMinimumSystemVersion)" = "15.0"
check "the app's identifier is com.latent.app" test "$(plist "$INFO" CFBundleIdentifier)" = "com.latent.app"
check "the decoder's identifier is com.latent.app.rawdecoder" test "$(plist "$XINFO" CFBundleIdentifier)" = "com.latent.app.rawdecoder"
check "CFBundleInfoDictionaryVersion 6.0 in both plists" test "$(plist "$INFO" CFBundleInfoDictionaryVersion)/$(plist "$XINFO" CFBundleInfoDictionaryVersion)" = "6.0/6.0"
check "the photography app category" test "$(plist "$INFO" LSApplicationCategoryType)" = "public.app-category.photography"
COPYRIGHT=$(plist "$INFO" NSHumanReadableCopyright)
check "the copyright notice names the year and GPLv3" bash -c '[[ "$1" == "Copyright © 20"* && "$1" == *GPLv3* && "$1" == *"no warranty"* ]]' _ "$COPYRIGHT"
check "the copyright notice points to the Licences page" bash -c '[[ "$1" == *"Help › Latent Help › Licences"* ]]' _ "$COPYRIGHT"

# The bundled models: each manifest is the repository's copy, and each
# package it names hashes to the SHA-256 the manifest records, so a package
# damaged or swapped on the way into the bundle fails here rather than at
# the first mask. --no-features: the hash check needs no coremltools.
MODELS=$(find "$RES" -path '*latent_MLKit.bundle*' -type d -name Models -print -quit 2>/dev/null)
for manifest in Sources/MLKit/Resources/Models/*.model.json; do
  name=$(basename "$manifest")
  check "the bundled $name is the repository's" cmp -s "$manifest" "$MODELS/$name"
  check "the bundled $name's package hashes" python3 scripts/latent_manifest.py --check --no-features "$MODELS/$name"
done

check "the signature verifies" codesign --verify --deep --strict "$APP"

if [ "$failed" != 0 ]; then
  echo "FAILED: $APP is not laid out as make_app.sh should leave it" >&2
  exit 1
fi
echo "$APP is laid out as expected"
