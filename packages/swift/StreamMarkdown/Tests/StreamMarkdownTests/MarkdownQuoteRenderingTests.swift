import AppKit
@testable import StreamMarkdown
import SwiftUI
import Testing

@MainActor
@Suite("Markdown quote rendering")
struct MarkdownQuoteRenderingTests {
  @Test("Quote borders keep uniform opacity across paragraphs and nested quotes", arguments: [180.0, 600.0])
  func quoteBorderOpacity(width: CGFloat) throws {
    var theme = MarkdownTheme.default
    theme.quoteBarColor = .white.opacity(0.2)
    let text = MarkdownTextRunRenderer.attributedString(
      for: MarkdownParser().parse(
        """
        > Open a file with `[View recording](./output/demo.mp4)`.
        >
        > Use an **inline preview** for images and videos.
        >
        > > A nested quote with `code` and a [link](https://example.com).
        > >
        > > Another nested paragraph.
        >
        > The final paragraph returns to the outer quote.
        """
      ),
      theme: theme,
      foregroundColor: .primary
    )
    let storage = NSTextStorage(attributedString: text)
    let layout = StreamingTextLayoutManager()
    let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    storage.addLayoutManager(layout)
    layout.addTextContainer(container)
    layout.ensureLayout(for: container)
    let glyphs = layout.glyphRange(for: container)
    let height = Int(ceil(layout.usedRect(for: container).height)) + 2
    let pixelWidth = Int(width * 2)
    let pixelHeight = height * 2
    let context = try #require(
      CGContext(
        data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
        bytesPerRow: pixelWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    context.scaleBy(x: 2, y: 2)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    layout.drawMarkdownQuoteBars(forGlyphRange: glyphs, at: .zero)

    let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    let outerBar = (0..<pixelHeight).map { row in data[(row * pixelWidth + 1) * 4 + 3] }
    let first = try #require(outerBar.firstIndex(where: { $0 > 0 }))
    let last = try #require(outerBar.lastIndex(where: { $0 > 0 }))
    #expect(Set(outerBar[first...last]) == [51], "Every border pixel should have 20% opacity")

    let nestedColumn = Int(MarkdownFragmentMetrics.quoteIndent * 2) + 1
    let nestedBar = (0..<pixelHeight).map { row in data[(row * pixelWidth + nestedColumn) * 4 + 3] }
    let nestedFirst = try #require(nestedBar.firstIndex(where: { $0 > 0 }))
    let nestedLast = try #require(nestedBar.lastIndex(where: { $0 > 0 }))
    #expect(Set(nestedBar[nestedFirst...nestedLast]) == [51])
    #expect(nestedFirst > first)
    #expect(nestedLast < last)
  }
}
