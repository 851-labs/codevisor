import CodevisorTestSupport
import Foundation
import Testing
@testable import StreamMarkdown

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

@Suite("Markdown table image rendering")
@MainActor
struct MarkdownTableImageTests {
  private func fixture(id: String = "pixels") -> MarkdownImage {
    #if canImport(AppKit)
      let image = NSImage(size: CGSize(width: 640, height: 320))
    #else
      let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 320)).image { context in
        UIColor.red.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 320))
      }
    #endif
    return MarkdownImage(image: image, id: id)
  }

  @Test("Images with and without alt text become image attachments", arguments: ["", "Screenshot"])
  func renderedImage(alt: String) throws {
    let source = "https://example.com/image.png"
    let text = MarkdownParser().parseInline("![\(alt)](\(source))")
    let resources: [String: MarkdownImageResource] = [source: .loaded(fixture())]
    #if canImport(AppKit)
      let prepared = MarkdownTableRenderer.prepare(
        headers: ["Preview"], rows: [[text]], theme: .default, images: resources)
      let cell = prepared.rows[0][0].attributedString
    #else
      let layout = try UIKitMarkdownTableLayout(
        headers: ["Preview"], alignments: [], rows: [[text]], theme: .default, width: 200, images: resources)
      let cell = layout.cells[1][0]
      #expect(layout.geometry.size.height > 100)
    #endif
    let attachment = try #require(cell.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
    #expect(attachment.image != nil)
    #expect(attachment.bounds.width > 0)
    #expect(abs(attachment.bounds.width / attachment.bounds.height - 2) < 0.01)
    #expect(cell.string == "\u{FFFC}")
  }

  @Test("Image placeholders stay visible when alt text is empty")
  func unavailable() {
    let reference = MarkdownImageReference(source: "./missing.png", alt: "")
    #expect(!MarkdownImageAttachment.content(reference, resource: nil, attributes: [:]).string.isEmpty)
    #expect(
      MarkdownImageAttachment.content(reference, resource: .unavailable, attributes: [:]).string
        == "[Image unavailable]")
  }

  @Test("Nested image links preserve their click destination")
  func linkedImage() throws {
    let text = MarkdownParser().parseInline("[![Screenshot](./shot.png)](https://example.com/details)")
    let rendered = InlineMarkdown.tableAttributedString(from: text)
    let run = try #require(rendered.runs.first)
    #expect(run.link == URL(string: "https://example.com/details"))
    #expect(run[MarkdownImageReferenceAttribute.self]?.source == "./shot.png")
  }

  #if canImport(AppKit)
    @Test("Image loading invalidates cached table geometry and narrow widths scale images")
    func layoutAndCache() throws {
      let cache = MarkdownTableRenderCache()
      let rows = [[MarkdownParser().parseInline("![](./shot.png)"), MarkdownText("ready")]]
      let empty = TableModel(headers: ["Preview", "Status"], alignments: [], rows: rows, theme: .default)
      let loaded = TableModel(
        headers: ["Preview", "Status"], alignments: [], rows: rows, theme: .default,
        images: ["./shot.png": .loaded(fixture())])
      let first = cache.size(for: empty, width: 400)
      let full = cache.size(for: loaded, width: 400)
      #expect(full.height > first.height + 50)
      let narrow = cache.attributedString(for: loaded, width: 220)
      var attachments: [NSTextAttachment] = []
      narrow.enumerateAttribute(.attachment, in: NSRange(location: 0, length: narrow.length)) { value, _, _ in
        if let attachment = value as? NSTextAttachment { attachments.append(attachment) }
      }
      let attachment = try #require(attachments.first)
      #expect(attachment.bounds.width <= 172)
      #expect(cache.size(for: loaded, width: 400) == full)
      #expect(
        TableTextView.tsv(from: narrow, in: NSRange(location: 0, length: narrow.length))
          == "Preview\tStatus\nImage\tready")
    }
  #endif

  @Test("Loading deduplicates sources and keeps different servers isolated")
  func loading() async {
    let state = MarkdownTableImages()
    var requests: [String] = []
    let image = fixture()
    let loader = MarkdownImageLoader(id: "server-one") { source in
      requests.append(source)
      return image
    }
    await state.load(sources: ["./shot.png"], using: loader)
    await state.load(sources: ["./shot.png"], using: loader)
    #expect(requests == ["./shot.png"])
    let other = MarkdownImageLoader(id: "server-two") { _ in nil }
    await state.load(sources: ["./shot.png"], using: other)
    #expect(state.resources["./shot.png"] == .unavailable)
  }
  @Test("A cancelled old load cannot overwrite a replacement server's pixels")
  func cancelledLoad() async {
    let requested = TestSignal()
    let release = TestSignal()
    let image = fixture()
    let old = MarkdownImageLoader(id: "old") { _ in
      requested.signal()
      await release.wait()
      return image
    }
    let state = MarkdownTableImages()
    let task = Task { await state.load(sources: ["./image.png"], using: old) }
    await requested.wait()
    task.cancel()
    await state.load(sources: ["./image.png"], using: MarkdownImageLoader(id: "new") { _ in nil })
    release.signal()
    await task.value
    #expect(state.resources["./image.png"] == .unavailable)
  }

  #if canImport(AppKit)
    @Test("Settled Markdown publishes the new row height after loading an image")
    func settledLayoutInvalidation() async {
      let requested = TestSignal()
      let release = TestSignal()
      let changed = TestSignal()
      let image = fixture()
      let loader = MarkdownImageLoader(id: "native-fixture") { _ in
        requested.signal()
        await release.wait()
        return image
      }
      let view = SettledMarkdownView()
      view.setContent(
        blocks: MarkdownParser().parse("| Preview |\n| --- |\n| ![](./image.png) |"),
        theme: .default, streamID: "fixture", linkAction: nil, imageLoader: loader)
      let before = view.contentHeight(forWidth: 400)
      view.onContentHeightChange = { changed.signal() }
      await requested.wait()
      release.signal()
      await changed.wait()
      let after = view.contentHeight(forWidth: 400)
      view.frame = CGRect(x: 0, y: 0, width: 400, height: after)
      view.layoutSubtreeIfNeeded()
      #expect(after > before + 50)
    }
  #endif

}
