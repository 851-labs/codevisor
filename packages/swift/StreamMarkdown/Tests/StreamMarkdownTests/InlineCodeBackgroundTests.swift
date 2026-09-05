import AppKit
@testable import StreamMarkdown
import SwiftUI
import Testing

@MainActor
@Suite("Inline code backgrounds")
struct InlineCodeBackgroundTests {
  @Test(
    "Linked code paints the same continuous background as unlinked code",
    arguments: [
      ("72d1965f", 600.0),
      ("72d1965f", 110.0),
      ("a longer code span that wraps across lines", 150.0),
    ]
  )
  func linkedCodeBackground(label: String, width: Double) throws {
    let destination = "https://example.com/commit/72d1965f"
    let linked = try backgroundPixels(
      markdown: "Pushed [`\(label)`](\(destination)) to `main`. Working tree is clean.",
      width: width
    )
    let plain = try backgroundPixels(
      markdown: "Pushed `\(label)` to `main`. Working tree is clean.",
      width: width
    )

    #expect(linked.text == plain.text)
    #expect(linked.links == [URL(string: destination)!])
    #expect(plain.links.isEmpty)
    #expect(linked.alphas.count == plain.alphas.count)
    let paintedPixels = plain.alphas.filter { $0 > 0 }.count
    #expect(paintedPixels > 0)
    let differingPixels = zip(linked.alphas, plain.alphas).filter { $0 != $1 }.count
    #expect(differingPixels == 0)
  }

  private func backgroundPixels(
    markdown: String,
    width: CGFloat
  ) throws -> (alphas: [UInt8], text: String, links: [URL]) {
    var theme = MarkdownTheme.default
    theme.inlineCodeBackground = .white.opacity(0.25)
    let rendered = NSMutableAttributedString(
      attributedString: MarkdownTextRunRenderer.attributedString(
        for: MarkdownParser().parse(markdown), theme: theme, foregroundColor: .clear
      )
    )
    // Hide glyphs while retaining link boundaries so only the actual chip
    // painter contributes pixels. Compare within this render, without a
    // snapshot baseline tied to the machine's fonts or appearance.
    rendered.addAttribute(
      .foregroundColor, value: NSColor.clear,
      range: NSRange(location: 0, length: rendered.length)
    )
    let view = MarkdownTextKit2View()
    view.appearance = NSAppearance(named: .darkAqua)
    view.linkTextAttributes = [.foregroundColor: NSColor.clear]
    view.setContent(rendered)
    let height = view.contentHeight(forWidth: width)
    view.setFrameSize(NSSize(width: width, height: height))
    view.layoutSubtreeIfNeeded()

    let storage = try #require(view.textStorage)
    var links: [URL] = []
    storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) {
      value, _, _ in
      if let url = value as? URL { links.append(url) }
    }

    let scale: CGFloat = 2
    let pixelWidth = Int(ceil((width + 8) * scale))
    let pixelHeight = Int(ceil((height + 8) * scale))
    let context = try #require(
      CGContext(
        data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
        bytesPerRow: pixelWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: 4, y: 4)
    let layout = try #require(view.textLayoutManager)
    layout.enumerateTextLayoutFragments(from: layout.documentRange.location) { fragment in
      fragment.draw(at: fragment.layoutFragmentFrame.origin, in: context)
      return true
    }
    let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    let alphas = (0..<(pixelWidth * pixelHeight)).map { pixels[$0 * 4 + 3] }
    return (alphas, view.string, links)
  }
}
