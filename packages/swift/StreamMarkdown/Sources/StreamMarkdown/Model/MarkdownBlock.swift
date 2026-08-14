import Foundation

/// Column alignment in a GFM table.
public enum ColumnAlignment: Sendable, Equatable {
    case leading
    case center
    case trailing
    case none
}

/// An ordered-list item with its rendered number.
public struct OrderedListItem: Sendable, Equatable {
    public let number: Int
    public let text: String

    public init(number: Int, text: String) {
        self.number = number
        self.text = text
    }
}

/// A top-level markdown block produced by `MarkdownParser`.
///
/// Inline spans (emphasis, code, links) are preserved as raw markdown strings
/// and rendered to `AttributedString` at display time, so partially streamed
/// inline syntax degrades gracefully.
public indirect enum MarkdownBlock: Sendable, Equatable, Identifiable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case codeBlock(language: String?, code: String, isComplete: Bool)
    case bulletList([String])
    case orderedList([OrderedListItem])
    case blockQuote([MarkdownBlock])
    case table(headers: [String], alignments: [ColumnAlignment], rows: [[String]])
    case thematicBreak

    /// A stable identity for use in SwiftUI `ForEach`. Indices are supplied by
    /// the renderer; the case content disambiguates re-parsed blocks.
    public var id: String {
        switch self {
        case let .heading(level, text): return "h\(level):\(text)"
        case let .paragraph(text): return "p:\(text)"
        case let .codeBlock(language, code, complete): return "code:\(language ?? ""):\(complete):\(code)"
        case let .bulletList(items): return "ul:\(items.joined(separator: "\u{1}"))"
        case let .orderedList(items): return "ol:\(items.map { "\($0.number).\($0.text)" }.joined(separator: "\u{1}"))"
        case let .blockQuote(blocks): return "quote:\(blocks.map(\.id).joined(separator: "\u{1}"))"
        case let .table(headers, _, rows): return "table:\(headers.joined(separator: "|")):\(rows.count)"
        case .thematicBreak: return "hr"
        }
    }
}
