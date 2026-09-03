import AppKit
@testable import StreamMarkdown
import SwiftUI
import Testing

@MainActor
@Suite("Settled native Markdown")
struct SettledMarkdownViewTests {
  @Test("Settled prose stays on TextKit 2 and selection does not change height")
  func textKit2SelectionStableSizing() {
    let text = NSAttributedString(
      string: String(repeating: "Native transcript text wraps predictably. ", count: 30),
      attributes: [.font: NSFont.preferredFont(forTextStyle: .body)]
    )
    let view = MarkdownTextKit2View()
    view.setContent(text)

    let before = view.contentHeight(forWidth: 280)
    view.setSelectedRange(NSRange(location: 7, length: 60))
    let after = view.contentHeight(forWidth: 280)

    #expect(view.usesTextKit2)
    #expect(before > 1)
    #expect(before == after)
    #expect(view.selectedRange() == NSRange(location: 7, length: 60))
  }

  @Test("TextKit 2 repairs its wrapping width after a virtualized remount")
  func textContainerTracksRemountedViewWidth() {
    let view = MarkdownTextKit2View()
    view.setContent(
      NSAttributedString(
        string: String(repeating: "Remounted transcript text. ", count: 12)
      )
    )

    _ = view.contentHeight(forWidth: 480)
    #expect(view.textContainer?.widthTracksTextView == true)
    #expect(view.textContainer?.size.width == 480)

    // Reproduce the AppKit state observed after a host was detached and
    // recycled: the text view remains wide while its container returns to
    // the 1pt size supplied at construction.
    view.textContainer?.size = NSSize(
      width: 1,
      height: CGFloat.greatestFiniteMagnitude
    )

    _ = view.contentHeight(forWidth: 480)
    #expect(view.textContainer?.size.width == 480)
  }

  @Test("Width changes invalidate native prose layout")
  func widthControlsWrapping() {
    let view = SettledMarkdownView()
    view.setContent(
      blocks: [
        .paragraph(String(repeating: "A settled Markdown sentence. ", count: 30))
      ],
      theme: .default,
      streamID: "settled-prose",
      linkAction: nil
    )

    let wide = view.contentHeight(forWidth: 600)
    let narrow = view.contentHeight(forWidth: 220)

    #expect(narrow > wide)
  }

  @Test("Settled selection clears when focus leaves the surface")
  func selectionClearsOnResign() {
    let view = MarkdownTextKit2View()
    view.setContent(NSAttributedString(string: "A native transcript selection"))
    view.setSelectedRange(NSRange(location: 2, length: 12))

    #expect(view.resignFirstResponder())
    #expect(view.selectedRange() == NSRange(location: 14, length: 0))
    #expect(view.usesTextKit2)
  }

  @Test("TextKit 2 preserves the established TextKit 1 line metrics")
  func settledLineMetricParity() {
    let rendered = MarkdownTextRunRenderer.attributedString(
      for: [
        .heading(level: 2, text: "A stable heading"),
        .paragraph(
          String(
            repeating: "Streaming and settled text share the same geometry. ",
            count: 12
          )
        ),
        .bulletList(["First item", "Second item with `code`"]),
      ],
      theme: .default,
      foregroundColor: .primary
    )
    let established = SelectableTextKitView()
    established.setContent(rendered)
    let settled = MarkdownTextKit2View()
    settled.setContent(rendered)

    for width: CGFloat in [220, 420, 760] {
      let establishedHeight = established.contentHeight(forWidth: width)
      let settledHeight = settled.contentHeight(forWidth: width)
      let delta = abs(establishedHeight - settledHeight)
      #expect(delta <= 1)
    }
  }

  @Test("Complex blocks report exact non-placeholder heights")
  func complexBlockHeights() {
    let parser = MarkdownParser()
    let blocks = parser.parse(
      """
      ```swift
      let answer = 42
      print(answer)
      ```

      | Name | Value |
      | --- | ---: |
      | answer | 42 |
      """
    )
    let view = SettledMarkdownView()
    view.setContent(
      blocks: blocks,
      theme: .default,
      streamID: "settled-complex",
      linkAction: nil
    )

    let height = view.contentHeight(forWidth: 500)

    #expect(height > 80)
  }

  @Test("Native code blocks preserve the established visible height")
  func codeBlockHeightParity() {
    let code = "let answer = 42\nprint(answer)"
    let established = NSHostingView(
      rootView: CodeBlockView(
        id: "established-code",
        language: "swift",
        code: code,
        isComplete: true
      )
      .markdownTheme(.default)
      .frame(width: 500)
    )
    let native = NativeMarkdownCodeBlockView(
      id: "native-code",
      language: "swift",
      code: code,
      theme: .default
    )

    let delta = abs(
      established.fittingSize.height
        - native.contentHeight(forWidth: 500)
    )

    #expect(delta <= 1)
  }

  @Test("Native code-block chrome uses top-down transcript coordinates")
  func codeBlockHeaderStaysAboveCode() {
    let native = NativeMarkdownCodeBlockView(
      id: "native-code-order",
      language: "swift",
      code: "let answer = 42",
      theme: .default
    )
    native.frame = NSRect(
      x: 0,
      y: 0,
      width: 500,
      height: native.contentHeight(forWidth: 500)
    )
    native.layoutSubtreeIfNeeded()

    let label = native.subviews.compactMap { $0 as? NSTextField }.first
    let scrollView = native.subviews.compactMap { $0 as? NSScrollView }.first

    #expect(native.isFlipped)
    #expect(label != nil)
    #expect(scrollView != nil)
    #expect((label?.frame.minY ?? .infinity) < (scrollView?.frame.minY ?? 0))
  }

  @Test("Native tables preserve the established visible height")
  func tableHeightParity() {
    let parser = MarkdownParser()
    let headers = [parser.parseInline("Name"), parser.parseInline("Value")]
    let rows = [
      [parser.parseInline("answer"), parser.parseInline("42")],
      [parser.parseInline("language"), parser.parseInline("Swift")],
    ]
    let established = NSHostingView(
      rootView: MarkdownTableView(
        headers: headers,
        alignments: [.leading, .trailing],
        rows: rows
      )
      .markdownTheme(.default)
      .frame(width: 500)
    )
    let native = NativeMarkdownTableBlockView(
      headers: headers,
      alignments: [.leading, .trailing],
      rows: rows,
      theme: .default,
      linkAction: nil
    )

    let delta = abs(
      established.fittingSize.height
        - native.contentHeight(forWidth: 500)
    )

    #expect(delta <= 1)
  }

  @Test("Adjacent translucent quote bar pieces tile without seams at 2x")
  func quoteBarPiecesTileWithoutSeams() throws {
    let scale: CGFloat = 2
    let width = 8, height = 80
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.scaleBy(x: scale, y: scale)
    let color = NSColor(white: 1, alpha: 0.2)
    // Three pieces with fractional shared edges, as line/layout fragments produce.
    for (top, bottom) in [(0.0, 10.3), (10.3, 21.7), (21.7, 30.0)] {
      TextKitQuoteBarPainter.fill(
        CGRect(x: 1, y: top, width: 2, height: bottom - top), color: color, in: context)
    }
    let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    let column = 2 * Int(scale) + 1  // inside the 2pt bar
    let alphas = (0..<height).map { row in data[(row * width + column) * 4 + 3] }
    let covered = alphas.filter { $0 > 0 }
    #expect(covered.count == Int(30 * scale))
    // No pixel composited twice (darker) or missed (lighter) inside the bar.
    #expect(Set(covered).count == 1, "seam values: \(Set(covered))")
  }

  @Test("Every character of a multi-paragraph quote carries the bar decoration")
  func quoteDecorationCoversSpacingBetweenParagraphs() {
    let text = MarkdownTextRunRenderer.attributedString(
      for: [.blockQuote([.paragraph("First paragraph."), .paragraph("Second paragraph.")])],
      theme: .default,
      foregroundColor: .primary
    )
    var uncovered = 0
    text.enumerateAttribute(
      .streamMarkdownQuoteDecoration,
      in: NSRange(location: 0, length: text.length)
    ) { value, range, _ in
      if value == nil { uncovered += range.length }
    }
    #expect(text.length > 0)
    #expect(uncovered == 0)
  }
}
