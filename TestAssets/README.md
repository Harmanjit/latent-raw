# Test assets

Not committed to the repo (large, and mostly not ours to redistribute).
Drop files here with these exact names and the tests under `Tests/` pick
them up automatically; a test whose file is missing skips itself. Each test
target that reads samples finds this folder through its own
`Support/TestAssets.swift`, except `LensKitTests`, which uses
`LensMatchingTests.assetPath`.

| Filename | Source |
|---|---|
| `golden_nikon_d750_cc0.nef` | Downloaded by `scripts/fetch_test_assets.sh` (raw.pixls.us, CC0, checksum-verified). The golden-image tests render it, and it is the only file CI has |
| `nikon_d750_sample.nef` | Harman's own D750 raw, with a Tokina AF 100mm f/2.8 Macro. Tests that take any D750 raw use it ahead of the golden raw, and `LensMatchingTests`, `HealTests` and `LocalAdjustmentTests` rely on this particular picture |
| `HSB_2615.NEF`, `HSB_2639.NEF`, `HSB_6548.NEF` | Harman's own D750 raws, with an AF-S Nikkor 50mm f/1.4G. Read by the lens-matching, lens-correction, active-area, demosaic-border, soft-proof, AI mask, AI denoise and export-worker tests |
| `HSB_6664.NEF` | Harman's own D750 raw, with a Tokina AF 100mm f/2.8 Macro. Read by `LensMatchingTests` and `ActiveAreaTests` |
| `sony_a7iii_compressed.arw` | An A7 III (ILCE-7M3) raw shot in compressed mode, your own or from raw.pixls.us, which lists its samples by camera. `RenderPipelineTests` checks that it opens |

Harman's own files are not redistributed. Several tests that name them
assert things about those particular pictures (the lens, where the sky is,
where a heal lands), so a different photo under the same name can fail
rather than skip.

## Photo Merge brackets (`TestAssets/merge/`)

Fetched with `scripts/fetch_test_assets.sh --merge` (about 390 MB, checksum-verified). The merge's end-to-end tests skip when they're missing, so CI doesn't download them.

| Folder | What | Licence and credit |
|---|---|---|
| `ihrke-tripod-bracket/` | Canon EOS 5D Mark II on a tripod, manual mode, 6 frames 2 EV apart (1 s to 1/1250 s), EF 50mm f/1.4 | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Ivo Ihrke, "Test data for RAW high dynamic range merging", Zenodo, [doi:10.5281/zenodo.8169091](https://zenodo.org/records/8169091) |
| `empa-market-mires-2/` | Nikon D200, 5 frames 1 EV apart (1/800 to 1/50 s), people moving; with the database's EXR merge and tone-mapped JPEG | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Peter Zolliker, Iris Sprow et al., "Empa HDR Image Database", Zenodo, [doi:10.5281/zenodo.7861544](https://zenodo.org/records/7861544) |
| `empa-crete-seashore-1/` | Nikon D200, 7 frames 1 EV apart (1/5000 to 1/80 s), waves moving; with the EXR merge and tone-mapped JPEG | Same as above |

The files are unmodified. The Canon set is also a real camera with a masked sensor border: its readout is 5792 × 3804 and the active area 5634 × 3752 at (158, 52).

## Portrait (`TestAssets/portrait/`)

Fetched with `scripts/fetch_test_assets.sh --portrait` (3.7 MB, checksum-verified). The face-detection and touch-up tests skip when it is missing.

| Filename | What | Licence and credit |
|---|---|---|
| `zena_cardman_nasa_portrait.jpg` | Official NASA portrait of astronaut candidate Zena Cardman, 2017, 4800 × 6000 JPEG (Hasselblad H6D-50c): frontal, studio-lit, smiling with teeth visible. Apple Vision finds one face (confidence 1.0) with left eye, right eye, outer lips and inner lips landmarks | Public domain: a work of NASA, a US government agency (`PD-USGov-NASA`; the Commons page states "This file is in the public domain in the United States because it was solely created by NASA"). NASA/Bill Stafford, photo ID JSC2017-E-116316, via [Wikimedia Commons](https://commons.wikimedia.org/wiki/File:Zena_Cardman_official_portrait.jpg) (original on [NASA Johnson's Flickr](https://www.flickr.com/photos/nasa2explore/42953217460/)) |

The file is unmodified.

## Photo Merge panorama (`TestAssets/pano/`)

Harman's own photos, not redistributed (tests skip without them): Nikon D750 with an AF-S Nikkor 50mm f/1.4G, 17 frames (`HSB_6554.NEF` to `HSB_6570.NEF`), handheld, portrait orientation, one row across mountains, sky and a path at dusk. Shot at 1/400 s and ISO 100, but the aperture moves between f/2.5 and f/3.5, so frames differ by up to about 1 EV. People walk through frames 6565 to 6568, one of them close to the camera. That covers gain compensation, parallax and moving people, and makes a panorama wider than 16,384 px (the downsampling case).
