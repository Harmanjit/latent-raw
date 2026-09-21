#!/usr/bin/env bash
# Downloads the public-domain raw file the golden-image tests render
# (Tests/PixelEngineTests/GoldenImageTests.swift) and checks it against
# the SHA-256 that raw.pixls.us publishes. A changed file fails here
# instead of producing confusing test failures.
#
#   scripts/fetch_test_assets.sh              the golden raw only (what CI needs)
#   scripts/fetch_test_assets.sh --merge      also the Photo Merge brackets (~390 MB)
#   scripts/fetch_test_assets.sh --portrait   also the portrait for the face tests (3.7 MB)
#
# Nikon D750, 14-bit lossless compressed, CC0 1.0 (public domain),
# https://raw.pixls.us/ (camera: Nikon D750).
set -euo pipefail
cd "$(dirname "$0")/.."

WANT_MERGE=false
WANT_PORTRAIT=false
for arg in "$@"; do
  case "${arg}" in
    --merge) WANT_MERGE=true ;;
    --portrait) WANT_PORTRAIT=true ;;
    *) echo "usage: $0 [--merge] [--portrait]" >&2; exit 2 ;;
  esac
done

NAME="golden_nikon_d750_cc0.nef"
URL="https://raw.pixls.us/getfile.php/898/nice/Nikon%20-%20D750%20-%2014bit%2014bit%20compressed%20(Lossless)%20(3:2).NEF"
SHA256="f90deb2819863f5a6ca9913c255fdd83a94963f4284eb88df9d389da7a6c7665"
DEST="TestAssets/${NAME}"

verify() { [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "${SHA256}" ]; }

if [ -f "${DEST}" ] && verify "${DEST}"; then
  echo "${NAME}: present and verified"
else
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
fi

# Photo Merge brackets: real raw exposure brackets for the HDR merge's
# end-to-end checks. Both are CC BY 4.0, so they may be used freely with
# credit (see TestAssets/README.md). Each zip is checked against the
# SHA-256 below (Zenodo publishes MD5s; these were taken from files that
# matched them), then only the raws and reference renders are kept.
#
# fetch_merge_set <folder> <zip name> <Zenodo record> <sha256> <files to keep...>
fetch_merge_set() {
  local name="$1" folder="TestAssets/merge/$1" zip="$2" record="$3" sum="$4"; shift 4
  if [ -f "${folder}/.verified-${sum}" ]; then
    echo "merge/${name}: present and verified"
    return
  fi
  mkdir -p "${folder}"
  local tmp; tmp="$(mktemp "TestAssets/.${zip}.XXXXXX")"
  echo "Downloading ${zip} from Zenodo record ${record}"
  curl --fail --location --silent --show-error \
       --retry 5 --retry-all-errors --retry-delay 5 --connect-timeout 20 --max-time 1800 \
       -o "${tmp}" "https://zenodo.org/api/records/${record}/files/${zip}/content"
  if [ "$(shasum -a 256 "${tmp}" | cut -d' ' -f1)" != "${sum}" ]; then
    rm -f "${tmp}"
    echo "error: ${zip} checksum mismatch; expected ${sum}" >&2
    exit 1
  fi
  # -j drops the archive's folders, so nothing can land outside ${folder}.
  unzip -q -j -o "${tmp}" "$@" -d "${folder}"
  rm -f "${tmp}"
  touch "${folder}/.verified-${sum}"
  echo "merge/${name}: downloaded and verified"
}

if ${WANT_MERGE}; then
  # Ivo Ihrke: Canon EOS 5D Mark II on a tripod, 6 frames 2 EV apart (1 s to 1/1250 s).
  fetch_merge_set ihrke-tripod-bracket HDRTest_Raw.zip 8169091 \
    bda47843d47c1acc0f3c6a05af8c1a91e21f59225a82376f25abd3354a087b32 'HDRTest_Raw/*'
  # Empa HDR Image Database: Nikon D200, 5 frames 1 EV apart, people moving.
  fetch_merge_set empa-market-mires-2 MarketMires2.zip 7861544 \
    b688c156cd1836d727c7ec1e961275a58282142b0cbd93f6f2dbadb5ad9b8811 \
    'DSC_*.NEF' 'MarketMires2_tonemapped.jpg' 'MarketMires2.exr'
  # Empa HDR Image Database: Nikon D200, 7 frames 1 EV apart, waves moving.
  fetch_merge_set empa-crete-seashore-1 CreteSeashore1.zip 7861544 \
    dd517f7dceb168d2941d3bf95753429410bc253837ab498d26500553efecd0fc \
    'DSC_*.NEF' 'CreteSeashore1_tonemapped.jpg' 'CreteSeashore1.exr'
fi

# Portrait for the face-detection tests (Apple Vision landmarks: eyes, lips,
# inner mouth). Official NASA astronaut portrait, public domain as a US
# government work (PD-USGov-NASA), from Wikimedia Commons; credit in
# TestAssets/README.md. Wikimedia asks for a descriptive User-Agent, hence
# the -A.
#
# fetch_portrait <file name> <direct URL> <sha256>
fetch_portrait() {
  local name="$1" url="$2" sum="$3" dest="TestAssets/portrait/$1"
  if [ -f "${dest}" ] && [ "$(shasum -a 256 "${dest}" | cut -d' ' -f1)" = "${sum}" ]; then
    echo "portrait/${name}: present and verified"
    return
  fi
  mkdir -p TestAssets/portrait
  local tmp; tmp="$(mktemp "TestAssets/.${name}.XXXXXX")"
  echo "Downloading ${name} (3.7 MB) from Wikimedia Commons"
  curl --fail --location --silent --show-error \
       --retry 5 --retry-all-errors --retry-delay 5 --connect-timeout 20 --max-time 300 \
       -A "Latent-test-assets/1.0 (https://github.com/harman/latent)" \
       -o "${tmp}" "${url}"
  if [ "$(shasum -a 256 "${tmp}" | cut -d' ' -f1)" != "${sum}" ]; then
    rm -f "${tmp}"
    echo "error: ${name} checksum mismatch; expected ${sum}" >&2
    exit 1
  fi
  mv "${tmp}" "${dest}"
  echo "portrait/${name}: downloaded and verified"
}

if ${WANT_PORTRAIT}; then
  # NASA/Bill Stafford, official portrait of astronaut candidate Zena Cardman,
  # 2017-09-15, JSC2017-E-116316, 4800 x 6000. PD-USGov-NASA.
  fetch_portrait zena_cardman_nasa_portrait.jpg \
    "https://upload.wikimedia.org/wikipedia/commons/4/45/Zena_Cardman_official_portrait.jpg" \
    9364c55ae90de4bb895be8eee2dc5b5187dbf70303510e21997e18b4db2e7044
fi
