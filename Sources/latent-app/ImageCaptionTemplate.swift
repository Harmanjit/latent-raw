import SwiftUI
import Catalog

/// Settings › Library's info line: what the caption under the image in
/// Loupe, Compare and Survey says, as a template in the export naming
/// language (ExportNaming, modifiers included), and whether it sits above
/// or below the image. The default template gives the caption as it has
/// always been: the file name, then the exposure.
enum ImageCaptionTemplate {
    static let templateKey = "latent.caption.template"
    static let positionKey = "latent.caption.position"
    /// The caption as it always was; while this is the template, the
    /// caption is drawn exactly as before.
    static let defaultTemplate = "{file}  {exposure}"

    enum Position: String, CaseIterable, Identifiable {
        case bottom, top
        var id: String { rawValue }
        var title: String { self == .top ? "Above the image" : "Below the image" }
    }

    /// The caption's own tokens, beyond the naming ones.
    static let tokens: [(token: String, meaning: String)] = [
        ("{file}", "file name with extension"), ("{exposure}", "shutter · aperture · ISO · focal length"),
    ]

    static func isStandard(_ template: String) -> Bool {
        let trimmed = template.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed == defaultTemplate
    }

    /// The template filled in for `record`.
    static func text(_ template: String, for record: ImageRecord) -> String {
        let marks = [("{file}", "\u{E020}", record.fileName), ("{exposure}", "\u{E021}", record.exposureLine)]
        var marked = template
        for (token, mark, _) in marks {
            marked = marked.replacingOccurrences(of: token, with: mark, options: .caseInsensitive)
        }
        var text = ExportNaming.text(template: marked, record: record, context: ExportNaming.Context(index: 0))
        for (_, mark, value) in marks { text = text.replacingOccurrences(of: mark, with: value) }
        return text
    }

    /// Tokens the template doesn't know, as the naming sheets report them.
    static func unknownTokens(in template: String) -> [String] {
        var marked = template
        for (token, _) in tokens { marked = marked.replacingOccurrences(of: token, with: "", options: .caseInsensitive) }
        return ExportNaming.unknownTokens(in: marked)
    }
}

/// An image pane with its caption above or below it, as Settings › Library
/// says. Below unless changed, as it always was.
struct CaptionedPane<Content: View>: View {
    var showsCaption = true
    let caption: ImageCaption
    @ViewBuilder let content: Content
    @AppStorage(ImageCaptionTemplate.positionKey) private var position = ImageCaptionTemplate.Position.bottom.rawValue

    var body: some View {
        let top = position == ImageCaptionTemplate.Position.top.rawValue
        VStack(spacing: 0) {
            if showsCaption, top {
                caption
                Divider()
            }
            content
            if showsCaption, !top {
                Divider()
                caption
            }
        }
    }
}

/// Settings › Library's Info Line and Metadata rows.
struct LibraryInfoSettings: View {
    @AppStorage(ImageCaptionTemplate.templateKey) private var template = ImageCaptionTemplate.defaultTemplate
    @AppStorage(ImageCaptionTemplate.positionKey) private var position = ImageCaptionTemplate.Position.bottom.rawValue
    @AppStorage(MetadataRow.hiddenKey) private var hiddenRows = ""

    var body: some View {
        Section("Info line") {
            HStack {
                TextField("Caption", text: $template, prompt: Text(ImageCaptionTemplate.defaultTemplate))
                    .accessibilityLabel("Caption template")
                    .help("What the line under the image in Loupe and Compare says. Tokens in braces are filled in for the photo; the stars and flag stay at the right.")
                Menu("Insert") {
                    ForEach(ImageCaptionTemplate.tokens + ExportNaming.tokens.filter { $0.token != "{seq}" },
                            id: \.token) { t in
                        Button("\(t.token)  \(t.meaning)") { template += t.token }
                    }
                }
                .fixedSize()
                .accessibilityLabel("Insert a caption token")
                Button("Reset") { template = ImageCaptionTemplate.defaultTemplate }
                    .disabled(template == ImageCaptionTemplate.defaultTemplate)
            }
            let unknown = ImageCaptionTemplate.unknownTokens(in: template)
            if !unknown.isEmpty {
                Text("Not a token: \(unknown.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.red)
            }
            Picker("Position", selection: $position) {
                ForEach(ImageCaptionTemplate.Position.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
        }
        Section("Metadata rows") {
            let hidden = MetadataRow.hidden(from: hiddenRows)
            ForEach(MetadataRow.allLabels, id: \.self) { label in
                Toggle(label, isOn: Binding(
                    get: { !hidden.contains(label) },
                    set: { shown in
                        var next = MetadataRow.hidden(from: hiddenRows)
                        if shown { next.remove(label) } else { next.insert(label) }
                        hiddenRows = MetadataRow.stored(next)
                    }))
            }
            Text("The rows the Library panel’s Metadata section shows when a photo has the value.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
