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
    // Set once unpack() has run, so the summary can tell "no image" from
    // "not decoded yet".
    bool unpacked = false;
    // The measured data maximum (see CLibRawSummary.data_maximum),
    // worked out on first request.
    bool dataMaximumKnown = false;
    float dataMaximum = 0;
};

extern "C" CLibRawHandle *clibraw_open_buffer_metadata(const void *bytes, size_t length) {
    auto *handle = new CLibRawHandle();

    // By default LibRaw turns floating-point DNG samples into 16-bit
    // integers as it unpacks them, scaling so the brightest value fits and
    // clipping at white. A merged HDR image keeps its range only as
    // floats, so ask for them as they are. Every ordinary raw stores
    // integers and never reaches the conversion, so this changes nothing
    // for them. It has to be set before open: LibRaw reads it while
    // choosing the decoder.
    handle->processor.imgdata.rawparams.options &= ~LIBRAW_RAWOPTIONS_CONVERTFLOAT_TO_INT;

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
    handle->unpacked = true;
    return handle;
}

// Whether the file describes an already-demosaiced image: a DNG (LinearRaw)
// with three colours per pixel and no colour filter pattern. Needs only
// identify(), so metadata-only opens can answer it too. Limited to DNG
// because other 3-colour layouts LibRaw knows (Foveon X3F) aren't camera
// RGB that is ready to use.
static bool clibraw_describes_linear_rgb(LibRaw &processor) {
    auto &idata = processor.imgdata.idata;
    return idata.dng_version != 0 && idata.filters == 0 && idata.colors == 3;
}

// Which of LibRaw's unpacked buffers holds a linear image, if any, and how
// many bytes one pixel takes in it.
static CLibRawLinearFormat clibraw_linear_format(LibRaw &processor, size_t *bytes_per_pixel) {
    auto &raw = processor.imgdata.rawdata;
    *bytes_per_pixel = 0;
    if (!clibraw_describes_linear_rgb(processor)) return CLIBRAW_LINEAR_NONE;
    CLibRawLinearFormat format = CLIBRAW_LINEAR_NONE;
    if (raw.float3_image)      { format = CLIBRAW_LINEAR_FLOAT3;   *bytes_per_pixel = 3 * sizeof(float); }
    else if (raw.color3_image) { format = CLIBRAW_LINEAR_UINT16X3; *bytes_per_pixel = 3 * sizeof(uint16_t); }
    else if (raw.color4_image) { format = CLIBRAW_LINEAR_UINT16X4; *bytes_per_pixel = 4 * sizeof(uint16_t); }
    // As for the Bayer plane: the row stride must be exactly one row of
    // pixels, or the layout this shim promises doesn't hold.
    auto &sizes = processor.imgdata.sizes;
    if (format != CLIBRAW_LINEAR_NONE && sizes.raw_pitch != 0
        && sizes.raw_pitch != static_cast<unsigned>(sizes.raw_width) * *bytes_per_pixel) {
        *bytes_per_pixel = 0;
        return CLIBRAW_LINEAR_NONE;
    }
    return format;
}

// LibRaw's black level for each colour channel, with a repeating black
// pattern folded in. LibRaw does this folding itself (adjust_bl) only
// inside processing steps the shim never runs, and it changes LibRaw's
// state as it goes; this works it out on the side instead.
static void clibraw_channel_black(LibRaw &processor, float out[4]) {
    auto &color = processor.imgdata.color;
    for (int c = 0; c < 4; c++) out[c] = static_cast<float>(color.black) + static_cast<float>(color.cblack[c]);

    // cblack[4] x cblack[5] is the pattern's size in rows and columns,
    // and its values follow from cblack[6], row by row, repeating across
    // the active area from its top-left photosite.
    unsigned rows = color.cblack[4], cols = color.cblack[5];
    if (rows == 0 || cols == 0 || rows * cols > LIBRAW_CBLACK_SIZE - 6) return;

    unsigned filters = processor.imgdata.idata.filters;
    // LibRaw's own test for a CFA whose colours repeat every 2x2 (X-Trans
    // is 9, and a few old backs use small values for other layouts).
    bool bayer = filters > 1000;
    double sum[4] = {0, 0, 0, 0}, count[4] = {0, 0, 0, 0}, all = 0;
    for (unsigned r = 0; r < rows; r++) {
        for (unsigned col = 0; col < cols; col++) {
            double value = color.cblack[6 + r * cols + col];
            all += value;
            if (!bayer) continue;
            // LibRaw's FC(): the colour at (row, col), 3 for the quad's
            // second green on most files. Some files label both greens 1;
            // the second (odd row) one is then counted as 3, as adjust_bl does.
            int channel = (filters >> ((((r << 1) & 14) | (col & 1)) << 1)) & 3;
            if (channel == 1 && (r & 1) == 1) channel = 3;
            sum[channel] += value;
            count[channel] += 1;
        }
    }
    double mean = all / (rows * cols);
    // A channel the pattern never lands on (a one-row pattern on a Bayer
    // sensor, or any linear image) gets the pattern's average.
    for (int c = 0; c < 4; c++) out[c] += static_cast<float>(count[c] > 0 ? sum[c] / count[c] : mean);
}

// The largest sample in the active area of the unpacked image, measured
// once. A plain loop over the pointers, which the compiler vectorises,
// because this runs on every full open: under 1.5 ms for 24 MP in a
// release build (about 70 ms unoptimised, as `swift test` builds it).
static float clibraw_measure_data_maximum(CLibRawHandle *handle) {
    if (handle->dataMaximumKnown) return handle->dataMaximum;
    auto &processor = handle->processor;
    auto &raw = processor.imgdata.rawdata;
    auto &s = processor.imgdata.sizes;
    int left = s.left_margin, top = s.top_margin;
    int width  = std::max(0, std::min(int(s.width),  int(s.raw_width)  - left));
    int height = std::max(0, std::min(int(s.height), int(s.raw_height) - top));
    float result = 0;

    size_t bytesPerPixel = 0;
    CLibRawLinearFormat linear = clibraw_linear_format(processor, &bytesPerPixel);
    if (linear == CLIBRAW_LINEAR_FLOAT3) {
        // LibRaw measures float data as it decodes it.
        result = processor.imgdata.color.fmaximum;
    } else if (linear != CLIBRAW_LINEAR_NONE) {
        int samples = linear == CLIBRAW_LINEAR_UINT16X3 ? 3 : 4;
        uint16_t best = 0;
        for (int row = 0; row < height; row++) {
            const uint16_t *p = raw.color4_image ? raw.color4_image[(row + top) * s.raw_width + left]
                                                 : raw.color3_image[(row + top) * s.raw_width + left];
            for (int i = 0; i < width * samples; i += samples) {
                // Only the three colours; a 4-sample buffer's last is unused.
                best = std::max(best, std::max(p[i], std::max(p[i + 1], p[i + 2])));
            }
        }
        result = best;
    } else if (raw.raw_image && (s.raw_pitch == 0 || s.raw_pitch == static_cast<unsigned>(s.raw_width) * 2)) {
        uint16_t best = 0;
        for (int row = 0; row < height; row++) {
            const uint16_t *p = raw.raw_image + static_cast<size_t>(row + top) * s.raw_width + left;
            for (int col = 0; col < width; col++) best = std::max(best, p[col]);
        }
        result = best;
    }
    handle->dataMaximum = result;
    handle->dataMaximumKnown = true;
    return result;
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
    // 0xFE is the code a linear image travels under (CFAPattern.linearRGB
    // in RawFile.swift). No Bayer quad packs to it (it has no red), but an
    // exotic four-colour filter could; such a file counts as "other".
    if (out->cfa_pattern == 0xFE) out->cfa_pattern = 0xFF;
    // A linear image: once unpacked, LibRaw must also have produced one of
    // the buffers clibraw_get_linear_image hands out; before that, what
    // identify() found is all there is to go on.
    if (handle->unpacked) {
        size_t bytesPerPixel = 0;
        out->is_linear_rgb = clibraw_linear_format(handle->processor, &bytesPerPixel) != CLIBRAW_LINEAR_NONE;
    } else {
        out->is_linear_rgb = clibraw_describes_linear_rgb(handle->processor);
    }

    for (int i = 0; i < 4; i++) out->cam_mul[i] = d.color.cam_mul[i];
    out->black_level = static_cast<float>(d.color.black);
    out->white_level = static_cast<float>(d.color.maximum);
    // A floating-point DNG with no WhiteLevel tag means white is 1.0 (the
    // DNG specification's default for float samples). LibRaw reports its
    // integer default of 65535 then, which would divide every value by it.
    // An integer DNG always gets a white from LibRaw (1 << bits) - 1, so
    // dng_whitelevel[0] is 0 only in the float case.
    if (clibraw_describes_linear_rgb(handle->processor) && handle->processor.is_floating_point()
        && d.color.dng_levels.dng_whitelevel[0] == 0) {
        out->white_level = 1.0f;
    }
    clibraw_channel_black(handle->processor, out->channel_black);
    out->data_maximum = handle->unpacked ? clibraw_measure_data_maximum(handle) : 0.0f;
    // LibRaw marks "no BaselineExposure tag" as -999.
    float baseline = d.color.dng_levels.baseline_exposure;
    out->baseline_exposure = (baseline > -100.0f && baseline < 100.0f) ? baseline : 0.0f;

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

extern "C" const void *clibraw_get_linear_image(CLibRawHandle *handle, CLibRawLinearFormat *out_format,
                                                size_t *out_length) {
    if (!handle || !out_format || !out_length) return nullptr;
    *out_format = CLIBRAW_LINEAR_NONE;
    *out_length = 0;
    auto &processor = handle->processor;
    size_t bytesPerPixel = 0;
    CLibRawLinearFormat format = clibraw_linear_format(processor, &bytesPerPixel);
    if (format == CLIBRAW_LINEAR_NONE) return nullptr;

    auto &raw = processor.imgdata.rawdata;
    auto &sizes = processor.imgdata.sizes;
    *out_format = format;
    *out_length = static_cast<size_t>(sizes.raw_width) * sizes.raw_height * bytesPerPixel;
    switch (format) {
    case CLIBRAW_LINEAR_FLOAT3:   return raw.float3_image;
    case CLIBRAW_LINEAR_UINT16X3: return raw.color3_image;
    case CLIBRAW_LINEAR_UINT16X4: return raw.color4_image;
    default:                      return nullptr;
    }
}

extern "C" const char *clibraw_get_xmp(CLibRawHandle *handle, size_t *out_length) {
    if (!handle || !out_length) return nullptr;
    auto &idata = handle->processor.imgdata.idata;
    if (!idata.xmpdata || idata.xmplen == 0) {
        *out_length = 0;
        return nullptr;
    }
    *out_length = idata.xmplen;
    return idata.xmpdata;
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
