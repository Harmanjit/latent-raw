import Foundation

/// How full a disk is, for the sidebar's free-space meters: one per volume
/// that holds a favourite folder or the open folder.
public struct VolumeSpace: Equatable, Sendable, Identifiable {
    /// The volume's mount point.
    public var url: URL
    public var name: String
    public var totalBytes: Int64
    /// What macOS would make room for an important file: purgeable space
    /// (caches, iCloud copies it can drop) counted in, as Finder counts it.
    public var availableBytes: Int64

    public var id: String { url.standardizedFileURL.path }

    public init(url: URL, name: String, totalBytes: Int64, availableBytes: Int64) {
        self.url = url
        self.name = name
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }

    /// 0 empty … 1 full.
    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(totalBytes - availableBytes) / Double(totalBytes), 0), 1)
    }

    /// Low enough to warn: under 10% or under 5 GB free, roughly a few
    /// cards of raw files.
    public var isLow: Bool {
        totalBytes > 0 && (Double(availableBytes) / Double(totalBytes) < 0.10 || availableBytes < 5_000_000_000)
    }

    /// "182 GB free of 1 TB".
    public var summary: String {
        let style = ByteCountFormatter.CountStyle.file
        return "\(ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: style)) free of "
            + ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: style)
    }

    /// The volumes `folders` live on, each once, in the order first met.
    /// Reads the file system: call off the main thread, since a share that
    /// has stopped answering blocks until it times out. A folder that can't
    /// be asked (its disk gone) is left out.
    public static func volumes(for folders: [URL]) -> [VolumeSpace] {
        var seen = Set<String>()
        var result: [VolumeSpace] = []
        let keys: Set<URLResourceKey> = [.volumeURLKey, .volumeNameKey, .volumeLocalizedNameKey,
                                         .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        for folder in folders {
            guard let values = try? folder.resourceValues(forKeys: keys), let volume = values.volume,
                  let total = values.volumeTotalCapacity, total > 0 else { continue }
            guard seen.insert(volume.standardizedFileURL.path).inserted else { continue }
            let important = values.volumeAvailableCapacityForImportantUsage.map { Int64($0) } ?? 0
            let plain = values.volumeAvailableCapacity.map { Int64($0) } ?? 0
            result.append(VolumeSpace(url: volume,
                                      name: values.volumeLocalizedName ?? values.volumeName ?? volume.lastPathComponent,
                                      totalBytes: Int64(total), availableBytes: max(important, plain)))
        }
        return result
    }
}
