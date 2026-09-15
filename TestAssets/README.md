# Test assets

Not committed to the repo (large, and mostly not ours to redistribute).
Drop files here with these exact names so the tests in
`Tests/PixelEngineTests` pick them up automatically:

| Filename | Source |
|---|---|
| `golden_nikon_d750_cc0.nef` | Downloaded by `scripts/fetch_test_assets.sh` (raw.pixls.us, CC0, checksum-verified). The golden-image tests render it |
| `nikon_d750_sample.nef` | One of your own D750 files, or raw.pixls.us |
| `sony_a7iii_compressed.arw` | One of your own A7 III files shot in compressed mode |
| `sony_a7iii_uncompressed.arw` | Same camera, uncompressed mode |
| `canon_cr2_sample.cr2` | raw.pixls.us |
| `canon_cr3_sample.cr3` | raw.pixls.us — only needed once a CR3-shooting body is confirmed |
| `monochrome_sample.dng` or raw | e.g. a Leica Monochrom sample from raw.pixls.us |
| `linear_sample.dng` | Any already-demosaiced linear DNG (many phone RAWs qualify) |

raw.pixls.us organizes samples by camera under
`https://raw.pixls.us/getfile.php/...` — browse by camera model there.

## Photo Merge brackets (`TestAssets/merge/`)

Fetched with `scripts/fetch_test_assets.sh --merge` (about 390 MB, checksum-verified). The merge's end-to-end tests skip when they're missing, so CI doesn't download them.

| Folder | What | Licence and credit |
|---|---|---|
| `ihrke-tripod-bracket/` | Canon EOS 5D Mark II on a tripod, manual mode, 6 frames 2 EV apart (1 s to 1/1250 s), EF 50mm f/1.4 | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Ivo Ihrke, "Test data for RAW high dynamic range merging", Zenodo, [doi:10.5281/zenodo.8169091](https://zenodo.org/records/8169091) |
| `empa-market-mires-2/` | Nikon D200, 5 frames 1 EV apart (1/800 to 1/50 s), people moving; with the database's EXR merge and tone-mapped JPEG | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Peter Zolliker, Iris Sprow et al., "Empa HDR Image Database", Zenodo, [doi:10.5281/zenodo.7861544](https://zenodo.org/records/7861544) |
| `empa-crete-seashore-1/` | Nikon D200, 7 frames 1 EV apart (1/5000 to 1/80 s), waves moving; with the EXR merge and tone-mapped JPEG | Same as above |

The files are unmodified. The Canon set is also a real camera with a masked sensor border: its readout is 5792 × 3804 and the active area 5634 × 3752 at (158, 52).
