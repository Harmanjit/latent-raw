import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Settings › Keyboard: every command's keys, which the user can change
/// (click the keys, press new ones), take away or reset, and save to or
/// load from a keymap file. The defaults stay in `Shortcuts.all`; changes
/// live in `Keymap`, which the menu bar and BareKeyMonitor read.
struct KeyboardSettingsTab: View {
    @ObservedObject private var settings = KeyboardSettings.shared
    @StateObject private var recorder = KeyRecorder()
    @State private var search = ""
    @State private var prompt: Prompt?

    /// An alert: a problem to explain, or keys to reassign.
    struct Prompt: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        var confirmTitle: String?
        var confirm: (() -> Void)?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search commands or keys", text: $search)
                .textFieldStyle(.roundedBorder)
            List {
                ForEach(Keymap.groups, id: \.self) { group in
                    let rows = matching(in: group)
                    if !rows.isEmpty {
                        Section(group) {
                            ForEach(rows, id: \.id) { row($0) }
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            Text("Click a command's keys, then press the new combination (Esc cancels). Single keys work anywhere but a text field; combinations with ⌘, ⌥ or ⌃ go on the command's menu item.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Import Keymap…", action: importKeymap)
                Button("Export Keymap…", action: exportKeymap)
                    .disabled(!settings.hasCustomisations)
                Spacer()
                Button("Reset All") {
                    prompt = Prompt(title: "Reset every shortcut to its default?",
                                    message: "Every change made here is lost.",
                                    confirmTitle: "Reset All") { settings.resetAll() }
                }
                .disabled(!settings.hasCustomisations)
            }
        }
        .frame(minHeight: 600)
        .onDisappear { recorder.stop() }
        .alert(item: $prompt) { prompt in
            if let confirm = prompt.confirm {
                Alert(title: Text(prompt.title), message: Text(prompt.message),
                      primaryButton: .default(Text(prompt.confirmTitle ?? "OK"), action: confirm),
                      secondaryButton: .cancel())
            } else {
                Alert(title: Text(prompt.title), message: Text(prompt.message))
            }
        }
    }

    private func matching(in group: String) -> [ShortcutCommandInfo] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return Keymap.commands.filter { info in
            guard info.group == group else { return false }
            guard !query.isEmpty else { return true }
            let glyphs = settings.shortcut(for: info)?.glyphs.lowercased() ?? ""
            return info.title.lowercased().contains(query) || glyphs.contains(query)
        }
    }

    private func row(_ info: ShortcutCommandInfo) -> some View {
        let shortcut = settings.shortcut(for: info)
        let isRecording = recorder.recordingID == info.id
        let customised = settings.isCustomised(info)
        return HStack(spacing: 6) {
            Text(info.title)
                .fontWeight(customised ? .semibold : .regular)
            if let clash = settings.clash(for: info) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("\(clash.title) has the same keys; only one of them will get them.")
                    .accessibilityLabel("Same keys as \(clash.title)")
            }
            Spacer()
            Button {
                isRecording ? recorder.stop() : record(info)
            } label: {
                Text(isRecording ? "Type keys…" : shortcut?.glyphs ?? "None")
                    .monospaced(!isRecording && shortcut != nil)
                    .foregroundStyle(shortcut == nil && !isRecording ? .secondary : .primary)
                    .frame(minWidth: 90)
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .accentColor : nil)
            .help(info.singleKeyOnly ? "Click, then press a single key (this command has no menu item)" : "Click, then press the new keys")
            .accessibilityLabel(isRecording ? "Recording keys for \(info.title)"
                                : "\(info.title): \(shortcut?.glyphs ?? "no keys")")
            Button { settings.removeKeys(from: info) } label: { Image(systemName: "delete.left") }
                .buttonStyle(.borderless)
                .disabled(shortcut == nil)
                .help("Remove the keys")
                .accessibilityLabel("Remove the keys for \(info.title)")
            Button { reset(info) } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.borderless)
                .disabled(!customised)
                .help("Reset to the default (\(Shortcuts.defaultShortcut(for: info.command)?.glyphs ?? "none"))")
                .accessibilityLabel("Reset \(info.title) to its default")
        }
    }

    private func record(_ info: ShortcutCommandInfo) {
        recorder.start(id: info.id) { key, modifiers in
            switch settings.problem(giving: key, modifiers, to: info) {
            case nil:
                settings.assign(key, modifiers, to: info)
            case .needsSingleKey?:
                prompt = Prompt(title: "\(info.title) takes a single key",
                                message: "It has no menu item to carry a combination with ⌘, ⌥ or ⌃. Choose a key on its own, or with ⇧.")
            case .system(let title)?:
                prompt = Prompt(title: "\(Shortcuts.glyphs(key, modifiers)) belongs to \(title)",
                                message: "macOS or a standard menu item keeps these keys. Choose others.")
            case .taken(let holder)?:
                let glyphs = Shortcuts.glyphs(key, modifiers)
                prompt = Prompt(title: "\(glyphs) is already used by \(holder.title)",
                                message: "Give \(glyphs) to \(info.title) instead? \(holder.title) is left without keys.",
                                confirmTitle: "Reassign") {
                    settings.assign(key, modifiers, to: info, takingFrom: holder)
                }
            }
        }
    }

    private func reset(_ info: ShortcutCommandInfo) {
        guard case .taken(let holder)? = settings.resetProblem(for: info) else {
            settings.reset(info)
            return
        }
        let glyphs = Shortcuts.defaultShortcut(for: info.command)?.glyphs ?? ""
        prompt = Prompt(title: "\(glyphs) is now used by \(holder.title)",
                        message: "Reset \(info.title) to \(glyphs) anyway? \(holder.title) is left without keys.",
                        confirmTitle: "Reset") {
            settings.reset(info, takingFrom: holder)
        }
    }

    private func exportKeymap() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Latent Keymap.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try settings.exportData().write(to: url, options: .atomic)
        } catch {
            prompt = Prompt(title: "The keymap couldn't be saved", message: error.localizedDescription)
        }
    }

    private func importKeymap() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try settings.importData(Data(contentsOf: url))
        } catch {
            prompt = Prompt(title: "The keymap couldn't be imported", message: error.localizedDescription)
        }
    }
}

/// Catches the next key-down in the app while a command's keys are being
/// recorded, so neither the menu bar nor the window acts on it.
@MainActor
final class KeyRecorder: ObservableObject {
    @Published private(set) var recordingID: String?
    private var monitor: Any?

    func start(id: String, onKeys: @escaping @MainActor (BareKeyPress.Key, ShortcutModifiers) -> Void) {
        stop()
        recordingID = id
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.take(event, onKeys) ?? false }
            return consumed ? nil : event
        }
    }

    /// Whether the event was the recording's; a key the table can't hold
    /// beeps and recording goes on.
    private func take(_ event: NSEvent, _ onKeys: @MainActor (BareKeyPress.Key, ShortcutModifiers) -> Void) -> Bool {
        guard recordingID != nil else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 && flags.isDisjoint(with: [.command, .option, .control, .shift]) {
            stop()   // Esc on its own cancels
            return true
        }
        guard let characters = event.charactersIgnoringModifiers,
              let recorded = Keymap.recordedKeys(
                charactersIgnoringModifiers: characters, shift: flags.contains(.shift),
                command: flags.contains(.command), option: flags.contains(.option),
                control: flags.contains(.control)) else {
            NSSound.beep()
            return true
        }
        stop()
        onKeys(recorded.0, recorded.1)
        return true
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingID = nil
    }
}
