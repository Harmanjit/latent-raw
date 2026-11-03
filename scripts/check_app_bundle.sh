#!/bin/bash
# Checks the layout of a bundle built by scripts/make_app.sh.
#
#   scripts/check_app_bundle.sh [build/Latent.app]
#
# CI runs it after make_app.sh, so a change that breaks packaging (a binary
# or resource bundle not found, the XPC service missing, a signature that
# does not verify, the licence texts left out) fails there rather than at
# release time. It prints a line per check and exits non-zero if any fails.
set -uo pipefail
cd "$(dirname "$0")/.."
APP="${1:-build/Latent.app}"
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
# Latent handles no open-documents event, so it must not claim document
# types Finder would then offer it (see make_app.sh).
check "no document types claimed" bash -c "! /usr/libexec/PlistBuddy -c 'Print :CFBundleDocumentTypes' '$APP/Contents/Info.plist'"
check "the signature verifies" codesign --verify --deep --strict "$APP"

if [ "$failed" != 0 ]; then
  echo "FAILED: $APP is not laid out as make_app.sh should leave it" >&2
  exit 1
fi
echo "$APP is laid out as expected"
