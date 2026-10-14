#if canImport(AppKit)
  import AppKit

  @testable import StreamMarkdown

  extension MarkdownTableRenderer {
    static func make(
      headers: [String], alignments: [ColumnAlignment], rows: [[String]],
      theme: MarkdownTheme, width: CGFloat? = nil
    ) -> NSAttributedString {
      let parser = MarkdownParser()
      return make(
        prepared: prepare(
          headers: headers.map(parser.parseInline),
          rows: rows.map { $0.map(parser.parseInline) },
          theme: theme
        ),
        alignments: alignments,
        theme: theme,
        width: width
      )
    }
  }

  extension TableModel {
    init(headers: [String], alignments: [ColumnAlignment], rows: [[String]], theme: MarkdownTheme) {
      let parser = MarkdownParser()
      self.init(
        headers: headers.map(parser.parseInline),
        alignments: alignments,
        rows: rows.map { $0.map(parser.parseInline) },
        theme: theme
      )
    }
  }
#endif
