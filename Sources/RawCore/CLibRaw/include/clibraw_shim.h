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
    uint16_t width;
    uint16_t height;
    uint16_t raw_width;   // includes any border LibRaw doesn't crop
    uint16_t raw_height;
    uint8_t  cfa_pattern; // packed 2x2 Bayer order, or 0xFF for X-Trans/other
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
} CLibRawSummary;

// Opens and unpacks a raw file from an already-mapped read-only buffer
// (the caller mmap()s the file; LibRaw never needs its own file handle).
// Returns NULL on failure.
CLibRawHandle *clibraw_open_buffer(const void *bytes, size_t length);

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
// uint16 per photosite, in raw_width x raw_height) without copying it,
// along with its byte length. The pointer is owned by `handle` and is
// valid until clibraw_close is called.
const uint16_t *clibraw_get_raw_plane(CLibRawHandle *handle, size_t *out_length);

// Extracts the embedded JPEG preview (for instant thumbnails) into a
// caller-provided buffer. Call once with buffer=NULL to get the required
// size in *out_length, then again with an allocated buffer.
int clibraw_get_thumbnail(CLibRawHandle *handle, uint8_t *buffer, size_t *out_length);

void clibraw_close(CLibRawHandle *handle);

#ifdef __cplusplus
}
#endif

#endif
