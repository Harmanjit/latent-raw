import XCTest
import AppKit
import SwiftUI
@testable import latent_app

/// When a slider's number field applies its text: the rules alone, then the
/// real field in a window.
@MainActor
final class SliderValueFieldTests: XCTestCase {
    // MARK: Rules

    func testUntypedTextIsNeverApplied() {
        var editing = NumberFieldEditing(shown: "+0.00")
        XCTAssertNil(editing.ended(text: "+0.00", cancelled: false), "Clicking in and out applies nothing")
        // The slider moved while the field had the keyboard.
        XCTAssertEqual(editing.update(text: "+1.00", subject: [], isEditing: true), .show("+1.00"))
        XCTAssertNil(editing.ended(text: "+0.00", cancelled: false),
                     "Stale text left in the field isn't written back over the slider")
    }

    func testTypedTextIsAppliedWhenEditingEnds() {
        var editing = NumberFieldEditing(shown: "+0.00")
        editing.typed()
        XCTAssertEqual(editing.update(text: "+0.00", subject: [], isEditing: true), .keep)
        XCTAssertEqual(editing.ended(text: "1.5", cancelled: false), "1.5")
        XCTAssertFalse(editing.isDirty)
        XCTAssertNil(editing.ended(text: "1.5", cancelled: false), "Applied once")
    }

    func testEscapeAppliesNothing() {
        var editing = NumberFieldEditing(shown: "+0.00")
        editing.typed()
        XCTAssertNil(editing.ended(text: "1.5", cancelled: true))
    }

    func testValueChangingUnderTypingAbandonsIt() {
        var editing = NumberFieldEditing(shown: "+0.00")
        editing.typed()
        XCTAssertEqual(editing.update(text: "+1.00", subject: [], isEditing: true), .abandon)
        XCTAssertEqual(editing.update(text: "+2.00", subject: [], isEditing: true), .keep, "Abandoned once")
        editing.typed()
        XCTAssertNil(editing.ended(text: "1.5", cancelled: false))
        XCTAssertEqual(editing.update(text: "+2.00", subject: [], isEditing: false), .show("+2.00"))
        XCTAssertFalse(editing.isAbandoned)
    }

    func testAnotherPhotoAbandonsEditingEvenAtTheSameValue() {
        let first = URL(fileURLWithPath: "/a.nef"), second = URL(fileURLWithPath: "/b.nef")
        var editing = NumberFieldEditing(shown: "+0.00")
        XCTAssertEqual(editing.update(text: "+0.00", subject: [first], isEditing: false), .show("+0.00"))
        editing.typed()
        XCTAssertEqual(editing.update(text: "+0.00", subject: [second], isEditing: true), .abandon)
        XCTAssertNil(editing.ended(text: "1.5", cancelled: false))
    }

    func testArrowKeysResetTheTypedState() {
        var editing = NumberFieldEditing(shown: "+0.00")
        editing.typed()
        editing.stepped(to: "+0.01")
        XCTAssertEqual(editing.update(text: "+0.01", subject: [], isEditing: true), .keep,
                       "The value the arrows set isn't a change under the field")
        XCTAssertNil(editing.ended(text: "+0.01", cancelled: false))
    }

    func testRowRemovedMidEditAppliesNothing() {
        var editing = NumberFieldEditing(shown: "+0.00")
        editing.typed()
        editing.abandon()
        XCTAssertNil(editing.ended(text: "1.5", cancelled: false))
    }

    // MARK: The field in a window

    private final class Model: ObservableObject {
        @Published var value: Float = 0
        @Published var photo = "a"
    }

    private struct Host: View {
        @ObservedObject var model: Model
        var body: some View {
            SliderValueField(value: $model.value, in: -5...5, format: SliderValueFormat(printf: "%+.2f"))
                .sliderFieldSubject(model.photo)
                .frame(width: 80, height: 20)
        }
    }

    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    private func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = textField(in: subview) { return field }
        }
        return nil
    }

    private func makeWindow(_ model: Model) throws -> (NSWindow, NSTextField) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Host(model: model))
        window.contentView?.layoutSubtreeIfNeeded()
        settle()
        let field = try XCTUnwrap(window.contentView.flatMap(textField(in:)))
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertNotNil(field.currentEditor())
        return (window, field)
    }

    func testFieldFollowsTheSliderWhileFocused() throws {
        let model = Model()
        let (window, field) = try makeWindow(model)
        model.value = 1
        settle()
        XCTAssertEqual(field.currentEditor()?.string, "+1.00")
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertEqual(model.value, 1, "Focus leaving the field doesn't put the old number back")
        XCTAssertEqual(field.stringValue, "+1.00")
    }

    func testTypedValueApplies() throws {
        let model = Model()
        let (window, field) = try makeWindow(model)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("2.5", replacementRange: editor.selectedRange())
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertEqual(model.value, 2.5)
    }

    func testOpeningAnotherPhotoEndsTypingWithoutApplyingIt() throws {
        let model = Model()
        let (window, field) = try makeWindow(model)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("2.5", replacementRange: editor.selectedRange())
        model.photo = "b"
        settle()
        XCTAssertNil(field.currentEditor(), "Editing ended")
        window.makeFirstResponder(nil)
        XCTAssertEqual(model.value, 0, "The number typed for one photo didn't land on the next")
        XCTAssertEqual(field.stringValue, "+0.00")
    }
}
