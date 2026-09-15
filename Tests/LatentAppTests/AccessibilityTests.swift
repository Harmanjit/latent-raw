import XCTest
import AppKit
import SwiftUI
@testable import latent_app

/// VoiceOver wording, Reduce Motion and Increase Contrast rules.
@MainActor
final class AccessibilityTests: XCTestCase {
    func testStarsAndFlagsAreWords() {
        XCTAssertEqual(SpokenText.stars(0), "No rating")
        XCTAssertEqual(SpokenText.stars(1), "1 star")
        XCTAssertEqual(SpokenText.stars(4), "4 stars")
        XCTAssertEqual(SpokenText.stars(9), "5 stars", "Out-of-range ratings read as the most the cell shows")
        XCTAssertEqual(SpokenText.minimumRating(0), "Any rating")
        XCTAssertEqual(SpokenText.minimumRating(3), "3 stars or more")
        XCTAssertEqual(SpokenText.minimumRating(5), "5 stars")
        XCTAssertEqual(SpokenText.flag(1), "Picked")
        XCTAssertEqual(SpokenText.flag(-1), "Rejected")
        XCTAssertEqual(SpokenText.flag(0), "Unflagged")
    }

    func testAnImageReadsAsOneLine() {
        XCTAssertEqual(SpokenText.image(name: "a.NEF", rating: 0, flag: 0, isEdited: false), "a.NEF")
        XCTAssertEqual(SpokenText.image(name: "a.NEF", rating: 3, flag: 1, isEdited: true), "a.NEF, picked, 3 stars, edited")
        XCTAssertEqual(SpokenText.image(name: "b.NEF", rating: 1, flag: -1, isEdited: false), "b.NEF, rejected, 1 star")
        // The grid cell and the filmstrip say the same thing.
        XCTAssertEqual(ThumbnailCellView.accessibilityText(name: "b.NEF", rating: 1, flag: -1, isEdited: false),
                       "b.NEF, rejected, 1 star")
    }

    func testGridCellIsOneSelectableImage() {
        let cell = ThumbnailCellView(frame: NSRect(x: 0, y: 0, width: 176, height: 210))
        cell.setMarks(name: "c.NEF", rating: 5, flag: 1, isEdited: false)
        XCTAssertTrue(cell.isAccessibilityElement())
        XCTAssertEqual(cell.accessibilityRole(), .image)
        XCTAssertEqual(cell.accessibilityLabel(), "c.NEF, picked, 5 stars")
        XCTAssertFalse(cell.isAccessibilitySelected())
        cell.selectionStyle = .selected
        XCTAssertTrue(cell.isAccessibilitySelected())
        // The name and badge text are part of the cell, not read on their own.
        XCTAssertTrue(cell.subviews.allSatisfy { !$0.isAccessibilityElement() })
    }

    func testCaptionReadsExposureAsPauses() {
        XCTAssertEqual(SpokenText.caption(title: "Candidate", name: "d.NEF", exposure: "1/250 s · f/4 · ISO 200",
                                          rating: 2, flag: 1),
                       "Candidate, d.NEF, 1/250 s, f/4, ISO 200, picked, 2 stars")
        XCTAssertEqual(SpokenText.caption(title: nil, name: "d.NEF", exposure: "", rating: 0, flag: 0), "d.NEF")
        XCTAssertEqual(SpokenText.caption(title: "Select", name: nil, exposure: "", rating: 0, flag: 0),
                       "Select, nothing selected")
    }

    func testReadouts() {
        XCTAssertEqual(SpokenText.zoom("Fit"), "Fit")
        XCTAssertEqual(SpokenText.zoom("150%"), "150 percent")
        XCTAssertEqual(SpokenText.zoom(""), "")

        XCTAssertEqual(SpokenText.healPatches(count: 0, selected: nil), "No patches")
        XCTAssertEqual(SpokenText.healPatches(count: 1, selected: nil), "1 patch")
        XCTAssertEqual(SpokenText.healPatches(count: 3, selected: 1), "3 patches, patch 2 selected")
        XCTAssertEqual(SpokenText.healPatches(count: 3, selected: 7), "3 patches", "A stale index isn't read")

        XCTAssertEqual(SpokenText.crop(width: 6016, height: 4016, aspect: "3:2", angle: 0),
                       "6016 by 4016 pixels, aspect 3:2")
        XCTAssertEqual(SpokenText.crop(width: 100, height: 100, aspect: "1:1", angle: -1.5),
                       "100 by 100 pixels, aspect 1:1, straightened -1.5 degrees")
        XCTAssertEqual(SpokenText.crop(width: 100, height: 100, aspect: "Free", angle: 12),
                       "100 by 100 pixels, aspect Free, straightened 12 degrees")
    }

    func testHistogramSpeaksWhereThePixelsAre() {
        XCTAssertEqual(SpokenText.histogram(luminance: []), "No data")
        XCTAssertEqual(SpokenText.histogram(luminance: [0, 0, 0, 0]), "No data")
        // 8 bins: two per quarter. 25 in the shadows, 50 in the middle, 25 up top.
        XCTAssertEqual(SpokenText.histogram(luminance: [20, 5, 10, 15, 20, 5, 0, 25]),
                       "shadows 25 percent, midtones 50 percent, highlights 25 percent")
        XCTAssertEqual(SpokenText.histogram(luminance: [0, 0, 0, 0, 0, 0, 0, 9]),
                       "shadows 0 percent, midtones 0 percent, highlights 100 percent")
    }

    func testScaledSliderValuesReadAsShown() {
        // HSL and split toning show -1...1 as -100...100.
        XCTAssertEqual(SliderValueFormat(decimals: 0, signed: true, scale: 100).text(0.25), "+25")
        XCTAssertEqual(SliderValueFormat(decimals: 0, scale: 100).text(0.92), "92")
        XCTAssertEqual(SliderValueFormat(printf: "%+.2f").text(-0.5), "-0.50")
    }

    func testReduceMotionDropsAnimation() {
        XCTAssertNil(Motion.animation(.easeInOut, reduced: true))
        XCTAssertNotNil(Motion.animation(.easeInOut, reduced: false))
        XCTAssertNil(Motion.animation(nil, reduced: false))
        XCTAssertEqual(Motion.scrollDuration(0.2, reduced: true), 0)
        XCTAssertEqual(Motion.scrollDuration(0.2, reduced: false), 0.2)
    }

    func testIncreaseContrastOutlinesOnlyTheSelection() {
        XCTAssertEqual(Contrast.selectionOutlineWidth(selected: true, increased: true), 2)
        XCTAssertEqual(Contrast.selectionOutlineWidth(selected: false, increased: true), 0)
        XCTAssertEqual(Contrast.selectionOutlineWidth(selected: true, increased: false), 0)
    }
}
