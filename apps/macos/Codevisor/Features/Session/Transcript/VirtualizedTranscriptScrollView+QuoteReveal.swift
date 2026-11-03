import AppKit
import CodevisorCore
import CodevisorUI
import StreamMarkdown
import TranscriptKit

extension VirtualizedTranscriptScrollView: TranscriptQuoteRevealTarget {
  private static let quoteSearchRowLimit = 64
  private static let quoteViewportFraction: CGFloat = 0.35
  private static let quoteSettleDelays: [Duration] = [.milliseconds(120), .milliseconds(300)]

  @discardableResult
  func revealQuote(_ quote: TranscriptQuote) -> Bool {
    quotes.pendingReveal = nil
    quotes.revealGeneration &+= 1
    guard initialPresentationGate.isReady, let start = firstRowIndex(of: quote) else { return false }

    let target = quoteTarget(quote, from: start)
    scrollToQuote(target, fallbackRow: start)
    showQuoteHighlight(target, generation: quotes.revealGeneration)
    return true
  }

  func waitToRevealQuote(_ quote: TranscriptQuote) {
    quotes.pendingReveal = quote
  }

  func cancelPendingQuoteReveal() {
    quotes.pendingReveal = nil
  }

  var isWaitingToRevealQuote: Bool { quotes.pendingReveal != nil }

  func revealPendingQuoteIfPossible() {
    guard let quote = quotes.pendingReveal, firstRowIndex(of: quote) != nil else { return }
    revealQuote(quote)
  }

  func showQuoteNotFound() {
    transcriptDocumentView.addSubview(quotes.notFoundNotice, positioned: .above, relativeTo: nil)
    quotes.notFoundNotice.show(centeredAtTopOf: unobstructedViewport)
  }

  private func firstRowIndex(of quote: TranscriptQuote) -> Int? {
    virtualLayout.keys.firstIndex { quote.isSource(ofRowKey: $0) }
  }

  private func quoteTarget(_ quote: TranscriptQuote, from start: Int) -> TranscriptTextSelection? {
    let messageRows = quoteRowTexts(from: start) { quote.isSource(ofRowKey: $0) }
    if let target = TranscriptQuoteLocator.selection(of: quote.text, in: messageRows) { return target }
    return TranscriptQuoteLocator.selection(of: quote.text, in: quoteRowTexts(from: start) { _ in true })
  }

  private func quoteRowTexts(from start: Int, while includes: (String) -> Bool) -> [TranscriptQuoteRowText] {
    let keys = virtualLayout.keys[start...].prefix(Self.quoteSearchRowLimit).prefix(while: includes)
    return keys.indices.map { index in
      let key = virtualLayout.keys[index]
      return TranscriptQuoteRowText(
        rowKey: key, surfaces: quoteSurfaceTexts(forRowKey: key), separatorBefore: quoteRowSeparator(before: index))
    }
  }

  private func quoteSurfaceTexts(forRowKey key: String) -> [String] {
    if let host = mountedHosts[key] { return selectionSurfaces(in: host).map(\.transcriptString) }
    guard let row = rowByKey[key] else { return [] }
    return TranscriptRowTextProjection.surfaceTexts(for: row, theme: markdownRowStyle.markdown)
  }

  private func quoteRowSeparator(before index: Int) -> String {
    TranscriptSelectionText.rowSeparator(
      previous: index > 0 ? rowByKey[virtualLayout.keys[index - 1]] : nil,
      current: rowByKey[virtualLayout.keys[index]]
    )
  }

  private func scrollToQuote(_ target: TranscriptTextSelection?, fallbackRow: Int) {
    let row = target.flatMap { virtualLayout.indexByKey[$0.anchor.rowKey] } ?? fallbackRow
    if target.map(documentRects(for:))?.isEmpty != false {
      scrollAsUserInput(toTop: quoteViewportTop(forRowAt: row))
      transcriptDocumentView.layoutSubtreeIfNeeded()
    }
    guard let target else { return }
    centerQuoteIfNeeded(documentRects(for: target))
  }

  private func centerQuoteIfNeeded(_ rects: [NSRect]) {
    guard let first = rects.first else { return }
    let bounds = rects.dropFirst().reduce(first) { $0.union($1) }
    let region = unobstructedViewport
    guard bounds.minY < region.minY || bounds.maxY > region.maxY else { return }

    let obstructedTop = region.minY - contentView.bounds.minY
    scrollAsUserInput(toTop: bounds.minY - obstructedTop - region.height * Self.quoteViewportFraction)
    transcriptDocumentView.layoutSubtreeIfNeeded()
  }

  private func quoteViewportTop(forRowAt index: Int) -> CGFloat {
    let region = unobstructedViewport
    let obstructedTop = region.minY - contentView.bounds.minY
    return rowFrame(at: index).minY - obstructedTop - region.height * Self.quoteViewportFraction
  }

  private func showQuoteHighlight(_ target: TranscriptTextSelection?, generation: Int) {
    let highlight = quotes.highlight
    guard let target else { return highlight.clear() }

    transcriptDocumentView.addSubview(highlight, positioned: .above, relativeTo: nil)
    highlight.show(documentRects(for: target))
    Task { [weak self] in
      for delay in Self.quoteSettleDelays {
        try? await Task.sleep(for: delay)
        guard let self, self.quotes.revealGeneration == generation, !highlight.isHidden else { return }
        highlight.place(self.documentRects(for: target))
      }
    }
  }
}
