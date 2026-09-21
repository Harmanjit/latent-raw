import CoreGraphics
import Foundation

// Sensor dust in the editor (docs/Retouch.md §6): Find Spots, the dust
// tool's clicks, the Visualise Spots view, and dust maps.
extension EditorModel {
    /// A click with the dust tool armed: a ring removes that spot, the
    /// image adds one. Nothing yet: the dust panel and overlay come with
    /// this extension's next commit.
    func dustToolBegan(at screen: CGPoint) {
    }
}
