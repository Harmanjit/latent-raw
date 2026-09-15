import Foundation

/// Nikon F-mount lenses identified by their full 8-byte lens ID, for the
/// lenses whose Lensfun entry can't be told apart from another by the
/// numbers the camera reports.
///
/// Nikon raw files never name the lens. The maker notes carry a lens ID
/// number (one byte), the focal range and maximum apertures, and a few
/// more bytes; together those 8 bytes identify a lens almost uniquely.
/// LibRaw hands the 8 bytes over as `lens_id`, in the order ExifTool
/// documents for its composite LensID: LensIDNumber, LensFStops,
/// MinFocalLength, MaxFocalLength, MaxApertureAtMinFocal,
/// MaxApertureAtMaxFocal, MCUVersion, LensType.
///
/// Why a table at all: the one-byte ID isn't unique (Tamron's SP 35mm
/// f/1.8 VC reports 232, which Nikon never assigned), and Lensfun records
/// it for only about 16 lenses, so three different 35mm f/1.8 lenses on a
/// D750 look identical to the matcher without it. The golden test file
/// is one of those: specs alone can't say it's the Tamron.
///
/// Only entries checked against the source are listed; don't add one from
/// memory. Source for every ID and name below: ExifTool's `%nikonLensIDs`
/// table (lib/Image/ExifTool/Nikon.pm, github.com/exiftool/exiftool,
/// checked 2026-09-15), which is based on Robert Rottmerhusen's lens ID
/// list. The values are the Lensfun database's spellings of the same lens,
/// so the matcher can compare names exactly.
enum NikonLensIDs {
    static let lensfunNames: [UInt64: [String]] = [
        // ExifTool: 'AF-S DX Zoom-Nikkor 17-55mm f/2.8G IF-ED' (the D200 brackets)
        0x7D48_2B53_2424_8206: ["Nikon AF-S DX Zoom-Nikkor 17-55mm f/2.8G IF-ED"],
        // ExifTool: 'AF-S DX Nikkor 16-80mm f/2.8-4E ED VR' (two MCU/type variants)
        0xAD48_2860_2430_C84E: ["Nikon AF-S DX Nikkor 16-80mm f/2.8-4E ED VR"],
        0xAD48_2860_2430_C80E: ["Nikon AF-S DX Nikkor 16-80mm f/2.8-4E ED VR"],
        // ExifTool: 'AF-S DX Nikkor 35mm f/1.8G'
        0x9F58_4444_1414_A106: ["Nikon AF-S DX Nikkor 35mm f/1.8G"],
        // ExifTool: 'AF-S Nikkor 35mm f/1.8G ED'
        0xA54C_4444_1414_C006: ["Nikon AF-S Nikkor 35mm f/1.8G ED"],
        // ExifTool: 'Tamron SP 35mm f/1.8 Di VC USD (F012)' (the golden D750 file)
        0xE84C_4444_1414_DF0E: ["Tamron SP 35mm f/1.8 Di VC USD F012"],
        // ExifTool: 'AF-S Nikkor 50mm f/1.4G' (Harman's D750 files)
        0xA054_5050_0C0C_A206: ["Nikon AF-S Nikkor 50mm f/1.4G"],
        // ExifTool: 'Tokina AT-X PRO 100mm F2.8 D Macro', which Lensfun
        // lists twice under different spellings.
        0x8D54_6868_2424_8702: ["Tokina AF 100mm f/2.8 AT-X Pro D M100 Macro",
                                "Tokina AT-X M100 100mm f/2.8 Pro D Macro AF"],
    ]

    /// The Lensfun names for a file's lens, when the table knows its ID.
    /// `lensID` is LibRaw's `lens_id`; its top byte must agree with the
    /// separately reported one-byte ID, or it isn't a Nikon composite.
    static func names(lensID: UInt64, nikonLensID: UInt8) -> [String]? {
        guard nikonLensID != 0, UInt8(truncatingIfNeeded: lensID >> 56) == nikonLensID else { return nil }
        return lensfunNames[lensID]
    }
}
