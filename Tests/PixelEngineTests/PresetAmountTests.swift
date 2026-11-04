import XCTest
import ColorKit
@testable import PixelEngine

/// A preset's Amount: sliders blend from the photo's values, everything
/// else is taken whole, and 100% is exactly the old paste.
final class PresetAmountTests: XCTestCase {
    private func preset() -> EditStack {
        var p = EditParameters()
        p.exposureEV = 1
        p.contrast = 2
        p.vibrance = 0.4
        p.splitToning = SplitToning(shadowHue: 215, shadowSaturation: 0.2, highlightHue: 45, highlightSaturation: 0.1, balance: 0)
        p.colour.blackAndWhite = BlackAndWhite(enabled: true)
        return EditStack(parameters: p)
    }

    private let groups: Set<EditGroup> = [.tone, .colour, .splitToning]

    func testFullAmountIsTheMerge() {
        let base = EditStack(parameters: EditParameters())
        XCTAssertEqual(base.applying(preset(), groups: groups, amount: 1), base.merged(with: preset(), groups: groups))
    }

    func testHalfBlendsSlidersAndTakesTheRestWhole() {
        let base = EditStack(parameters: EditParameters())
        let p = base.applying(preset(), groups: groups, amount: 0.5).parameters()
        XCTAssertEqual(p.exposureEV, 0.5, accuracy: 1e-6)
        XCTAssertEqual(p.contrast, 1.75, accuracy: 1e-6)
        XCTAssertEqual(p.vibrance, 0.2, accuracy: 1e-6)
        XCTAssertEqual(p.splitToning.shadowSaturation, 0.1, accuracy: 1e-6)
        XCTAssertEqual(p.splitToning.shadowHue, 215)
        XCTAssertTrue(p.colour.blackAndWhite.enabled)
    }

    func testZeroLeavesTheLookAndDoubleIsClamped() {
        var start = EditParameters(); start.exposureEV = 4
        let base = EditStack(parameters: start)
        XCTAssertEqual(base.applying(preset(), groups: groups, amount: 0).parameters().exposureEV, 4)
        let doubled = base.applying(preset(), groups: groups, amount: 2).parameters()
        XCTAssertEqual(doubled.exposureEV, -2, accuracy: 1e-6)   // 4 + 2 × (1 − 4)
        XCTAssertEqual(doubled.contrast, 2.5, accuracy: 1e-6)
        XCTAssertEqual(doubled.vibrance, 0.8, accuracy: 1e-6)
        var far = EditParameters(); far.exposureEV = -4
        XCTAssertEqual(EditStack(parameters: far).applying(EditStack(parameters: { var q = EditParameters(); q.exposureEV = 4; return q }()),
                                                            groups: [.tone], amount: 2).parameters().exposureEV, 5)
    }

    func testGeometryAndUnchosenGroupsAreUntouched() {
        var start = EditParameters()
        start.crop = CropParameters(centre: [0.5, 0.5], size: [0.5, 0.5], angle: 0, aspect: nil)
        start.sharpenAmount = 0.7
        let base = EditStack(parameters: start)
        let out = base.applying(preset(), groups: groups, amount: 0.3)
        XCTAssertEqual(out.modules.crop, base.modules.crop)
        XCTAssertEqual(out.frame, base.frame)
        XCTAssertEqual(out.modules.sharpen, base.modules.sharpen)
    }

    func testWhiteBalanceBlendsOnlyBetweenConcreteSettings() {
        var warm = EditParameters(); warm.whiteBalance = .init(temperature: 7000, tint: 10)
        var cool = EditParameters(); cool.whiteBalance = .init(temperature: 5000, tint: 0)
        let mixed = warm.blended(from: cool, amount: 0.5)
        XCTAssertEqual(mixed.whiteBalance.temperature, 6000, accuracy: 1e-3)
        XCTAssertEqual(mixed.whiteBalance.tint, 5, accuracy: 1e-3)
        let fromAsShot = warm.blended(from: EditParameters(), amount: 0.5)
        XCTAssertEqual(fromAsShot.whiteBalance, warm.whiteBalance)
    }
}
