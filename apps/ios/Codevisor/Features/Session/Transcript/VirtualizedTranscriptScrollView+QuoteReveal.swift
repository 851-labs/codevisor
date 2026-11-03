import CodevisorCore
import CodevisorUI
import TranscriptKit
import UIKit

@MainActor
final class TranscriptQuoteState {
  let highlight = TranscriptQuoteHighlightView()
  let notFoundNotice = TranscriptQuoteNotFoundNotice()
  var pendingReveal: TranscriptQuote?
  var revealGeneration = 0
  var viewportHoldDeadline: TimeInterval = 0
}

extension VirtualizedTranscriptScrollView: TranscriptQuoteRevealTarget {
  private static let quoteSearchRowLimit = 64
  private static let viewportHoldWindow: TimeInterval = 1
  private static let quoteViewportFraction: CGFloat = 0.3
  private static let quoteSettleDelays: [Duration] = [.milliseconds(60), .milliseconds(150), .milliseconds(300)]

  var isWaitingToRevealQuote: Bool { quotes.pendingReveal != nil }

  func holdViewportForComposerChange() {
    quotes.viewportHoldDeadline = ProcessInfo.processInfo.systemUptime + Self.viewportHoldWindow
  }

  var holdsViewportForComposerChange: Bool {
    ProcessInfo.processInfo.systemUptime <= quotes.viewportHoldDeadline
  }

  func releaseFollowIfOffBottom() {
    guard followsLatest, currentDistanceFromBottom() > Self.atBottomThreshold else { return }
    followsLatest = false
    onFollowStateChange?(false)
  }

  @discardableResult
  func revealQuote(_ quote: TranscriptQuote) -> Bool {
    quotes.pendingReveal = nil
    quotes.revealGeneration &+= 1
    quotes.highlight.clear()
    guard initialPositionApplied, let start = firstRowIndex(of: quote) else { return false }

    if mountedHosts[virtualLayout.keys[start]] == nil { scrollQuoteRow(start) }
    settleQuoteHighlight(quote, from: start, generation: quotes.revealGeneration)
    return true
  }

  func waitToRevealQuote(_ quote: TranscriptQuote) {
    quotes.pendingReveal = quote
  }

  func cancelPendingQuoteReveal() {
    quotes.pendingReveal = nil
  }

  func revealPendingQuoteIfPossible() {
    guard let quote = quotes.pendingReveal, firstRowIndex(of: quote) != nil else { return }
    revealQuote(quote)
  }

  func showQuoteNotFound() {
    canvasView.addSubview(quotes.notFoundNotice)
    quotes.notFoundNotice.show(centeredAtTopOf: convert(visibleQuoteRegion, to: canvasView))
  }

  private var visibleQuoteRegion: CGRect {
    let covered = rowByKey[TranscriptVirtualRow.ID.bottomSpacer.layoutKey]?.estimatedHeight ?? 0
    let top = contentOffset.y + appliedTopContentInset
    return CGRect(x: 0, y: top, width: bounds.width, height: max(1, bounds.height - appliedTopContentInset - covered))
  }

  private func firstRowIndex(of quote: TranscriptQuote) -> Int? {
    virtualLayout.keys.firstIndex { quote.isSource(ofRowKey: $0) }
  }

  private func scrollQuoteRow(_ index: Int) {
    let rowTop = transcriptRowsOrigin + virtualLayout.frame(at: index).minY
    setViewportTop(rowTop - appliedTopContentInset - visibleQuoteRegion.height * Self.quoteViewportFraction)
    updateMountedRows()
    layoutIfNeeded()
  }

  private func settleQuoteHighlight(_ quote: TranscriptQuote, from start: Int, generation: Int) {
    Task { [weak self] in
      var isShown = false
      for delay in Self.quoteSettleDelays {
        try? await Task.sleep(for: delay)
        guard let self, self.quotes.revealGeneration == generation else { return }
        let rects = self.quoteCanvasRects(quote, from: start)
        guard !rects.isEmpty else { continue }
        if isShown {
          self.quotes.highlight.place(rects)
          continue
        }
        self.centerQuote(rects)
        self.canvasView.addSubview(self.quotes.highlight)
        self.quotes.highlight.show(rects)
        isShown = true
      }
    }
  }

  private func centerQuote(_ canvasRects: [CGRect]) {
    guard let first = canvasRects.first else { return }
    let union = canvasRects.dropFirst().reduce(first) { $0.union($1) }
    let bounds = canvasView.convert(union, to: self)
    let region = visibleQuoteRegion
    guard bounds.minY < region.minY || bounds.maxY > region.maxY else { return }

    setViewportTop(bounds.minY - appliedTopContentInset - region.height * Self.quoteViewportFraction)
    updateMountedRows()
    layoutIfNeeded()
  }

  private func quoteCanvasRects(_ quote: TranscriptQuote, from start: Int) -> [CGRect] {
    let surfaces = quoteSurfaces(from: start)
    let rows = surfaces.map { key, views in
      TranscriptQuoteRowText(
        rowKey: key, surfaces: views.map(\.textStorage.string), separatorBefore: quoteRowSeparator(before: key))
    }
    let messageRows = Array(rows.prefix { quote.isSource(ofRowKey: $0.rowKey) })
    guard
      let target = TranscriptQuoteLocator.selection(of: quote.text, in: messageRows)
        ?? TranscriptQuoteLocator.selection(of: quote.text, in: rows)
    else { return [] }
    return canvasRects(for: target, surfaces: surfaces)
  }

  private func quoteSurfaces(from start: Int) -> [(key: String, views: [UITextView])] {
    virtualLayout.keys[start...].prefix(Self.quoteSearchRowLimit).map { key in
      (key, mountedHosts[key].map(Self.textViews(in:)) ?? [])
    }
  }

  private func quoteRowSeparator(before key: String) -> String {
    guard let index = virtualLayout.indexByKey[key] else { return "\n\n" }
    return TranscriptSelectionText.rowSeparator(
      previous: index > 0 ? rowByKey[virtualLayout.keys[index - 1]] : nil,
      current: rowByKey[key]
    )
  }

  private func canvasRects(
    for target: TranscriptTextSelection, surfaces: [(key: String, views: [UITextView])]
  ) -> [CGRect] {
    let order = surfaces.map(\.key)
    guard let span = target.resolve(rowIndex: { order.firstIndex(of: $0) }) else { return [] }

    return span.rowRange.flatMap { rowIndex -> [CGRect] in
      let views = surfaces[rowIndex].views
      let ranges = span.surfaceRanges(rowIndex: rowIndex, surfaceLengths: views.map(\.textStorage.length))
      return zip(views, ranges).flatMap { view, range in range.map { canvasRects(of: NSRange($0), in: view) } ?? [] }
    }
  }

  private func canvasRects(of range: NSRange, in textView: UITextView) -> [CGRect] {
    guard let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
      let end = textView.position(from: start, offset: range.length),
      let textRange = textView.textRange(from: start, to: end)
    else { return [] }
    return textView.selectionRects(for: textRange)
      .map { textView.convert($0.rect, to: canvasView) }
      .filter { $0.width > 0 && $0.height > 0 }
  }

  private static func textViews(in view: UIView) -> [UITextView] {
    var found: [UITextView] = []
    func visit(_ view: UIView) {
      guard !view.isHidden else { return }
      if let textView = view as? UITextView { return found.append(textView) }
      view.subviews.forEach(visit)
    }
    visit(view)
    return found.sorted { readsBefore($0, $1, in: view) }
  }

  private static func readsBefore(_ lhs: UIView, _ rhs: UIView, in host: UIView) -> Bool {
    let left = lhs.convert(CGPoint.zero, to: host)
    let right = rhs.convert(CGPoint.zero, to: host)
    return (left.y.rounded(), left.x.rounded()) < (right.y.rounded(), right.x.rounded())
  }
}
