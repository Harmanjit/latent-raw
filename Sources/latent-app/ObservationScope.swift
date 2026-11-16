import SwiftUI

/// Builds `content` in a body of its own, so the `@Observable` properties
/// it reads (the editor's status, its parameters, its render report) are
/// tracked here rather than by the view that contains it. A change to
/// one of them then rebuilds this part only, not the whole enclosing view
/// and everything under it (plan fix #16).
///
/// The enclosing view rebuilding still rebuilds this (the closure is new
/// each time), so state the enclosing view owns (`@State`, its
/// `ObservableObject`s) reaches the content exactly as before.
struct ObservationScope<Content: View>: View {
    private let content: () -> Content

    init(@ViewBuilder _ content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
    }
}
