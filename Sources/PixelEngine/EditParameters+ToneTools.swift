import Foundation

extension EditParameters {
    /// Whether the colour kernel's master curve has anything to do: a
    /// point curve that isn't a straight line, or a moved region slider.
    public var wantsMasterCurve: Bool { !toneCurve.isIdentity || !parametricCurve.isNeutral }
}
