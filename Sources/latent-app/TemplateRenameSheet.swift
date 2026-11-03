import SwiftUI
import Catalog

/// The photos a template rename is for, in grid order, while its sheet is up.
struct TemplateRenameRequest: Identifiable {
    let id = UUID()
    let records: [ImageRecord]
}

/// The filename template editor, remembered between renames as Lightroom
/// remembers its last template and custom text.
enum RenameTemplateDefaults {
    static let templateKey = "latent.rename.template"
    static let textKey = "latent.rename.customText"
    static let startKey = "latent.rename.start"
}

/// Rename with Template: a filename template with tokens, custom text and a
/// start number, and a preview of every new name before anything moves.
/// Works for one photo or many, and the rename is one undoable step.
struct TemplateRenameSheet: View {
    let request: TemplateRenameRequest
    /// Makes the plan for the current settings (Library.renamePlan).
    let plan: (_ template: String, _ text: String, _ start: Int) -> RenamePlan
    /// Renames; problems are reported in the status bar, as a move's are.
    let onRename: (RenamePlan) async -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(RenameTemplateDefaults.templateKey) private var template = RenameTemplate.defaultTemplate
    @AppStorage(RenameTemplateDefaults.textKey) private var customText = ""
    @AppStorage(RenameTemplateDefaults.startKey) private var start = 1
    @State private var isRenaming = false

    private var current: RenamePlan { plan(template, customText, start) }
    private var unknown: [String] { RenameTemplate.unknownTokens(in: template) }
    private var usesText: Bool { template.range(of: RenameTemplate.textToken, options: .caseInsensitive) != nil }

    var body: some View {
        let plan = current
        VStack(alignment: .leading, spacing: 12) {
            Text(request.records.count == 1 ? "Rename “\(request.records[0].fileName)”"
                                            : "Rename \(request.records.count) Photos")
                .font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Template").gridColumnAlignment(.trailing)
                    TextField("Template", text: $template)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Filename template")
                        .help("Tokens in braces are filled in for each photo; anything else is used as typed. The extension is always kept.")
                }
                GridRow {
                    Text("Custom text")
                    TextField("Fills {text}", text: $customText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Custom text")
                        .help("What {text} stands for in the template, such as the name of the shoot")
                }
                GridRow {
                    Text("Start number")
                    TextField("1", value: $start, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .accessibilityLabel("Start number")
                        .help("The first {seq} number; the photos are numbered in the grid’s order")
                }
            }

            tokenButtons

            if !unknown.isEmpty {
                Text("Not a token: \(unknown.joined(separator: ", ")). Fix it or the braces stay in the names.")
                    .font(.caption).foregroundStyle(.red)
                    .accessibilityLabel("Problem: not a token: \(unknown.joined(separator: ", "))")
            } else if usesText, customText.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("The template has {text}, but no custom text is typed.")
                    .font(.caption).foregroundStyle(.orange)
            }

            preview(plan)

            HStack {
                Text(summary(plan)).font(.caption).foregroundStyle(.secondary)
                if isRenaming {
                    ProgressView().controlSize(.small).accessibilityLabel("Renaming")
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { rename(plan) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRenaming || plan.renameCount == 0 || !unknown.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    /// One button per token, adding it at the end of the template.
    private var tokenButtons: some View {
        let columns = [GridItem(.adaptive(minimum: 110), spacing: 6, alignment: .leading)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(RenameTemplate.tokens, id: \.token) { token in
                Button(token.meaning) { template += token.token }
                    .controlSize(.small)
                    .help("Add \(token.token) to the template")
                    .accessibilityLabel("Add \(token.meaning)")
            }
        }
    }

    /// The first photos' names, old and new, and what is wrong with any.
    private func preview(_ plan: RenamePlan) -> some View {
        let shown = Array(plan.items.prefix(50))
        return ScrollView {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 6, verticalSpacing: 3) {
                ForEach(shown) { item in
                    GridRow {
                        Text(item.record.fileName).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Text("→").foregroundStyle(.tertiary).accessibilityHidden(true)
                        if let problem = item.problem {
                            Text(problem).foregroundStyle(.red)
                                .lineLimit(2)
                        } else {
                            Text(item.isUnchanged ? "unchanged" : item.newName)
                                .foregroundStyle(item.isUnchanged ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                if plan.items.count > shown.count {
                    GridRow {
                        Text("and \(plan.items.count - shown.count) more").foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: min(220, CGFloat(shown.count) * 18 + 24))
        .padding(6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("New names")
    }

    private func summary(_ plan: RenamePlan) -> String {
        var parts = ["\(plan.renameCount) to rename"]
        if plan.problemCount > 0 { parts.append("\(plan.problemCount) can’t be") }
        return parts.joined(separator: ", ")
    }

    private func rename(_ plan: RenamePlan) {
        guard !isRenaming, plan.renameCount > 0 else { return }
        isRenaming = true
        Task {
            await onRename(plan)
            isRenaming = false
            dismiss()
        }
    }
}
