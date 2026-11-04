import XCTest
@testable import PixelEngine

/// Copy, Sync and Paste Settings' Upright and Transform choices
/// (TransformCopyGroups.swift).
final class TransformCopyGroupsTests: XCTestCase {
    private let matrix: [Float] = [1, 0.02, 0, -0.01, 1, 0, 0, 0.03, 1]

    private func source() -> EditStack {
        var p = EditParameters()
        p.crop = CropParameters(centre: [0.5, 0.5], size: [0.8, 0.8], angle: 2)
        p.perspective = PerspectiveCorrection(vertical: 0.2, horizontal: -0.1)
        p.perspective.rotate = 1.5
        p.perspective.flipHorizontal = true
        p.perspective.upright = UprightCorrection(mode: .vertical, matrix: matrix)
        p.perspective.constrainCrop = true
        return EditStack(parameters: p)
    }

    private func target() -> EditStack {
        var p = EditParameters()
        p.perspective.scale = 1.2
        p.perspective.upright = UprightCorrection(mode: .level, matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1.0])
        return EditStack(parameters: p)
    }

    func testUprightModeLeavesTheMatrixBehind() {
        let merged = target().merged(with: source(), groups: [.uprightMode])
        let p = merged.modules.perspective
        XCTAssertEqual(p?.upright?.mode, .vertical)
        XCTAssertNil(p?.upright?.matrix, "analysed again on the photo it lands on")
        XCTAssertEqual(p?.scale, 1.2, "the target's sliders stay")
        XCTAssertNil(p?.constrainCrop)
        XCTAssertNil(merged.modules.crop)
        XCTAssertTrue(source().restricted(to: [.uprightMode]).wantsUprightAnalysis(groups: [.uprightMode]))
    }

    func testUprightTransformsCopyTheExactCorrection() {
        let p = target().merged(with: source(), groups: [.uprightMode, .uprightTransforms]).modules.perspective
        XCTAssertEqual(p?.upright?.matrix, matrix)
        XCTAssertEqual(p?.scale, 1.2)
        XCTAssertFalse(source().wantsUprightAnalysis(groups: [.uprightMode, .uprightTransforms]))
        // A clipboard copied with Upright Mode alone has no matrix to give.
        let clipboard = source().restricted(to: [.uprightMode])
        XCTAssertTrue(clipboard.wantsUprightAnalysis(groups: [.uprightTransforms]))
    }

    func testSlidersAndConstrainCropTravelOnTheirOwn() {
        let sliders = target().merged(with: source(), groups: [.transformSliders]).modules.perspective
        XCTAssertEqual(sliders?.vertical, 0.2)
        XCTAssertEqual(sliders?.rotate, 1.5)
        XCTAssertNil(sliders?.scale, "the source's default scale replaces the target's")
        XCTAssertEqual(sliders?.flipHorizontal, true)
        XCTAssertEqual(sliders?.upright?.mode, .level, "the target's own Upright stays")
        XCTAssertNil(sliders?.constrainCrop)

        let constrain = target().merged(with: source(), groups: [.constrainCrop]).modules.perspective
        XCTAssertEqual(constrain?.constrainCrop, true)
        XCTAssertEqual(constrain?.scale, 1.2)

        // Sliders onto a photo with none; "no Upright" pasted clears it.
        let pasted = EditStack(parameters: EditParameters()).merged(with: target(), groups: [.transformSliders])
        XCTAssertEqual(pasted.modules.perspective?.scale, 1.2)
        XCTAssertNil(pasted.modules.perspective?.upright)
        XCTAssertNil(target().restricted(to: [.uprightMode]).merged(
            with: EditStack(), groups: [.uprightMode]).modules.perspective)
    }

    func testCropAloneNoLongerCarriesTheTransform() {
        let merged = target().merged(with: source(), groups: [.crop])
        XCTAssertEqual(merged.modules.crop, source().modules.crop)
        XCTAssertEqual(merged.modules.perspective, target().modules.perspective)
    }

    /// A set saved before the split (Crop meaning the whole transform)
    /// still copies what it did, exactly.
    func testLegacyCropGroupStillCarriesEverything() {
        let upgraded = EditGroup.upgradingLegacy([.crop, .tone])
        XCTAssertEqual(upgraded, [.crop, .tone, .uprightTransforms, .transformSliders, .constrainCrop])
        XCTAssertEqual(EditGroup.upgradingLegacy([.crop, .uprightMode]), [.crop, .uprightMode], "already split")
        XCTAssertEqual(EditGroup.upgradingLegacy([.tone]), [.tone])
        let merged = target().merged(with: source(), groups: upgraded)
        XCTAssertEqual(merged.modules.perspective, source().modules.perspective)
        XCTAssertEqual(merged.modules.crop, source().modules.crop)
    }

    func testPresentGroups() {
        let groups = source().presentGroups
        XCTAssertTrue(groups.isSuperset(of: [.crop, .uprightMode, .uprightTransforms, .transformSliders, .constrainCrop]))
        var p = EditParameters()
        p.perspective.upright = UprightCorrection(mode: .auto)
        XCTAssertEqual(EditStack(parameters: p).presentGroups.intersection(EditGroup.transformGroups),
                       [.uprightMode, .uprightTransforms])
    }

    /// Guided Upright's guides were drawn by hand: they travel whole.
    func testGuidedTravelsWhole() {
        var p = EditParameters()
        p.perspective.upright = UprightCorrection(mode: .guided, matrix: matrix,
                                                  guides: [UprightGuide(x0: 0, y0: -0.5, x1: 0.02, y1: 0.5)])
        let guided = EditStack(parameters: p)
        let merged = EditStack().merged(with: guided, groups: [.uprightMode])
        XCTAssertEqual(merged.modules.perspective?.upright, p.perspective.upright)
        XCTAssertFalse(guided.wantsUprightAnalysis(groups: [.uprightMode]))
    }

    /// A preset from before the split decodes with the transform groups;
    /// one saved now keeps exactly its groups.
    func testPresetGroupsUpgradeOnce() throws {
        let legacy = #"{"name":"Old","groups":["crop","tone"],"stack":{"schema":1,"process":"1.0","modules":{}},"isBuiltIn":false}"#
        let old = try JSONDecoder().decode(Preset.self, from: Data(legacy.utf8))
        XCTAssertEqual(old.groups, [.crop, .tone, .uprightTransforms, .transformSliders, .constrainCrop])

        let now = Preset(name: "New", groups: [.crop, .uprightMode], stack: source())
        let back = try JSONDecoder().decode(Preset.self, from: JSONEncoder().encode(now))
        XCTAssertEqual(back.groups, [.crop, .uprightMode])
        XCTAssertEqual(back, now)
    }
}
