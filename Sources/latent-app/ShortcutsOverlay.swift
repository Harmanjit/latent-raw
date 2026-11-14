import SwiftUI

/// Help › Show Shortcuts Overlay (? by default): a translucent sheet over
/// the window listing the keys that work in the current mode, from the
/// keymap in effect (Settings › Keyboard included), grouped as the
/// Keyboard Shortcuts page groups them. It only shows the keys; what a key
/// does is unchanged. Esc or the same key closes it, as does a click.
struct ShortcutsOverlay: View {
    let mode: AppMode
    @ObservedObject private var settings = ViewingSettings.shared
    /// Redraws when a key is changed in Settings › Keyboard.
    @ObservedObject private var keyboard = KeyboardSettings.shared

    var body: some View {
        if settings.shortcutsOverlayShown {
            ZStack {
                Color.black.opacity(0.25)
                    .contentShape(Rectangle())
                    .onTapGesture { settings.shortcutsOverlayShown = false }
                    .accessibilityHidden(true)
                sheet
            }
            .transition(.opacity)
        }
    }

    private var sheet: some View {
        let groups = ShortcutsOverlayContent.groups(for: mode, table: keyboard.table)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(mode.title) Shortcuts").font(.title3.weight(.semibold))
                Spacer()
                Button {
                    settings.shortcutsOverlayShown = false
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close shortcuts")
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), alignment: .topLeading)],
                          alignment: .leading, spacing: 16) {
                    ForEach(groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.rows, id: \.id) { row in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(row.keys)
                                        .font(.system(.callout, design: .monospaced))
                                        .frame(minWidth: 64, alignment: .leading)
                                    Text(row.title).font(.callout)
                                    Spacer(minLength: 0)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
            }
            Text("Settings › Keyboard changes any of these. Esc or ? closes this.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: 820, maxHeight: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
        .padding(40)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(mode.title) shortcuts")
    }
}

/// What the overlay lists, apart from the view so it can be tested.
enum ShortcutsOverlayContent {
    struct Row: Equatable {
        let id: String
        let title: String
        let keys: String
    }

    struct Group: Equatable {
        let title: String
        let rows: [Row]
    }

    /// Whether a shortcut of `scope` does anything in `mode`. The Library
    /// scope is the grid and Loupe (`ShortcutScope.library`).
    static func applies(_ scope: ShortcutScope, in mode: AppMode) -> Bool {
        switch scope {
        case .everywhere: true
        case .library: mode == .library || mode == .loupe
        case .develop: mode == .develop
        case .compare: mode == .compare
        case .survey: mode == .survey
        }
    }

    /// The keys in `table` that apply in `mode`, titled and grouped as
    /// Settings › Keyboard does, groups in its order.
    static func groups(for mode: AppMode, table: [Shortcut]) -> [Group] {
        var rowsByGroup: [String: [Row]] = [:]
        for shortcut in table where applies(shortcut.scope, in: mode) {
            let info = Keymap.info(for: shortcut.command)
            let row = Row(id: info?.id ?? "\(shortcut.command)", title: info?.title ?? "\(shortcut.command)",
                          keys: shortcut.glyphs)
            rowsByGroup[info?.group ?? "Other", default: []].append(row)
        }
        let order = Keymap.groups + ["Other"]
        return order.compactMap { title in rowsByGroup[title].map { Group(title: title, rows: $0) } }
    }
}
