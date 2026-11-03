import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ColorKit
import PixelEngine

extension EditorModel {
    // MARK: - Profiles

    /// The profile the open image renders with, for the picker. Standard
    /// when the edit has none.
    var profileTitle: String {
        guard let choice = parameters.profile else { return BuiltInProfile.standard.name }
        return choice.name
    }

    func isProfileSelected(_ id: String) -> Bool {
        (parameters.profile?.id ?? BuiltInProfile.standardID) == id
    }

    /// Switches profile. The Amount goes back to 100% and a DCP's tone
    /// curve starts off, as for a fresh choice in any editor; choosing the
    /// profile already in use changes nothing.
    func chooseProfile(_ choice: ProfileChoice?) {
        let next = choice?.sanitized
        guard next?.id != parameters.profile?.id else { return }
        parameters.profile = next
    }

    func chooseBuiltInProfile(_ profile: BuiltInProfile) {
        chooseProfile(ProfileChoice.builtIn(profile))
    }

    func chooseImportedProfile(_ entry: CameraProfileLibrary.Entry) {
        chooseProfile(ProfileChoice(id: entry.id, name: entry.name))
    }

    /// The built-in profile in use, if it is one.
    var selectedBuiltInProfile: BuiltInProfile {
        parameters.profile?.builtIn ?? .standard
    }

    /// The Amount slider's value, 0...maximum (1 is 100%).
    var profileAmountBinding: Binding<Float> {
        Binding(get: { self.parameters.profile?.effectiveAmount ?? 1 },
                set: { amount in
                    guard var choice = self.parameters.profile else { return }
                    choice.amount = amount
                    self.parameters.profile = choice.sanitized
                })
    }

    var profileToneCurveBinding: Binding<Bool> {
        Binding(get: { self.parameters.profile?.toneCurve == true },
                set: { on in
                    guard var choice = self.parameters.profile, choice.isDCP else { return }
                    choice.toneCurve = on
                    self.parameters.profile = choice.sanitized
                })
    }

    /// The DCP the edit asks for, if it is in the library.
    var selectedImportedProfile: CameraProfileLibrary.Entry? {
        guard let choice = parameters.profile, choice.isDCP else { return nil }
        return CameraProfileLibrary.shared.entry(id: choice.id)
    }

    /// Set when the edit names a DCP this Mac doesn't have: the image then
    /// renders with Latent Standard, and the panel says so.
    var missingProfileName: String? {
        guard let choice = parameters.profile, choice.isDCP, selectedImportedProfile == nil else { return nil }
        return choice.name
    }

    /// "Nikon D750", the camera DCPs are matched against.
    var profileCameraName: String? {
        guard let summary = session?.file.summary else { return nil }
        let name = [summary.cameraMake, summary.cameraModel].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    /// Imported profiles split into those made for this camera and the rest.
    func importedProfiles() -> (camera: [CameraProfileLibrary.Entry], other: [CameraProfileLibrary.Entry]) {
        let all = CameraProfileLibrary.shared.entries()
        guard let summary = session?.file.summary else { return ([], all) }
        let mine = all.filter {
            CameraProfileLibrary.matches(uniqueCameraModel: $0.uniqueCameraModel,
                                         cameraMake: summary.cameraMake, cameraModel: summary.cameraModel)
        }
        let mineIDs = Set(mine.map(\.id))
        return (mine, all.filter { !mineIDs.contains($0.id) })
    }
}

/// Develop › Import Camera Profile… and the picker's Import Profile…:
/// copies .dcp files the user chooses into Latent's profile folder.
@MainActor
enum CameraProfileImport {
    /// Shows an open panel and imports what's chosen. Returns the entries
    /// imported, and reports files that aren't profiles in one alert.
    @discardableResult
    static func run() -> [CameraProfileLibrary.Entry] {
        let panel = NSOpenPanel()
        panel.title = "Import Camera Profile"
        panel.message = "Choose DNG camera profiles (.dcp). Latent keeps a copy in its own folder."
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if let dcp = UTType(filenameExtension: "dcp") { panel.allowedContentTypes = [dcp] }
        guard panel.runModal() == .OK else { return [] }
        return importFiles(panel.urls)
    }

    static func importFiles(_ urls: [URL]) -> [CameraProfileLibrary.Entry] {
        var imported: [CameraProfileLibrary.Entry] = []
        var failures: [String] = []
        for url in urls {
            do {
                imported.append(try CameraProfileLibrary.shared.importProfile(from: url))
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = failures.count == 1 ? "A profile couldn't be imported" : "Some profiles couldn't be imported"
            alert.informativeText = failures.joined(separator: "\n")
            alert.runModal()
        }
        return imported
    }
}
