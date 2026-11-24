#if canImport(AppKit)
  import AppKit

  final class TableTextView: TranscriptSelectableTextView {
    private var model: TableModel?
    private var renderMemo: MarkdownTableRenderMemo?
    private var builtWidth: CGFloat = -1
    private var geometry: MarkdownTableGeometry?
    var preparedWidth: CGFloat?
    var ruleColor: NSColor = .separatorColor {
      didSet {
        guard ruleColor != oldValue else { return }
        needsDisplay = true
      }
    }

    convenience init(preparedLayout layout: PreparedNativeTextLayout) {
      self.init(frame: CGRect(origin: .zero, size: layout.size), textContainer: layout.container)
      preparedWidth = layout.size.width
      geometry = layout.tableGeometry
    }

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

    func adoptPreparedLayout(_ layout: PreparedNativeTextLayout) {
      guard layoutManager !== layout.manager else { return }
      let selection = selectedRange()
      model = nil
      renderMemo = nil
      builtWidth = -1
      updateLinkHover(at: nil)
      textContainer?.textView = nil
      layout.container.textView = self
      preparedWidth = layout.size.width
      geometry = layout.tableGeometry
      if NSMaxRange(selection) <= layout.text.length { setSelectedRange(selection) }
      needsDisplay = true
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
      geometry = nil
      builtWidth = bounds.width
      needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
      drawChrome(in: dirtyRect)
      super.draw(dirtyRect)
    }

    private func drawChrome(in dirtyRect: NSRect) {
      guard drawsGlyphs, let chrome = measuredChrome(), let context = NSGraphicsContext.current?.cgContext else {
        return
      }

      let origin = textContainerOrigin
      context.saveGState()
      context.translateBy(x: origin.x, y: origin.y)
      chrome.fillHeader(in: context, color: Self.headerColor.cgColor)
      chrome.fillRules(
        intersecting: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y), in: context, color: ruleColor.cgColor)
      context.restoreGState()
    }

    private func measuredChrome() -> MarkdownTableChrome? {
      if geometry == nil, let layoutManager {
        geometry = MarkdownTextTableGeometry.measured(in: layoutManager)
      }
      return geometry.map(MarkdownTableChrome.init)
    }

    private static let headerColor = NSColor.labelColor.withAlphaComponent(
      MarkdownTableMetrics.headerBackgroundOpacity)

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
