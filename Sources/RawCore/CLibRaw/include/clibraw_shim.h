// A narrow C interface over LibRaw's C++ API, so Swift can import it directly
// without a C++ interop layer. Every function here does one job only —
// keep this file small; new needs get a new function, not a widened one.
#ifndef CLIBRAW_SHIM_H
#define CLIBRAW_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CLibRawHandle CLibRawHandle;

typedef struct {
    // The sensor readout LibRaw unpacks is raw_width x raw_height. Only
    // part of it is picture: the active (LibRaw: "visible") area is the
    // width x height rectangle whose top-left photosite is at
    // (left_margin, top_margin). Around it can sit optically masked
    // columns and rows (black strips, common on Canon) and padding with
    // no image data at all (some Nikons). LibRaw's CFA pattern, and
    // everything else it does with the image, counts from the active
    // area's corner, not the readout's.
    uint16_t width;       // active area, clamped to lie inside the readout
    uint16_t height;
    uint16_t raw_width;   // the whole readout, masked border included
    uint16_t raw_height;
    uint16_t left_margin; // where the active area starts in the readout
    uint16_t top_margin;
    uint8_t  cfa_pattern; // packed 2x2 Bayer order at the active area's top-left, or 0xFF for X-Trans/other
    float    cam_mul[4];  // as-shot white balance multipliers, camera order
    float    black_level;
    float    white_level;
    char     camera_make[64];
    char     camera_model[64];
    char     lens_model[64];
    double   iso;
    double   shutter;
    double   aperture;
    double   focal_length;
    int64_t  timestamp; // unix epoch seconds
    int32_t  orientation; // LibRaw `flip`: 0 none, 3 = 180°, 5 = 90° CCW, 6 = 90° CW

    // Lens identity, for lens-correction profile lookup. Cameras rarely
    // record a full lens name; most record an ID plus the lens's focal
    // range and maximum apertures, which is enough to match a profile.
    char     lens_make[64];
    char     lens_makernotes[128]; // name from the maker notes, if any
    uint64_t lens_id;              // maker-specific lens ID (makernotes)
    uint8_t  nikon_lens_id;        // Nikon's 8-bit LensIDNumber
    uint8_t  nikon_lens_type;
    float    lens_min_focal, lens_max_focal;
    float    lens_max_ap_min_focal, lens_max_ap_max_focal;
    float    crop_factor;          // vs 35mm full frame; 0 if unknown

    // Black level per colour channel, in the same units as black_level:
    // LibRaw's common `black` plus its per-channel `cblack[0..3]`, with any
    // repeating black pattern (`cblack[4]` x `cblack[5]` values from
    // `cblack[6]` on) averaged into the channel each position belongs to.
    // Index 3 is the Bayer quad's second green. Today's renders still use
    // black_level; merges need these so unequal channel offsets don't tint
    // the shadows.
    float    channel_black[4];
    // The largest value actually present in the unpacked image, in the
    // units of white_level (sensor counts for Bayer, the stored value for
    // linear data). LibRaw only fills its own `data_maximum` during
    // processing steps this shim never runs, so the shim measures it.
    // 0 for metadata-only opens.
    float    data_maximum;
    // DNG BaselineExposure in stops: how much brighter than its stored
    // values the file asks to be shown. 0 when the file doesn't say.
    float    baseline_exposure;
    // 1 when the image is already demosaiced: a DNG with 3 colour samples
    // per pixel (LinearRaw), which Latent opens as a linear source.
    uint8_t  is_linear_rgb;
} CLibRawSummary;

// How the samples behind clibraw_get_linear_image are stored.
typedef enum {
    CLIBRAW_LINEAR_NONE    = 0,
    CLIBRAW_LINEAR_FLOAT3  = 1, // 3 x float32 per pixel (float DNGs)
    CLIBRAW_LINEAR_UINT16X3 = 2, // 3 x uint16 per pixel
    CLIBRAW_LINEAR_UINT16X4 = 3, // 4 x uint16 per pixel, the 4th unused
} CLibRawLinearFormat;

// Opens and unpacks a raw file from an already-mapped read-only buffer
// (the caller mmap()s the file; LibRaw never needs its own file handle).
// Returns NULL on failure.
CLibRawHandle *clibraw_open_buffer(const void *bytes, size_t length);

// Same, but stops after LibRaw's identify step: metadata, colour matrix
// and the embedded preview are available, the sensor plane is not.
// ~100x cheaper than a full open — this is what the catalog uses.
CLibRawHandle *clibraw_open_buffer_metadata(const void *bytes, size_t length);

// Fills `out` with the fields needed for the catalog and the pipeline's
// early stages. Cheap — no demosaic, no color conversion.
int clibraw_get_summary(CLibRawHandle *handle, CLibRawSummary *out);

// Writes the camera's XYZ->camera characterization matrix into `out12`,
// row-major, 4 rows of 3 (the 4th row is only meaningful for four-colour
// CFAs; Bayer cameras use the first 3 rows).
//
// This is the Adobe "ColorMatrix" convention: it converts CIE XYZ into the
// camera's native response. ColorKit inverts and composes it to get the
// camera -> working-space transform. Kept out of CLibRawSummary because a
// fixed C array of 12 floats imports into Swift as an unwieldy 12-tuple.
//
// Returns 0 on success, non-zero if the camera has no known matrix (in
// which case the caller must fall back to a generic profile).
int clibraw_get_cam_xyz(CLibRawHandle *handle, float *out12);

// Returns a pointer to LibRaw's internal unpacked sensor buffer (one
// uint16 per photosite, the whole raw_width x raw_height readout, row by
// row) without copying it, along with its byte length. The caller cuts
// the active area out of it (see CLibRawSummary). The pointer is owned
// by `handle` and is valid until clibraw_close is called.
const uint16_t *clibraw_get_raw_plane(CLibRawHandle *handle, size_t *out_length);

// For a linear (already demosaiced, 3-colour) image: a pointer to
// LibRaw's unpacked pixels, the whole raw_width x raw_height readout row
// by row, without copying, with its storage in *out_format and its byte
// length in *out_length. Float DNGs arrive as float32 because
// clibraw_open_buffer clears LibRaw's option that would otherwise turn
// them into 16-bit integers (and clip everything above white). NULL, with
// CLIBRAW_LINEAR_NONE, for Bayer and every other layout. Owned by
// `handle`, valid until clibraw_close.
const void *clibraw_get_linear_image(CLibRawHandle *handle, CLibRawLinearFormat *out_format,
                                     size_t *out_length);

// The file's XMP packet (the text of TIFF tag 700) without copying it,
// or NULL with *out_length 0 when there is none. Not NUL-terminated.
// Owned by `handle`, valid until clibraw_close.
const char *clibraw_get_xmp(CLibRawHandle *handle, size_t *out_length);

// Extracts the embedded JPEG preview (for instant thumbnails) into a
// caller-provided buffer. Call once with buffer=NULL to get the required
// size in *out_length, then again with an allocated buffer.
int clibraw_get_thumbnail(CLibRawHandle *handle, uint8_t *buffer, size_t *out_length);

void clibraw_close(CLibRawHandle *handle);

#ifdef __cplusplus
}
#endif

#endif
