import SwiftUI
import AppKit
import Combine
import Catalog

/// The sidebar's Recently Added row: the photos the latest scan that found
/// anything new added to the open folder (Lightroom's Previous Import).
/// Choosing it narrows the grid to them; choosing it again, or Clear
/// Filters, shows everything.
struct RecentlyAddedRow: View {
    @ObservedObject var library: Library

    var body: some View {
        if library.folderURL != nil {
            let showing = library.isShowingRecentlyAdded
            let count = library.recentlyAdded?.ids.count ?? 0
            Button {
                library.showRecentlyAdded(!showing)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 18)
                    Text("Recently Added")
                    Spacer(minLength: 4)
                    if count > 0 {
                        Text("\(count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .background(showing ? Color.accentColor.opacity(0.2) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .disabled(count == 0 && !showing)
            .help(Self.help(library.recentlyAdded, showing: showing))
            .accessibilityLabel("Recently Added")
            .accessibilityValue(count == 1 ? "1 photo" : "\(count) photos")
            .accessibilityAddTraits(showing ? .isSelected : [])
        }
    }

    static func help(_ batch: RecentlyAdded?, showing: Bool) -> String {
        guard let batch else {
            return "The photos found new the next time this folder is scanned show here: copied in, imported from a watched folder, or there when the folder was first opened."
        }
        let when = batch.date.formatted(date: .abbreviated, time: .shortened)
        let what = batch.ids.count == 1 ? "The photo" : "The \(batch.ids.count) photos"
        return showing
            ? "Showing only \(what.lowercased()) added on \(when). Click to show every photo again (or Clear Filters)."
            : "\(what) found new on \(when). Click to show only them; the filter bar still applies."
    }
}

/// A free-space meter for each disk that holds a favourite or the open
/// folder, read off the main thread when the sidebar appears, when a disk
/// comes or goes, and every minute while it shows.
struct VolumeSpaceList: View {
    @ObservedObject var favourites: FavouriteFolders
    let currentFolder: URL?
    @State private var volumes: [VolumeSpace] = []
    /// One timer for the life of the app, not one per redraw.
    @MainActor private static let minute = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var folders: [URL] {
        favourites.folders.filter(\.isAvailable).map(\.url) + (currentFolder.map { [$0] } ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !volumes.isEmpty {
                Text("Volumes")
                    .font(.system(size: NSFont.smallSystemFontSize, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(volumes) { VolumeSpaceRow(volume: $0) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, volumes.isEmpty ? 0 : 8)
        .task(id: folders.map(\.path)) { await reload() }
        .onReceive(Self.minute) { _ in
            Task { await reload() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            Task { await reload() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            Task { await reload() }
        }
    }

    private func reload() async {
        let folders = folders
        let found = await Task.detached(priority: .utility) { VolumeSpace.volumes(for: folders) }.value
        if found != volumes { volumes = found }
    }
}

private struct VolumeSpaceRow: View {
    let volume: VolumeSpace

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: volume.url.path == "/" ? "internaldrive" : "externaldrive")
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(volume.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProgressView(value: volume.usedFraction)
                    .progressViewStyle(.linear)
                    .tint(volume.isLow ? .orange : .accentColor)
                    .controlSize(.small)
                Text(volume.summary)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(volume.isLow ? Color.orange : Color.secondary)
            }
        }
        .help("\(volume.name): \(volume.summary)\(volume.isLow ? ". Running low: imports and exports to this disk may not fit." : ".")")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(volume.name) disk")
        .accessibilityValue("\(volume.summary), \(Int((volume.usedFraction * 100).rounded())) percent used\(volume.isLow ? ", running low" : "")")
    }
}

/// Add Parent Folder…: the open panel shows the favourite's parent, and
/// choosing it (the sandbox's way of granting access to it) puts it in
/// the favourite's place, with the favourite inside its tree.
@MainActor
func chooseParent(of favourite: URL, favourites: FavouriteFolders) {
    let parent = favourite.standardizedFileURL.deletingLastPathComponent()
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = parent
    panel.prompt = "Add Parent"
    panel.message = "Click Add Parent to show “\(parent.lastPathComponent)” in Favourites, with “\(favourite.lastPathComponent)” inside it."
    guard panel.runModal() == .OK, let chosen = panel.url else { return }
    if !favourites.addParent(chosen) {
        MainWindowModels.shared.model.lastError = "“\(chosen.lastPathComponent)” couldn’t be added to Favourites."
    }
}
