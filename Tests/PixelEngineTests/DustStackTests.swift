import XCTest
import simd
@testable import PixelEngine
@testable import RawCore

/// The sensor-dust module in the edit stack (docs/Retouch.md §3, §6):
/// absent when empty, capped and sanitised on the way in, moved like a
/// heal on a bordered camera; plus the detector's pure maths and the
/// dust-map store.
final class DustStackTests: XCTestCase {
    private func spot(_ x: Float, _ y: Float, radius: Float = 0.002) -> HealPatch {
        HealPatch(target: [x, y], source: [x + 0.006, y], radius: radius, feather: 0.5, mode: .heal)
    }

    // MARK: - Stack

    func testNeutralEncodesNothingAndUntouchedStacksAreUnchanged() throws {
        XCTAssertNil(EditStack(parameters: EditParameters()).modules.dust)
        var p = EditParameters()
        p.exposureEV = 0.7
        p.heals = [HealPatch(target: [0.2, 0.3], source: [0.4, 0.5], radius: 0.02)]
        let json = try EditStack(parameters: p).encodeJSON()
        XCTAssertFalse(json.contains("dust"))
        XCTAssertFalse(json.contains("touchup"))
        // A sidecar written before the module existed reads and writes
        // back byte for byte.
        let legacy = #"{"frame":"active-area","modules":{"exposure":{"ev":0.5},"heal":[{"feather":0.5,"id":"7A1C0000-0000-0000-0000-000000000001","mode":"clone","radius":0.02,"source":[0.4,0.5],"target":[0.2,0.3]}]},"process":"1.0","schema":1}"#
        XCTAssertEqual(try EditStack.decode(json: legacy).encodeJSON(), legacy)
        XCTAssertEqual(EditParameters().dust, [])
        XCTAssertEqual(EditParameters().allHealPatches, [])
    }

    func testRoundTripAndGroup() throws {
        var p = EditParameters()
        p.dust = [spot(0.412, 0.087), spot(0.7, 0.2, radius: 0.003)]
        let stack = EditStack(parameters: p)
        XCTAssertEqual(stack.modules.dust, p.dust)
        XCTAssertEqual(stack.frame, EditStack.activeAreaFrame, "dust is geometry")
        let json = try stack.encodeJSON()
        XCTAssertTrue(json.contains("\"dust\""))
        let back = try EditStack.decode(json: json)
        XCTAssertEqual(back.parameters().dust, p.dust)
        XCTAssertEqual(back, stack)
        XCTAssertNotEqual(p, EditParameters(), "dust counts in ==")

        XCTAssertTrue(stack.presentGroups.contains(.dust))
        XCTAssertFalse(EditGroup.lookGroups.contains(.dust))
        XCTAssertEqual(EditGroup.dust.displayName, "Sensor Dust")
        XCTAssertNil(stack.restricted(to: EditGroup.lookGroups).modules.dust)
        XCTAssertEqual(EditStack().merged(with: stack, groups: [.dust]).modules.dust, p.dust)
        XCTAssertNil(stack.merged(with: EditStack(), groups: [.dust]).modules.dust, "pasting no dust clears it")
        XCTAssertEqual(EditHistory.describeChange(from: EditStack(parameters: EditParameters()), to: stack), "Sensor Dust")
        XCTAssertFalse(EditStack.isDefault(p, relativeTo: EditParameters()))
    }

    func testCapsAndSanitising() throws {
        var stack = EditStack()
        stack.modules.dust = (0..<250).map { i in spot(Float(i) / 250, 0.5) }
        XCTAssertEqual(stack.parameters().dust.count, HealPatch.maximumDustCount)
        XCTAssertEqual(stack.parameters().dust.first?.target.x, 0)
        // A spot that isn't a number is dropped; one off the sensor is
        // pulled back within a frame of it.
        stack.modules.dust = [HealPatch(target: [.nan, 0.5], source: [0.5, 0.5], radius: 0.002),
                              HealPatch(target: [5, 0.5], source: [0.5, 0.5], radius: 3)]
        let dust = stack.parameters().dust
        XCTAssertEqual(dust.count, 1)
        XCTAssertEqual(dust[0].target.x, HealPatch.coordinateRange.upperBound)
        XCTAssertEqual(dust[0].radius, 0.5)
    }

    func testStageListIsDustThenBlemishesThenHeals() {
        var p = EditParameters()
        p.dust = [spot(0.1, 0.1)]
        p.heals = [HealPatch(target: [0.5, 0.5], source: [0.6, 0.6], radius: 0.03)]
        p.touchUp.blemishes = [spot(0.45, 0.27, radius: 0.0018)]
        XCTAssertEqual(p.allHealPatches, p.dust + p.heals, "blemishes only with Remove Blemishes on")
        p.touchUp.blemishRemoval = true
        XCTAssertEqual(p.allHealPatches, p.dust + p.touchUp.blemishes + p.heals)
    }

    /// A dust list saved against the whole readout moves onto the active
    /// area exactly as a heal patch does.
    func testMigrationMovesDustLikeAHeal() throws {
        let canon = SensorActiveArea(left: 146, top: 48, width: 6742, height: 4498, fullWidth: 6888, fullHeight: 4546)
        var old = EditStack()
        old.modules.dust = [spot(0.3, 0.4)]
        old.modules.heal = [spot(0.3, 0.4)]
        XCTAssertNil(old.frame)
        let new = old.migratingGeometry(to: canon)
        XCTAssertEqual(new.frame, EditStack.activeAreaFrame)
        let dust = try XCTUnwrap(new.modules.dust?.first), heal = try XCTUnwrap(new.modules.heal?.first)
        XCTAssertEqual(dust.target, heal.target)
        XCTAssertEqual(dust.source, heal.source)
        XCTAssertEqual(dust.radius, heal.radius)
        XCTAssertNotEqual(dust.target, old.modules.dust?.first?.target, "it moved")
        XCTAssertEqual(new.migratingGeometry(to: canon), new, "once only")
    }

    // MARK: - Detector maths

    func testExpectedRadiusFollowsTheAperture() throws {
        // A full-frame D750: 5.97 µm pitch.
        let f11 = try XCTUnwrap(DustDetector.expectedRadius(aperture: 11, cropFactor: 1, rawWidth: 6032))
        XCTAssertEqual(f11, 11.4, accuracy: 0.1)
        let f22 = try XCTUnwrap(DustDetector.expectedRadius(aperture: 22, cropFactor: 1, rawWidth: 6032))
        XCTAssertEqual(f22, f11 / 2, accuracy: 0.05)
        // APS-C at the same pixel count has a finer pitch, so a bigger shadow in pixels.
        let crop = try XCTUnwrap(DustDetector.expectedRadius(aperture: 11, cropFactor: 1.5, rawWidth: 6032))
        XCTAssertEqual(crop, f11 * 1.5, accuracy: 0.05)
        // Clamped to the bands' reach.
        XCTAssertEqual(DustDetector.expectedRadius(aperture: 1.4, cropFactor: 1, rawWidth: 6032), 40)
        XCTAssertEqual(DustDetector.expectedRadius(aperture: 64, cropFactor: 1, rawWidth: 1000), 2)
        // A crop factor under 1 (medium format) counts as 1.
        XCTAssertEqual(DustDetector.expectedRadius(aperture: 11, cropFactor: 0.7, rawWidth: 6032), f11)
        XCTAssertNil(DustDetector.expectedRadius(aperture: 0, cropFactor: 1, rawWidth: 6032))
        XCTAssertNil(DustDetector.expectedRadius(aperture: 11, cropFactor: 0, rawWidth: 6032))
        XCTAssertNil(DustDetector.expectedRadius(aperture: .nan, cropFactor: 1, rawWidth: 6032))
    }

    func testBlobParametersNarrowTheBandAndMapTheSensitivity() {
        XCTAssertEqual(DustSpotSize.small.sensorRadiusRange, 4...8)
        XCTAssertEqual(DustSpotSize.medium.sensorRadiusRange, 6...16)
        XCTAssertEqual(DustSpotSize.large.sensorRadiusRange, 12...40)
        XCTAssertEqual(DustSpotSize.allCases.map(\.displayName), ["Small", "Medium", "Large"])

        let plain = DustDetector.blobParameters(options: .init(), expectedRadius: nil, binSpan: 2)
        XCTAssertEqual(plain.radiusRange, 3...8, "medium band in map pixels")
        XCTAssertEqual(plain.polarity, .dark)
        XCTAssertEqual(plain.contrastSigma, 4, accuracy: 1e-6)
        XCTAssertEqual(plain.minimumContrast, 0.05, accuracy: 1e-6)
        XCTAssertEqual(plain.minimumCircularity, 0.575, accuracy: 1e-6)
        XCTAssertEqual(plain.smoothSurround ?? 0, 3, accuracy: 1e-6)
        XCTAssertEqual(plain.maximumSurroundGradient, 0.01)
        XCTAssertEqual(plain.maximumCount, HealPatch.maximumDustCount)

        // Sensitivity 0 and 100 are the ends of each mapping.
        let strict = DustDetector.blobParameters(options: .init(sensitivity: 0), expectedRadius: nil, binSpan: 2)
        XCTAssertEqual(strict.contrastSigma, 6, accuracy: 1e-6)
        XCTAssertEqual(strict.minimumContrast, 0.08, accuracy: 1e-6)
        XCTAssertEqual(strict.minimumCircularity, 0.65, accuracy: 1e-6)
        XCTAssertEqual(strict.smoothSurround ?? 0, 2.5, accuracy: 1e-6)
        let loose = DustDetector.blobParameters(options: .init(sensitivity: 100), expectedRadius: nil, binSpan: 2)
        XCTAssertEqual(loose.contrastSigma, 2, accuracy: 1e-6)
        XCTAssertEqual(loose.minimumContrast, 0.02, accuracy: 1e-6)
        XCTAssertEqual(loose.minimumCircularity, 0.5, accuracy: 1e-6)
        XCTAssertEqual(loose.smoothSurround ?? 0, 3.5, accuracy: 1e-6)
        XCTAssertEqual(DustDetector.blobParameters(options: .init(sensitivity: 400), expectedRadius: nil, binSpan: 2)
                           .contrastSigma, 2, accuracy: 1e-6, "clamped")

        // An expected radius of 10 sensor px narrows Large 12…40 to 12…25.
        let large = DustDetector.blobParameters(options: .init(size: .large), expectedRadius: 10, binSpan: 2)
        XCTAssertEqual(large.radiusRange, 6...12.5)
        // An expected 3 px shadow narrows Small 4…8 to 4…7.5, which is
        // 2…3.75 on the map; a 1 px one would ask for 4…2.5 and keeps the band.
        let small = DustDetector.blobParameters(options: .init(size: .small), expectedRadius: 3, binSpan: 2)
        XCTAssertEqual(small.radiusRange, 2...3.75)
        XCTAssertEqual(DustDetector.blobParameters(options: .init(size: .small), expectedRadius: 1, binSpan: 2).radiusRange, 2...4)
        // A radius outside the band leaves the band as chosen.
        let outside = DustDetector.blobParameters(options: .init(size: .small), expectedRadius: 40, binSpan: 2)
        XCTAssertEqual(outside.radiusRange, 2...4)
        // At full resolution the band is in sensor pixels.
        XCTAssertEqual(DustDetector.blobParameters(options: .init(), expectedRadius: nil, binSpan: 1).radiusRange, 6...16)
    }

    func testAnalysisParametersKeepOnlyWhiteBalanceAndDemosaic() {
        var p = EditParameters()
        p.whiteBalance = .init(temperature: 4200, tint: 3)
        p.demosaic = .bilinear
        p.exposureEV = 2; p.denoiseLuminance = 0.5; p.aiDenoise = 1
        p.heals = [spot(0.5, 0.5)]; p.dust = [spot(0.1, 0.1)]
        p.locals = [LocalAdjustment(name: "x", shape: .whole, exposureEV: -1)]
        let a = DustDetector.analysisParameters(p)
        var expected = EditParameters()
        expected.whiteBalance = p.whiteBalance
        expected.demosaic = .bilinear
        XCTAssertEqual(a, expected)
    }

    // MARK: - Dust maps

    private func map(_ camera: String, created: Date, spots: Int, id: UUID = UUID()) -> DustMap {
        DustMap(id: id, camera: camera, sensorSize: SIMD2(6032, 4032), created: created, referenceName: "DSC_0001.NEF",
                referenceCaptureDate: nil, aperture: 16, options: .init(sensitivity: 60, size: .large),
                spots: (0..<spots).map { DustMapSpot(centre: [Float($0) / 100, 0.5], radius: 0.002, contrast: 0.1) })
    }

    func testTitleNamesCameraDateAndCount() {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 12; components.hour = 12
        let date = Calendar(identifier: .gregorian).date(from: components)!
        XCTAssertEqual(map("Nikon D750", created: date, spots: 41).title, "Nikon D750 · 12 Sep 2026 · 41 spots")
        XCTAssertEqual(map("Nikon D750", created: date, spots: 1).title, "Nikon D750 · 12 Sep 2026 · 1 spot")
        var reference = map("Canon EOS R5", created: date, spots: 0)
        reference.referenceCaptureDate = Calendar(identifier: .gregorian).date(byAdding: .day, value: -30, to: date)
        XCTAssertEqual(reference.title, "Canon EOS R5 · 13 Aug 2026 · 0 spots", "the reference photo's date when known")
    }

    func testStoreRoundTripsNewestFirstAndReadsGarbageAsEmpty() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-dust-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("dust-maps.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = DustMapStore(url: url)
        XCTAssertEqual(store.load(), [], "no file yet")

        let older = map("Nikon D750", created: Date(timeIntervalSince1970: 1_700_000_000), spots: 3)
        let newer = map("Nikon D750", created: Date(timeIntervalSince1970: 1_800_000_000), spots: 5)
        let other = map("Canon EOS R5", created: Date(timeIntervalSince1970: 1_750_000_000), spots: 2)
        try store.add(older)
        try store.add(other)
        try store.add(newer)
        XCTAssertEqual(store.load().count, 3)
        XCTAssertEqual(store.maps(forCamera: "Nikon D750").map(\.id), [newer.id, older.id])
        XCTAssertEqual(store.maps(forCamera: "Canon EOS R5"), [other])
        XCTAssertEqual(store.maps(forCamera: "Sony ILCE-7M4"), [])
        // Every field survives the file, dates to the second.
        let back = try XCTUnwrap(store.load().first { $0.id == newer.id })
        XCTAssertEqual(back.spots, newer.spots)
        XCTAssertEqual(back.options, newer.options)
        XCTAssertEqual(back.sensorSize, newer.sensorSize)
        XCTAssertEqual(back.aperture, 16)
        XCTAssertEqual(back.created.timeIntervalSince1970, newer.created.timeIntervalSince1970, accuracy: 1)

        // Adding a map again replaces it; deleting removes it.
        var renamed = newer
        renamed.referenceName = "DSC_0002.NEF"
        try store.add(renamed)
        XCTAssertEqual(store.load().count, 3)
        XCTAssertEqual(store.load().first { $0.id == newer.id }?.referenceName, "DSC_0002.NEF")
        try store.delete(id: older.id)
        XCTAssertEqual(store.maps(forCamera: "Nikon D750").map(\.id), [newer.id])

        // The file is versioned, and an unreadable one reads as empty.
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"version\" : 1"))
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(store.load(), [])
        XCTAssertTrue(DustMapStore.defaultURL.path.hasSuffix("latent/dust-maps.json"))
    }
}
