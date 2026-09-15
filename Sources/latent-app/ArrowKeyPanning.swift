import Foundation

extension KeyCommand {
    /// The command an arrow key gives once `pans` says the arrows move
    /// around a zoomed-in image (Settings, Loupe and Develop only): ← and →
    /// pan instead of stepping to another image. Only the keys go through
    /// here, so Previous and Next in the menus always step; ↑ and ↓ are
    /// pan commands in the table already.
    func panningImage(_ pans: Bool) -> KeyCommand {
        guard pans, case .step(let offset) = self, abs(offset) == 1 else { return self }
        return .panImage(offset < 0 ? .left : .right)
    }
}
