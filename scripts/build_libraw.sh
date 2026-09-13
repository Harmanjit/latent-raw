#!/bin/bash
# Builds vendor/LibRaw.xcframework from a pinned LibRaw tag.
#
# The XCFramework is not committed (it's a 20 MB binary that changes with
# every LibRaw release), so a fresh clone and CI both run this first. It's
# idempotent: if the framework already exists and was built from the same
# tag, it does nothing.
#
#   scripts/build_libraw.sh            # build if missing or stale
#   LIBRAW_TAG=0.22.2 scripts/build_libraw.sh
#
# Needs: autoconf automake libtool pkg-config (brew), and Xcode's
# command-line tools. Configured arm64-only, static, without OpenMP
# (Latent schedules its own parallelism) and without libjpeg/LCMS/JasPer
# so the static library has no dependencies beyond zlib, which
# Package.swift links. Only the library target is built.
set -euo pipefail
trap 'echo "build_libraw.sh: failed at line $LINENO (see output above)"' ERR

LIBRAW_TAG="${LIBRAW_TAG:-0.22.2}"
# The commit the tag pointed at when it was vetted. Tags can be moved;
# commits can't. Update both together when bumping LibRaw.
LIBRAW_COMMIT="${LIBRAW_COMMIT:-b93f6e45c194f5df9b02a43b1af9a54b4f41f33f}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor"
SRC="${SRC:-$VENDOR/libraw-src}"
OUT="${OUT:-$VENDOR/LibRaw.xcframework}"
STAMP="$OUT/.libraw-tag"

if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "${LIBRAW_TAG}" ]; then
  echo "LibRaw ${LIBRAW_TAG} already built at $OUT"
  exit 0
fi

for tool in autoreconf glibtoolize xcodebuild; do
  command -v "$tool" >/dev/null || { echo "missing $tool (brew install autoconf automake libtool)"; exit 1; }
done
echo "Tools: $(command -v autoreconf) $(command -v glibtoolize) $(xcodebuild -version | head -1)"

if [ ! -d "$SRC/.git" ] || [ "$(git -C "$SRC" describe --tags --exact-match 2>/dev/null || true)" != "${LIBRAW_TAG}" ]; then
  rm -rf "$SRC"
  echo "Cloning LibRaw ${LIBRAW_TAG}..."
  git clone --quiet --branch "${LIBRAW_TAG}" --depth 1 https://github.com/LibRaw/LibRaw.git "$SRC"
fi

cd "$SRC"
ACTUAL="$(git rev-parse HEAD)"
if [ "$ACTUAL" != "$LIBRAW_COMMIT" ]; then
  echo "LibRaw tag ${LIBRAW_TAG} resolves to $ACTUAL, expected $LIBRAW_COMMIT; refusing to build" >&2
  exit 1
fi
echo "Configuring..."
autoreconf --install
./configure --host=aarch64-apple-darwin \
            --disable-shared --enable-static \
            --disable-openmp --disable-jpeg --disable-lcms \
            CFLAGS="-arch arm64 -mmacosx-version-min=15.0" \
            CXXFLAGS="-arch arm64 -mmacosx-version-min=15.0"
echo "Building..."
# Only the library: LibRaw's sample programs are C sources linked without
# the C++ runtime and fail to link on current Xcode; we never use them.
make -j"$(sysctl -n hw.ncpu)" lib/libraw.la
[ -f lib/.libs/libraw.a ] || { echo "libraw.a was not produced"; exit 1; }

rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library lib/.libs/libraw.a -headers libraw \
  -output "$OUT"
echo "${LIBRAW_TAG}" > "$STAMP"
echo "Built $OUT from LibRaw ${LIBRAW_TAG}"
