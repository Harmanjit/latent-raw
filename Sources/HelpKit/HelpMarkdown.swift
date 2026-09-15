import Foundation

/// One block of a help page: a heading, a paragraph, a list item's
/// paragraph, a code block, a note or a table, with its inline styling
/// (bold, italic, code, links) kept in the attributed text.
public struct HelpBlock: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case heading(level: Int)
        case paragraph
        /// A paragraph inside a list, `depth` lists deep (1 for a top-level
        /// list). `marker` is "•" or "3." on an item's first paragraph and
        /// nil on the ones after it.
        case listItem(depth: Int, marker: String?)
        case code
        /// A paragraph inside a block quote: shown as a note.
        case note
        /// Rows of cells; `text` is empty.
        case table(HelpTable)
    }

    /// The parser's identity for the block, unique within a page.
    public let id: Int
    public let kind: Kind
    public let text: AttributedString

    public init(id: Int, kind: Kind, text: AttributedString) {
        self.id = id
        self.kind = kind
        self.text = text
    }

    /// What search looks through: the text, or a table's cells.
    public var plainText: String {
        if case .table(let table) = kind { return table.plainText }
        return String(text.characters)
    }

    /// The heading's link target, as GitHub names it (`Page#anchor`).
    public var anchor: String? {
        guard case .heading = kind else { return nil }
        return HelpMarkdown.anchor(forHeading: plainText)
    }
}

/// A Markdown table. Rows always have one cell per column: the parser
/// leaves empty cells out, so they are filled in here.
public struct HelpTable: Equatable, Sendable {
    public let columnCount: Int
    /// Empty when the table's header row has no text, as a table used only
    /// for layout (`| | |`) has.
    public private(set) var header: [AttributedString]
    public private(set) var rows: [[AttributedString]] = []

    init(columnCount: Int) {
        self.columnCount = columnCount
        header = []
    }

    public var plainText: String {
        ([header] + rows)
            .filter { !$0.isEmpty }
            .map { $0.map { String($0.characters) }.joined(separator: "\t") }
            .joined(separator: "\n")
    }

    mutating func startRow() {
        rows.append(Array(repeating: AttributedString(), count: columnCount))
    }

    /// Appends to a cell: a cell with a link or code in it arrives in
    /// several runs.
    mutating func append(_ text: AttributedString, column: Int, inHeader: Bool) {
        guard column >= 0, column < columnCount else { return }
        if inHeader {
            if header.isEmpty { header = Array(repeating: AttributedString(), count: columnCount) }
            header[column] += text
        } else {
            if rows.isEmpty { startRow() }
            rows[rows.count - 1][column] += text
        }
    }
}

/// Turns Markdown into `HelpBlock`s.
///
/// `AttributedString(markdown:)` with full syntax parses the block structure
/// but leaves it as `presentationIntent` attributes: SwiftUI's `Text` would
/// run every paragraph, heading and list item together. So the runs are
/// grouped by their block here, and the Help window lays each block out.
public enum HelpMarkdown {
    public static func blocks(from markdown: String) throws -> [HelpBlock] {
        let document = try AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible))
        var blocks: [HelpBlock] = []
        var itemsWithMarker = Set<Int>()
        var lastTableRow: Int?
        for (intent, range) in document.runs[\.presentationIntent] {
            guard let intent else { continue }
            var text = AttributedString(document[range])
            text.presentationIntent = nil

            if let cell = TableCellPosition(intent) {
                var table: HelpTable
                if let last = blocks.last, last.id == cell.table, case .table(let existing) = last.kind {
                    table = existing
                    blocks.removeLast()
                } else {
                    table = HelpTable(columnCount: cell.columnCount)
                    lastTableRow = nil
                }
                if !cell.inHeader, cell.row != lastTableRow { table.startRow() }
                if !cell.inHeader { lastTableRow = cell.row }
                table.append(text, column: cell.column, inHeader: cell.inHeader)
                blocks.append(HelpBlock(id: cell.table, kind: .table(table), text: AttributedString()))
                continue
            }

            guard let kind = kind(of: intent, itemsWithMarker: &itemsWithMarker) else { continue }
            if kind == .code {
                // A code block's text ends with its closing newline.
                while text.characters.last == "\n" { text.characters.removeLast() }
            }
            let id = intent.components.first?.identity ?? blocks.count
            // Runs of one block split by an attribute the grouping didn't
            // see (a link, bold) are joined back into the block.
            if let last = blocks.last, last.kind == kind, last.id == id {
                blocks[blocks.count - 1] = HelpBlock(id: id, kind: kind, text: last.text + text)
                continue
            }
            blocks.append(HelpBlock(id: id, kind: kind, text: text))
        }
        return blocks
    }

    /// GitHub's anchor for a heading: lower case, punctuation other than
    /// hyphens and underscores dropped, spaces as hyphens. Wiki links use
    /// it as `Page#anchor`.
    public static func anchor(forHeading heading: String) -> String {
        var anchor = ""
        for character in heading.lowercased() {
            if character == " " {
                anchor.append("-")
            } else if character.isLetter || character.isNumber || character == "-" || character == "_" {
                anchor.append(character)
            }
        }
        return anchor
    }

    /// Components run from the innermost block outwards.
    private static func kind(of intent: PresentationIntent, itemsWithMarker: inout Set<Int>) -> HelpBlock.Kind? {
        var base: HelpBlock.Kind = .paragraph
        var depth = 0
        var item: (identity: Int, ordinal: Int)?
        var innermostListIsOrdered: Bool?
        var quoted = false
        for component in intent.components {
            switch component.kind {
            case .header(let level): base = .heading(level: level)
            case .codeBlock: base = .code
            case .thematicBreak: return nil
            case .blockQuote: quoted = true
            case .listItem(let ordinal):
                if item == nil { item = (component.identity, ordinal) }
            case .orderedList, .unorderedList:
                depth += 1
                if innermostListIsOrdered == nil { innermostListIsOrdered = component.kind == .orderedList }
            default: break
            }
        }
        if base != .paragraph { return base }
        if let item {
            let isFirst = itemsWithMarker.insert(item.identity).inserted
            let marker = innermostListIsOrdered == true ? "\(item.ordinal)." : "•"
            return .listItem(depth: depth, marker: isFirst ? marker : nil)
        }
        return quoted ? .note : .paragraph
    }
}

/// Where a run sits in a table, read from its presentation intent.
private struct TableCellPosition {
    let table: Int
    let columnCount: Int
    let row: Int
    let inHeader: Bool
    let column: Int

    init?(_ intent: PresentationIntent) {
        var table: (identity: Int, columns: Int)?
        var row: (identity: Int, header: Bool)?
        var column: Int?
        for component in intent.components {
            switch component.kind {
            case .table(let columns): table = (component.identity, columns.count)
            case .tableHeaderRow: row = (component.identity, true)
            case .tableRow: row = (component.identity, false)
            case .tableCell(let index): column = index
            default: break
            }
        }
        guard let table, let row, let column else { return nil }
        self.table = table.identity
        columnCount = table.columns
        self.row = row.identity
        inHeader = row.header
        self.column = column
    }
}
