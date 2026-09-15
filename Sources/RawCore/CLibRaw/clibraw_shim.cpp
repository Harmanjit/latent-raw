// Implementation of the C shim declared in include/clibraw_shim.h.
//
// NOTE: the LibRaw call sequence here (open_buffer -> unpack ->
// imgdata.rawdata.raw_image) matches LibRaw's documented API for the
// 0.21/0.22 series. If a LibRaw upgrade breaks the build, this file is
// where the field names need rechecking.

#include "include/clibraw_shim.h"
#include "libraw.h"
#include <algorithm>
#include <cstring>
#include <cstdlib>

struct CLibRawHandle {
    LibRaw processor;
};

extern "C" CLibRawHandle *clibraw_open_buffer_metadata(const void *bytes, size_t length) {
    auto *handle = new CLibRawHandle();

    // open_buffer reads the header and runs identify(): it does not copy
    // or decode the sensor data.
    if (handle->processor.open_buffer(const_cast<void *>(bytes), length) != LIBRAW_SUCCESS) {
        delete handle;
        return nullptr;
    }
    return handle;
}

extern "C" CLibRawHandle *clibraw_open_buffer(const void *bytes, size_t length) {
    CLibRawHandle *handle = clibraw_open_buffer_metadata(bytes, length);
    if (!handle) return nullptr;

    // unpack() decodes the sensor data into imgdata.rawdata. This is the
    // expensive step (~190ms for a 24MP 14-bit lossless NEF).
    if (handle->processor.unpack() != LIBRAW_SUCCESS) {
        delete handle;
        return nullptr;
    }
    return handle;
}

extern "C" int clibraw_get_summary(CLibRawHandle *handle, CLibRawSummary *out) {
    if (!handle || !out) return -1;
    std::memset(out, 0, sizeof(CLibRawSummary));

    auto &d = handle->processor.imgdata;

    // The active area. LibRaw's own raw2image() copies
    // min(width, raw_width - left_margin) columns (and likewise rows), so
    // a file whose header claims more than the readout holds gets the
    // same clamp here and the rectangle always lies inside the buffer.
    auto &s = d.sizes;
    int activeWidth  = std::max(0, std::min(int(s.width),  int(s.raw_width)  - int(s.left_margin)));
    int activeHeight = std::max(0, std::min(int(s.height), int(s.raw_height) - int(s.top_margin)));
    out->width       = static_cast<uint16_t>(activeWidth);
    out->height      = static_cast<uint16_t>(activeHeight);
    out->raw_width   = s.raw_width;
    out->raw_height  = s.raw_height;
    out->left_margin = s.left_margin;
    out->top_margin  = s.top_margin;

    // idata.filters encodes the 2x2 Bayer pattern as 4 x 2-bit color indices.
    // 0 => not a simple Bayer pattern; 9 => X-Trans. LibRaw defines it
    // relative to the active area's top-left photosite (raw2image() looks
    // colours up with active-area coordinates), and open_datastream()
    // already moves an odd margin in by one and rotates `filters` to
    // match, so the low byte is the pattern of the plane RawFile cuts out.
    out->cfa_pattern = (d.idata.filters != 0 && d.idata.filters != 9)
                          ? static_cast<uint8_t>(d.idata.filters & 0xFF)
                          : 0xFF;

    for (int i = 0; i < 4; i++) out->cam_mul[i] = d.color.cam_mul[i];
    out->black_level = static_cast<float>(d.color.black);
    out->white_level = static_cast<float>(d.color.maximum);

    std::strncpy(out->camera_make,  d.idata.make,  sizeof(out->camera_make) - 1);
    std::strncpy(out->camera_model, d.idata.model, sizeof(out->camera_model) - 1);
    std::strncpy(out->lens_model,   d.lens.Lens,   sizeof(out->lens_model) - 1);

    out->iso           = d.other.iso_speed;
    out->shutter       = d.other.shutter;
    out->aperture      = d.other.aperture;
    out->focal_length  = d.other.focal_len;
    out->timestamp     = static_cast<int64_t>(d.other.timestamp);
    out->orientation   = d.sizes.flip;

    auto &lens = d.lens;
    std::strncpy(out->lens_make, lens.LensMake, sizeof(out->lens_make) - 1);
    std::strncpy(out->lens_makernotes, lens.makernotes.Lens, sizeof(out->lens_makernotes) - 1);
    out->lens_id         = lens.makernotes.LensID;
    out->nikon_lens_id   = lens.nikon.LensIDNumber;
    out->nikon_lens_type = lens.nikon.LensType;
    // Prefer the maker-note values; fall back to the EXIF-level ones.
    out->lens_min_focal = lens.makernotes.MinFocal > 0 ? lens.makernotes.MinFocal : lens.MinFocal;
    out->lens_max_focal = lens.makernotes.MaxFocal > 0 ? lens.makernotes.MaxFocal : lens.MaxFocal;
    out->lens_max_ap_min_focal = lens.makernotes.MaxAp4MinFocal > 0
        ? lens.makernotes.MaxAp4MinFocal : lens.MaxAp4MinFocal;
    out->lens_max_ap_max_focal = lens.makernotes.MaxAp4MaxFocal > 0
        ? lens.makernotes.MaxAp4MaxFocal : lens.MaxAp4MaxFocal;
    // Crop factor from the 35mm-equivalent focal length when recorded.
    float eq = lens.FocalLengthIn35mmFormat > 0 ? float(lens.FocalLengthIn35mmFormat)
             : lens.makernotes.FocalLengthIn35mmFormat;
    out->crop_factor = (eq > 0 && d.other.focal_len > 0) ? eq / d.other.focal_len : 0.0f;

    return 0;
}

extern "C" int clibraw_get_cam_xyz(CLibRawHandle *handle, float *out12) {
    if (!handle || !out12) return -1;
    auto &color = handle->processor.imgdata.color;

    // cam_xyz is populated during identify(), which open_buffer() runs, so
    // it's available without any further processing. An all-zero matrix
    // means LibRaw has no characterization for this camera.
    bool allZero = true;
    for (int i = 0; i < 4 && allZero; i++) {
        for (int j = 0; j < 3; j++) {
            if (color.cam_xyz[i][j] != 0.0) { allZero = false; break; }
        }
    }
    if (allZero) return -2;

    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 3; j++) {
            out12[i * 3 + j] = static_cast<float>(color.cam_xyz[i][j]);
        }
    }
    return 0;
}

extern "C" const uint16_t *clibraw_get_raw_plane(CLibRawHandle *handle, size_t *out_length) {
    if (!handle || !out_length) return nullptr;
    auto &raw = handle->processor.imgdata.rawdata;

    // raw_image is only populated for classic Bayer/X-Trans unpacking;
    // color4_image / float_image cover the four-colour-CFA and some linear
    // DNG cases. Bayer is all v1 needs (DESIGN.md §9.1).
    if (raw.raw_image == nullptr) {
        *out_length = 0;
        return nullptr;
    }

    auto &sizes = handle->processor.imgdata.sizes;
    // raw_pitch is the row stride in bytes. LibRaw sets it to
    // raw_width * 2 for a Bayer raw_image; anything else (only a RawSpeed
    // build produces it) would break the raw_width x raw_height layout
    // this function promises, so refuse rather than hand out a skewed plane.
    if (sizes.raw_pitch != 0 && sizes.raw_pitch != static_cast<unsigned>(sizes.raw_width) * 2) {
        *out_length = 0;
        return nullptr;
    }
    *out_length = static_cast<size_t>(sizes.raw_width) * sizes.raw_height * sizeof(uint16_t);
    return raw.raw_image;
}

// Picks the largest JPEG among the file's embedded previews. Many raws
// carry several (a tiny EXIF thumbnail, a mid-size one, a full-size
// preview); unpack_thumb() alone takes LibRaw's default choice, which for
// some files is a non-JPEG bitmap or an empty slot. Returns the index in
// thumbs_list, or -1 if there is no JPEG at all.
static int clibraw_best_jpeg_thumb_index(LibRaw &processor) {
    auto &list = processor.imgdata.thumbs_list;
    int best = -1;
    unsigned bestPixels = 0;
    for (int i = 0; i < list.thumbcount && i < LIBRAW_THUMBNAIL_MAXCOUNT; i++) {
        auto &item = list.thumblist[i];
        if (item.tformat != LIBRAW_INTERNAL_THUMBNAIL_JPEG) continue;
        unsigned pixels = static_cast<unsigned>(item.twidth) * item.theight;
        if (pixels >= bestPixels) { bestPixels = pixels; best = i; }
    }
    return best;
}

extern "C" int clibraw_get_thumbnail(CLibRawHandle *handle, uint8_t *buffer, size_t *out_length) {
    if (!handle || !out_length) return -1;
    auto &processor = handle->processor;

    int index = clibraw_best_jpeg_thumb_index(processor);
    int rc = (index >= 0) ? processor.unpack_thumb_ex(index) : processor.unpack_thumb();
    if (rc != LIBRAW_SUCCESS) {
        // Pass LibRaw's own code through (negative; see libraw_const.h),
        // offset so it can't collide with this shim's -1/-2.
        *out_length = 0;
        return -100 + rc;
    }
    auto &thumb = processor.imgdata.thumbnail;
    if (thumb.tformat != LIBRAW_THUMBNAIL_JPEG || thumb.tlength == 0) {
        *out_length = 0;
        return -3; // no usable JPEG preview
    }

    if (buffer == nullptr) {
        *out_length = static_cast<size_t>(thumb.tlength);
        return 0;
    }
    if (*out_length < static_cast<size_t>(thumb.tlength)) return -2; // buffer too small

    std::memcpy(buffer, thumb.thumb, thumb.tlength);
    *out_length = static_cast<size_t>(thumb.tlength);
    return 0;
}

extern "C" void clibraw_close(CLibRawHandle *handle) {
    delete handle;
}
