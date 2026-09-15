import SwiftUI
import AppKit
import Catalog

/// How Finder tags look in the app: coloured dots, as Finder draws them,
/// and the words VoiceOver says for them.
extension FinderTag {
    /// The dot colour; nil for a tag without one, which is drawn hollow.
    var nsColor: NSColor? {
        switch colorIndex {
        case 1: .systemGray
        case 2: .systemGreen
        case 3: .systemPurple
        case 4: .systemBlue
        case 5: .systemYellow
        case 6: .systemRed
        case 7: .systemOrange
        default: nil
        }
    }

    /// A small dot for menus, which show images but not SwiftUI shapes.
    @MainActor
    func dotImage(diameter: CGFloat = 10) -> NSImage {
        let color = nsColor
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            if let color {
                color.setFill()
                dot.fill()
            } else {
                NSColor.secondaryLabelColor.setStroke()
                dot.lineWidth = 1
                dot.stroke()
            }
            return true
        }
        image.accessibilityDescription = name
        return image
    }
}

extension SpokenText {
    /// "tagged Red, Work", or nothing for no tags.
    static func finderTags(_ tags: [FinderTag]) -> String {
        tags.isEmpty ? "" : "tagged " + tags.map(\.name).joined(separator: ", ")
    }
}

/// A file's tags as dots and names, for the Library panel: "● Red  ○ Work".
/// One Text, so a long list wraps like a sentence.
struct FinderTagList: View {
    let tags: [FinderTag]

    var body: some View {
        tags.enumerated().reduce(Text("")) { text, entry in
            let (index, tag) = entry
            let dot = Text(tag.nsColor == nil ? "○" : "●")
                .foregroundStyle(tag.nsColor.map { Color(nsColor: $0) } ?? Color.secondary)
            return text + Text(index == 0 ? "" : "   ") + dot + Text(" " + tag.name)
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Finder tags")
        .accessibilityValue(tags.map(\.name).joined(separator: ", "))
        .help("Tags set in Finder. Latent reads them when the folder is opened or refreshed.")
    }
}

/// The filter bar's tag picker: Any, or one of the folder's tags.
struct FinderTagFilterMenu: View {
    @Binding var selection: String?
    let tags: [FinderTag]

    var body: some View {
        Menu {
            Button("Any") { selection = nil }
            if !tags.isEmpty { Divider() }
            ForEach(tags, id: \.name) { tag in
                Toggle(isOn: Binding(get: { selection == tag.name },
                                     set: { selection = $0 ? tag.name : nil })) {
                    Label {
                        Text(tag.name)
                    } icon: {
                        Image(nsImage: tag.dotImage())
                    }
                }
            }
        } label: {
            Text(selection ?? "Tag")
                .lineLimit(1)
                .frame(maxWidth: 120)
        }
        .disabled(tags.isEmpty && selection == nil)
        .help("Show only images with this Finder tag")
        .accessibilityLabel("Finder tag")
        .accessibilityValue(selection ?? "Any")
    }
}
