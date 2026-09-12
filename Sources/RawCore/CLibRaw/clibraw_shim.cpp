// Implementation of the C shim declared in include/clibraw_shim.h.
//
// NOTE: the LibRaw call sequence here (open_buffer -> unpack ->
// imgdata.rawdata.raw_image) matches LibRaw's documented API for the
// 0.21/0.22 series. If a LibRaw upgrade breaks the build, this file is
// where the field names need rechecking.

#include "include/clibraw_shim.h"
#include "libraw.h"
#include <cstring>
#include <cstdlib>

struct CLibRawHandle {
    LibRaw processor;
};

extern "C" CLibRawHandle *clibraw_open_buffer(const void *bytes, size_t length) {
    auto *handle = new CLibRawHandle();

    // open_buffer reads the header only; it does not copy the whole file.
    if (handle->processor.open_buffer(const_cast<void *>(bytes), length) != LIBRAW_SUCCESS) {
        delete handle;
        return nullptr;
    }
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

    out->width      = static_cast<uint16_t>(d.sizes.width);
    out->height     = static_cast<uint16_t>(d.sizes.height);
    out->raw_width  = static_cast<uint16_t>(d.sizes.raw_width);
    out->raw_height = static_cast<uint16_t>(d.sizes.raw_height);

    // idata.filters encodes the 2x2 Bayer pattern as 4 x 2-bit color indices.
    // 0 => not a simple Bayer pattern; 9 => X-Trans.
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
    *out_length = static_cast<size_t>(sizes.raw_width) * sizes.raw_height * sizeof(uint16_t);
    return raw.raw_image;
}

extern "C" int clibraw_get_thumbnail(CLibRawHandle *handle, uint8_t *buffer, size_t *out_length) {
    if (!handle || !out_length) return -1;

    if (handle->processor.unpack_thumb() != LIBRAW_SUCCESS) {
        *out_length = 0;
        return -1;
    }
    auto &thumb = handle->processor.imgdata.thumbnail;

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
