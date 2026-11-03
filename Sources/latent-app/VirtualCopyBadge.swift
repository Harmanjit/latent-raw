import AppKit

/// The mark on a virtual copy's thumbnail: two stacked squares in a small
/// dark chip at the picture's bottom-left corner, where Lightroom puts its
/// page curl. The cell's name ("DSC_0107 (Copy 2).NEF") says it too, and is
/// what VoiceOver reads, so the chip itself stays out of the accessibility
/// tree.
final class VirtualCopyBadgeView: NSView {
    static let side: CGFloat = 16
    static let inset: CGFloat = 3

    private let symbol = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 3
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        symbol.image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        symbol.contentTintColor = .white
        symbol.imageScaling = .scaleProportionallyDown
        addSubview(symbol)
        setAccessibilityElement(false)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        symbol.frame = bounds.insetBy(dx: 2, dy: 2)
    }

    /// Clicks go to the cell beneath, as they do on the picture.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Its frame in a flipped cell: the bottom-left corner of the picture.
    static func frame(inImageFrame image: CGRect) -> CGRect {
        CGRect(x: image.minX + inset, y: image.maxY - inset - side, width: side, height: side)
    }
}
