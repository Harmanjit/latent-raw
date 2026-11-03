import SwiftUI
import ColorKit
import PixelEngine

/// The Profile row at the top of the Develop panel, above White Balance:
/// a menu of Latent's own profiles and the imported DCPs, an Amount slider
/// for the creative ones, and a switch for a DCP's own tone curve.
struct ProfilePicker: View {
    @ObservedObject var model: EditorModel
    /// Re-read when a profile is imported, so the menu lists it at once.
    @State private var imported: (camera: [CameraProfileLibrary.Entry], other: [CameraProfileLibrary.Entry]) = ([], [])

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Profile")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .accessibilityHidden(true)
                Spacer()
                menu
                    .frame(maxWidth: 190)
            }

            if let builtIn = model.parameters.profile?.builtIn, builtIn.hasAmount {
                amountRow(maximum: builtIn.maximumAmount)
            }

            if let entry = model.selectedImportedProfile, entry.hasToneCurve {
                Toggle("Use profile's tone curve", isOn: model.profileToneCurveBinding)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Apply this profile's own tone curve on top of Latent's tone mapping. Off keeps Latent's tone and takes only the profile's colour.")
                    .accessibilityLabel("Use profile's tone curve")
            }

            if let missing = model.missingProfileName {
                Text("\(missing) isn't on this Mac, so Latent Standard is used. Import the profile to see this edit as it was made.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!model.hasImage)
        .onAppear(perform: reload)
        .onChange(of: model.profileCameraName) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: CameraProfileLibrary.didChangeNotification)) { _ in
            reload()
        }
    }

    private var menu: some View {
        Menu {
            Section("Latent") {
                ForEach(BuiltInProfile.all.filter { $0.group == .basic }) { builtInItem($0) }
            }
            Section("Creative") {
                ForEach(BuiltInProfile.all.filter { $0.group == .creative }) { builtInItem($0) }
            }
            Section("Black & White") {
                ForEach(BuiltInProfile.all.filter { $0.group == .monochrome }) { builtInItem($0) }
            }
            Section(model.profileCameraName.map { "Camera Profiles for \($0)" } ?? "Camera Profiles") {
                if imported.camera.isEmpty {
                    Text("None imported for this camera")
                }
                ForEach(imported.camera) { importedItem($0) }
            }
            if !imported.other.isEmpty {
                Menu("Other Cameras") {
                    ForEach(imported.other) { importedItem($0) }
                }
            }
            Divider()
            Button("Import Profile…") {
                let entries = CameraProfileImport.run()
                if !entries.isEmpty {
                    model.status = entries.count == 1 ? "Imported profile \(entries[0].name)"
                        : "Imported \(entries.count) profiles"
                }
                reload()
            }
        } label: {
            Text(model.profileTitle)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .help("The profile sets the starting colour and contrast: Latent's own, a creative look, or a DNG camera profile you imported")
        .accessibilityLabel("Profile")
        .accessibilityValue(model.profileTitle)
    }

    private func builtInItem(_ profile: BuiltInProfile) -> some View {
        Toggle(profile.name, isOn: Binding(get: { model.isProfileSelected(profile.id) },
                                           set: { _ in model.chooseBuiltInProfile(profile) }))
            .help(profile.summary)
    }

    private func importedItem(_ entry: CameraProfileLibrary.Entry) -> some View {
        let title = entry.uniqueCameraModel.map { imported.other.contains(entry) ? "\(entry.name) (\($0))" : entry.name }
            ?? entry.name
        return Toggle(title, isOn: Binding(get: { model.isProfileSelected(entry.id) },
                                           set: { _ in model.chooseImportedProfile(entry) }))
    }

    private func amountRow(maximum: Float) -> some View {
        let format = SliderValueFormat(decimals: 0, unit: "%", scale: 100)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Amount").font(.subheadline).accessibilityHidden(true)
                Spacer()
                SliderValueField(value: model.profileAmountBinding, in: 0...maximum, format: format, label: "Profile amount")
            }
            ResettableSlider(value: model.profileAmountBinding, in: 0...maximum, label: "Profile amount",
                             format: format) { model.profileAmountBinding.wrappedValue = 1 }
                .help("How strongly the profile's look applies. Double-click to reset to 100%")
        }
    }

    private func reload() {
        imported = model.importedProfiles()
    }
}
