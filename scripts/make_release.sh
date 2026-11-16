#!/bin/bash
# Builds, checks and zips a release of Latent, and prints its SHA-256.
#
#   scripts/make_release.sh 1.0.0      # or no argument: the tag on HEAD (v1.0.0 -> 1.0.0)
#
# It runs scripts/make_app.sh with the version, scripts/check_app_bundle.sh
# against that version, zips build/Latent.app with ditto (which keeps the
# bundle's signature, extended attributes and symbolic links, as Finder's
# Compress does and plain zip does not), unpacks the zip again to check the
# signature survived, and prints the zip's SHA-256 for the release notes.
#
# It publishes nothing and creates no tag: uploading build/Latent-<version>.zip
# to a GitHub Release, and tagging, are done by hand. See CHANGELOG.md and
# the release checklist in docs/wiki/README.md.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=""
for arg in "$@"; do
  case "$arg" in
    -*) echo "make_release.sh: unknown option $arg (usage: scripts/make_release.sh [version])" >&2; exit 2 ;;
    *)
      if [ -n "$VERSION" ]; then
        echo "make_release.sh: more than one version given ($VERSION, $arg)" >&2; exit 2
      fi
      VERSION="$arg" ;;
  esac
done

TAG=$(git describe --tags --exact-match 2>/dev/null || true)
if [ -z "$VERSION" ]; then
  if [ -z "$TAG" ]; then
    echo "make_release.sh: give a version (scripts/make_release.sh 1.0.0) or tag HEAD first" >&2; exit 2
  fi
  VERSION="${TAG#v}"
elif [ -n "$TAG" ] && [ "${TAG#v}" != "$VERSION" ]; then
  echo "make_release.sh: HEAD is tagged $TAG but the version given is $VERSION" >&2; exit 2
fi

# A release is built from committed code, so the zip matches a commit.
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "make_release.sh: the working tree has uncommitted changes; commit or discard them first" >&2
  git status --short --untracked-files=no >&2
  exit 1
fi

echo "== Latent $VERSION from $(git rev-parse --short HEAD)${TAG:+ ($TAG)}"
scripts/make_app.sh "$VERSION"

echo "== Checking the bundle"
scripts/check_app_bundle.sh build/Latent.app --version "$VERSION"

ZIP="build/Latent-$VERSION.zip"
echo "== Zipping $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent build/Latent.app "$ZIP"

# Unpack the zip as a downloader would and check the copy's signature, so a
# zip that lost part of the bundle never reaches the Releases page.
UNPACK=$(mktemp -d)
trap 'rm -rf "$UNPACK"' EXIT
ditto -x -k "$ZIP" "$UNPACK"
codesign --verify --deep --strict "$UNPACK/Latent.app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$UNPACK/Latent.app/Contents/Info.plist")" = "$VERSION"
echo "The unpacked copy's signature verifies"

SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "$SHA  $(basename "$ZIP")" > "$ZIP.sha256"
echo
echo "Built $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "SHA-256: $SHA"
echo "(also written to $ZIP.sha256)"
echo
echo "Nothing was published or tagged. To release: tag the commit, then upload"
echo "$ZIP to a GitHub Release with the CHANGELOG section and the SHA-256 above."
