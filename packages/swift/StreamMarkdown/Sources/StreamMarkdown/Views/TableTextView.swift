#if canImport(AppKit)
  import AppKit

  final class TableTextView: TranscriptSelectableTextView {
    private var model: TableModel?
    private var renderMemo: MarkdownTableRenderMemo?
    private var builtWidth: CGFloat = -1
    var preparedWidth: CGFloat?

    var minimumTableWidth: CGFloat {
      if let preparedWidth { return preparedWidth }
      guard let model, let renderMemo else { return 0 }
      return renderMemo.minimumWidth(for: model)
    }

    func update(model: TableModel, renderMemo: MarkdownTableRenderMemo) {
      guard self.model != model || self.renderMemo !== renderMemo else { return }
      self.model = model
      self.renderMemo = renderMemo
      builtWidth = -1
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
      if let layoutManager, let textContainer { layoutManager.ensureLayout(for: textContainer) }
      builtWidth = bounds.width
      needsDisplay = true
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
      super.setNeedsDisplay(Self.redrawRect(covering: invalidRect, in: bounds))
    }

    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
      super.setNeedsDisplay(Self.redrawRect(covering: rect, in: bounds), avoidAdditionalLayout: flag)
    }

    static func redrawRect(covering rect: NSRect, in bounds: NSRect) -> NSRect {
      guard !rect.isEmpty, rect.height.isFinite else { return rect }
      let reach = MarkdownTableMetrics.verticalPadding * 2 + 1
      let widened = NSRect(
        x: bounds.minX, y: rect.minY - reach,
        width: bounds.width, height: rect.height + reach * 2
      )
      return widened.intersection(bounds)
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

    static func tsv(from storage: NSAttributedString, in range: NSRange) -> String? {
      guard range.length > 0, NSMaxRange(range) <= storage.length else { return nil }

      var grid: [Int: [Int: String]] = [:]
      var sawCell = false
      let strip = CharacterSet(charactersIn: "\u{202F}").union(.newlines)

      storage.enumerateAttribute(.paragraphStyle, in: range) { value, subRange, _ in
        guard let style = value as? NSParagraphStyle,
          let block = style.textBlocks.first as? NSTextTableBlock
        else { return }
        sawCell = true
        let text = MarkdownImageAttachment.plainText(storage.attributedSubstring(from: subRange)).trimmingCharacters(
          in: strip)
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
