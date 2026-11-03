import XCTest
import PixelEngine
import ColorKit
@testable import latent_app

/// The Profile picker's model side: choosing, the Amount, undo, and an
/// edit that names a DCP this Mac doesn't have.
@MainActor
final class ProfilePickerTests: XCTestCase {
    func testChoosingAProfileIsAnUndoableEdit() async throws {
        let url = try TestAssets.d750URL()
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.open(url: url, catalogImageID: 1)
        XCTAssertTrue(model.hasImage)
        XCTAssertEqual(model.profileTitle, "Latent Standard")
        XCTAssertTrue(model.isProfileSelected(BuiltInProfile.standardID))

        let vivid = try XCTUnwrap(BuiltInProfile.named("latent:vivid"))
        model.chooseBuiltInProfile(vivid)
        model.flushPendingSave()
        XCTAssertEqual(model.parameters.profile?.id, "latent:vivid")
        XCTAssertEqual(model.profileTitle, "Vivid")

        model.profileAmountBinding.wrappedValue = 1.5
        model.flushPendingSave()
        XCTAssertEqual(model.parameters.profile?.effectiveAmount, 1.5)
        // Choosing the profile already in use keeps its Amount.
        model.chooseBuiltInProfile(vivid)
        XCTAssertEqual(model.parameters.profile?.effectiveAmount, 1.5)

        model.undo()
        XCTAssertEqual(model.parameters.profile?.effectiveAmount, 1)
        model.undo()
        XCTAssertNil(model.parameters.profile, "back to Latent Standard")
        model.redo()
        XCTAssertEqual(model.parameters.profile?.id, "latent:vivid")

        // Standard is stored as no profile at all.
        model.chooseBuiltInProfile(.standard)
        XCTAssertNil(model.parameters.profile)
    }

    func testAMissingDCPIsNamed() async throws {
        let url = try TestAssets.d750URL()
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.open(url: url, catalogImageID: 1)
        model.parameters.profile = ProfileChoice(id: "dcp:Somebody Else's.dcp", name: "Somebody Else's")
        XCTAssertEqual(model.missingProfileName, "Somebody Else's")
        XCTAssertEqual(model.profileTitle, "Somebody Else's")
        model.parameters.profile = ProfileChoice(id: "latent:mono", name: "Monochrome")
        XCTAssertNil(model.missingProfileName)
    }
}
