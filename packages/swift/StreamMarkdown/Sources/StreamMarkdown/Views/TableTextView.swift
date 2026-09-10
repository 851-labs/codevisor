#if canImport(AppKit)
  import AppKit

  // MARK: - NSTextView subclass

  /// A read-only text view that renders a markdown table and copies selections as
  /// tab-separated rows.
  ///
  /// It (re)builds its table in `layout()` at its assigned width, so the table
  /// always fills the frame SwiftUI grants — no chopped-off content, no sideways
  /// jitter while streaming.
  ///
  /// The copy override matters because copying spans of an `NSTextTable` otherwise
  /// yields one cell per line (each cell is its own paragraph in the backing
  /// store), losing the row/column shape when pasted as plain text. The rich (RTF)
  /// representation from `super` is preserved for apps that accept it.
  final class TableTextView: TranscriptSelectableTextView {
    private var model: TableModel?
    private var renderMemo: MarkdownTableRenderMemo?
    private var builtWidth: CGFloat = -1
    var preparedWidth: CGFloat?

    /// The narrowest width at which no column wraps mid-word.
    var minimumTableWidth: CGFloat {
      if let preparedWidth { return preparedWidth }
      guard let model, let renderMemo else { return 0 }
      return renderMemo.minimumWidth(for: model)
    }

    func update(model: TableModel, renderMemo: MarkdownTableRenderMemo) {
      guard self.model != model || self.renderMemo !== renderMemo else { return }
      self.model = model
      self.renderMemo = renderMemo
      builtWidth = -1  // force a rebuild at the next layout pass
      needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
      super.setFrameSize(newSize)
      if abs(newSize.width - builtWidth) > 0.25 { needsLayout = true }
    }

    override func layout() {
      super.layout()
      guard let model, let renderMemo, bounds.width > 0,
        abs(bounds.width - builtWidth) > 0.25
      else { return }
      let string = renderMemo.attributedString(for: model, width: bounds.width)
      updateLinkHover(at: nil)
      textStorage?.setAttributedString(string)
      builtWidth = bounds.width
    }

    override func transcriptPlainText(in range: NSRange) -> String {
      guard let storage = textStorage, let tsv = Self.tsv(from: storage, in: range) else {
        return super.transcriptPlainText(in: range)
      }
      return tsv
    }

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
      guard range.length > 16_384, let storage = textStorage else {
        return super.accessibilityAttributedString(for: range)
      }
      // AppKit's bulk conversion repeatedly hashes NSTextTableBlock graphs.
      // Export text styles directly for large requests; native selection,
      // individual link queries, and table copying still use the text view.
      return MarkdownTableAccessibility.attributedText(storage, in: range)
    }

    override func writeSelection(
      to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]
    ) -> Bool {
      let handled = super.writeSelection(to: pboard, types: types)
      if types.contains(.string), let storage = textStorage,
        let tsv = Self.tsv(from: storage, in: selectedRange())
      {
        pboard.setString(tsv, forType: .string)
      }
      return handled
    }

    /// Rebuilds a range as TSV by grouping the cell paragraphs it covers (each
    /// tagged with an `NSTextTableBlock`) by row and column. Returns nil when
    /// the range contains no table cells, so non-table text (should there ever
    /// be any) falls back to the default copy behavior.
    static func tsv(from storage: NSAttributedString, in range: NSRange) -> String? {
      guard range.length > 0, NSMaxRange(range) <= storage.length else { return nil }

      let nsString = storage.string as NSString
      var grid: [Int: [Int: String]] = [:]
      var sawCell = false
      let strip = CharacterSet(charactersIn: "\u{202F}").union(.newlines)

      storage.enumerateAttribute(.paragraphStyle, in: range) { value, subRange, _ in
        guard let style = value as? NSParagraphStyle,
          let block = style.textBlocks.first as? NSTextTableBlock
        else { return }
        sawCell = true
        let text = nsString.substring(with: subRange).trimmingCharacters(in: strip)
        grid[block.startingRow, default: [:]][block.startingColumn, default: ""] += text
      }
      guard sawCell else { return nil }

      return grid.keys.sorted().map { rowIndex -> String in
        let columns = grid[rowIndex] ?? [:]
        guard let lowest = columns.keys.min(), let highest = columns.keys.max() else { return "" }
        return (lowest...highest).map { columns[$0] ?? "" }.joined(separator: "\t")
      }.joined(separator: "\n")
    }
  }

#endif
