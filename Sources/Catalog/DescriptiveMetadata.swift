import Foundation

/// The words a photographer attaches to a photo: what it is called, what it
/// shows, who made it and who owns it. Lightroom files these under IPTC;
/// Latent keeps the four that matter most for sharing a picture, on the
/// catalog row, in the sidecar as Dublin Core (`dc:title`,
/// `dc:description`, `dc:creator`, `dc:rights`, which is where Lightroom,
/// Bridge and Capture One read them) and in every export.
public enum DescriptiveField: String, CaseIterable, Sendable, Hashable {
    case title, caption, creator, copyright

    public var title: String {
        switch self {
        case .title: "Title"
        case .caption: "Caption"
        case .creator: "Creator"
        case .copyright: "Copyright"
        }
    }

    /// The value on `record`.
    public func value(of record: ImageRecord) -> String? {
        switch self {
        case .title: record.title
        case .caption: record.caption
        case .creator: record.creator
        case .copyright: record.copyright
        }
    }

    /// Sets the value on `record`, cleaned (`normalized`).
    public func set(_ value: String?, on record: inout ImageRecord) {
        let cleaned = Self.normalized(value, multiline: self == .caption)
        switch self {
        case .title: record.title = cleaned
        case .caption: record.caption = cleaned
        case .creator: record.creator = cleaned
        case .copyright: record.copyright = cleaned
        }
    }

    /// What is stored for typed text: surrounding spaces dropped, empty
    /// becomes nil. Control characters go, because XML 1.0 can't hold them
    /// and one would leave the sidecar unreadable; a caption keeps its line
    /// breaks and tabs, the one-line fields have them turned into spaces.
    public static func normalized(_ value: String?, multiline: Bool = false) -> String? {
        guard let value else { return nil }
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x0A, 0x09:
                scalars.append(multiline ? scalar : " ")
            case 0x0D:
                // A Windows line ending is one break, not two.
                continue
            case 0x00...0x1F, 0x7F, 0xFFFE, 0xFFFF:
                continue
            default:
                scalars.append(scalar)
            }
        }
        let cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The value the selection shares, for a form editing several photos at
    /// once: `.same(value)` when every one has it (nil for all empty),
    /// `.mixed` when they differ.
    public enum Shared: Equatable, Sendable {
        case same(String?)
        case mixed
    }

    public func shared(by records: [ImageRecord]) -> Shared {
        guard let first = records.first else { return .same(nil) }
        let value = self.value(of: first)
        return records.dropFirst().allSatisfy { self.value(of: $0) == value } ? .same(value) : .mixed
    }
}

extension ImageRecord {
    /// The descriptive fields as one value, for export and undo.
    public var descriptive: [DescriptiveField: String] {
        var out: [DescriptiveField: String] = [:]
        for field in DescriptiveField.allCases {
            if let value = field.value(of: self) { out[field] = value }
        }
        return out
    }
}
