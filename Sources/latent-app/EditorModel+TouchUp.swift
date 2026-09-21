import CoreGraphics
import Foundation

// Touch-up in the editor (docs/Retouch.md §7): Find Faces, the region
// masks' regeneration, blemishes, and the touch-up tool's clicks.
extension EditorModel {
    /// A click with the touch-up tool armed: a ring keeps that spot, skin
    /// adds one. Nothing yet: the touch-up panel and overlay come with
    /// this extension's next commit.
    func touchUpToolBegan(at screen: CGPoint) {
    }
}
