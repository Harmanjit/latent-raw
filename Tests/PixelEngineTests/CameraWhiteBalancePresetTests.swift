import XCTest
import ColorKit
@testable import PixelEngine
@testable import RawCore

/// The camera's own white balance presets: carried across the decoder
/// service, checked on arrival, and turned into temperature and tint for
/// the White Balance menu.
final class CameraWhiteBalancePresetTests: XCTestCase {
    typealias F = RawReconstructionFixtures

    static let presets: [CameraWhiteBalancePreset] = [
        .init(illuminant: 1, kelvin: 0, multipliers: [2048, 1024, 1500, 1024]),
        .init(illuminant: 11, kelvin: 0, multipliers: [2400, 1024, 1250, 1024]),
        .init(illuminant: 3, kelvin: 0, multipliers: [1300, 1024, 2600, 0]),
        .init(illuminant: 254, kelvin: 6500, multipliers: [2.2, 1, 1.4, 1]),
        .init(illuminant: 254, kelvin: 3000, multipliers: [1.4, 1, 2.4, 1]),
    ]

    func testTitles() {
        XCTAssertEqual(Self.presets.map(\.title), ["Daylight", "Shade", "Tungsten", "6500 K", "3000 K"])
    }

    /// What the service sends survives the JSON reply; anything unusable
    /// is dropped on arrival, and a file with none sends nothing.
    func testCrossesTheServiceAndIsChecked() throws {
        var summary = F.summary(width: 64, height: 48)
        summary.cameraWhiteBalancePresets = Self.presets
        var meta = RawSnapshotMetadata(summary: summary, cameraToXYZ: nil, thumbnailError: 0, isMetadataOnly: true,
                                       planeSampleCount: 0)
        let decoded = try JSONDecoder().decode(RawSnapshotMetadata.self, from: try JSONEncoder().encode(meta))
        XCTAssertEqual(decoded.summary.cameraWhiteBalancePresets, Self.presets)

        meta.cameraWhiteBalancePresets = [.init(illuminant: 1, kelvin: 0, multipliers: [1, .nan, 1, 1]),
                                          .init(illuminant: 2, kelvin: 0, multipliers: [1, 1]),
                                          .init(illuminant: 3, kelvin: 0, multipliers: [1.5, 1, 2, 1])]
        XCTAssertEqual(meta.summary.cameraWhiteBalancePresets.map(\.illuminant), [3])

        let none = RawSnapshotMetadata(summary: F.summary(width: 64, height: 48), cameraToXYZ: nil, thumbnailError: 0,
                                       isMetadataOnly: true, planeSampleCount: 0)
        XCTAssertNil(none.cameraWhiteBalancePresets)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(none), as: UTF8.self).contains("cameraWhiteBalancePresets"))
    }

    /// Light sources first in the camera's order, then Kelvin entries warm
    /// to cool; each converts through the as-shot solver, so a preset with
    /// the as-shot multipliers lands on the as-shot temperature.
    func testChoicesUseTheAsShotSolver() throws {
        let profile = try XCTUnwrap(ColorKit.CameraColorProfile(cameraToXYZRowMajor: F.cameraMatrix))
        let asShot = CameraWhiteBalancePreset(illuminant: 1, kelvin: 0, multipliers: [2, 1, 1.5, 1])
        let choices = CameraWhiteBalanceChoice.choices(for: Self.presets + [asShot], profile: profile)
        XCTAssertEqual(choices.map(\.title), ["Daylight", "Shade", "Tungsten", "Daylight 2", "3000 K", "6500 K"])
        XCTAssertEqual(Set(choices.map(\.id)).count, choices.count)
        let expected = profile.whiteBalance(fromMultipliers: ColorKit.normalizedWhiteBalance((2, 1, 1.5, 1)))
        XCTAssertEqual(choices[3].balance.temperature, expected.temperature, accuracy: 0.01)
        XCTAssertTrue(choices.allSatisfy { $0.balance.temperature.isFinite && $0.balance.tint.isFinite })
        // Shade is warmer-rendering (a higher temperature) than Daylight;
        // Tungsten far lower.
        XCTAssertLessThan(choices[2].balance.temperature, choices[0].balance.temperature)
        XCTAssertTrue(CameraWhiteBalanceChoice.choices(for: Self.presets, profile: nil).isEmpty)
        XCTAssertTrue(CameraWhiteBalanceChoice.choices(for: [], profile: profile).isEmpty)
    }

    /// On the golden raw: whatever LibRaw finds converts to usable choices.
    func testGoldenRawsPresetsConvert() throws {
        let path = TestAssets.path(TestAssets.goldenName)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "golden raw missing")
        let file = try RawFile(path: path)
        let session = try ImageSession(file: file, gpu: try GPUContext())
        print("golden raw: \(file.summary.cameraWhiteBalancePresets.count) camera white balance presets")
        XCTAssertLessThanOrEqual(session.cameraWhiteBalanceChoices.count, file.summary.cameraWhiteBalancePresets.count)
        for choice in session.cameraWhiteBalanceChoices {
            XCTAssertTrue((1500...50000).contains(choice.balance.temperature), "\(choice.title)")
        }
    }
}
