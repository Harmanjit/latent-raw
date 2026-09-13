import SwiftUI

extension View {
    /// Double-click restores a control's default. A simultaneous gesture,
    /// so the slider still takes the clicks; the reset simply lands last.
    func resetsOnDoubleClick(_ action: @escaping () -> Void) -> some View {
        simultaneousGesture(TapGesture(count: 2).onEnded(action))
    }
}
