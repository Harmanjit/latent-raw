#!/usr/bin/env bash
# Downloads the public-domain raw file the golden-image tests render
# (Tests/PixelEngineTests/GoldenImageTests.swift) and checks it against
# the SHA-256 that raw.pixls.us publishes. A changed file fails here
# instead of producing confusing test failures.
#
#   scripts/fetch_test_assets.sh
#
# Nikon D750, 14-bit lossless compressed, CC0 1.0 (public domain),
# https://raw.pixls.us/ (camera: Nikon D750).
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="golden_nikon_d750_cc0.nef"
URL="https://raw.pixls.us/getfile.php/898/nice/Nikon%20-%20D750%20-%2014bit%2014bit%20compressed%20(Lossless)%20(3:2).NEF"
SHA256="f90deb2819863f5a6ca9913c255fdd83a94963f4284eb88df9d389da7a6c7665"
DEST="TestAssets/${NAME}"

verify() { [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "${SHA256}" ]; }

if [ -f "${DEST}" ] && verify "${DEST}"; then
  echo "${NAME}: present and verified"
  exit 0
fi

mkdir -p TestAssets
TMP="$(mktemp "TestAssets/.${NAME}.XXXXXX")"
trap 'rm -f "${TMP}"' EXIT
echo "Downloading ${NAME} (25 MB) from raw.pixls.us"
curl --fail --location --silent --show-error \
     --retry 5 --retry-all-errors --retry-delay 5 --connect-timeout 20 --max-time 300 \
     -o "${TMP}" "${URL}"
if ! verify "${TMP}"; then
  echo "error: ${NAME} checksum mismatch; expected ${SHA256}" >&2
  exit 1
fi
mv "${TMP}" "${DEST}"
trap - EXIT
echo "${NAME}: downloaded and verified"
