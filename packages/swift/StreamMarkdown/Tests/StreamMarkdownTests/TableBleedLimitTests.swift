#if canImport(AppKit)
  import AppKit
  import MarkdownCore
  import Testing

  @testable import StreamMarkdown

  @MainActor
  @Suite("Table bleed limit")
  struct TableBleedLimitTests {
    @Test("A table bleeds to the transcript gutter unless its container caps the bleed")
    func bleedLimit() throws {
      let transcript = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
      transcript.hasVerticalScroller = true
      let document = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
      transcript.documentView = document
      let markdown = SettledMarkdownView(frame: NSRect(x: 40, y: 0, width: 520, height: 200))
      document.addSubview(markdown)
      markdown.setContent(
        blocks: [
          .table(
            headers: [MarkdownText("Column"), MarkdownText("Column")],
            alignments: [],
            rows: [[MarkdownText(String(repeating: "unbreakable", count: 20)), MarkdownText("x")]]
          )
        ],
        theme: .default,
        streamID: "bleed",
        linkAction: nil
      )
      let table = try #require(markdown.subviews.first as? NativeMarkdownTableBlockView)
      let container = try #require(table.subviews.first as? TableBleedContainer)
      func layout() {
        markdown.frame.size.height = markdown.contentHeight(forWidth: 520)
        markdown.needsLayout = true
        markdown.layoutSubtreeIfNeeded()
      }

      layout()
      #expect(container.bleed == 40)
      #expect(container.scrollView.frame.width == 600)

      markdown.tableBleedLimit = 11
      layout()
      #expect(container.bleed == 11)
      #expect(container.scrollView.frame.minX == -11)
      #expect(container.scrollView.frame.width == 542)
      let documentWidth = try #require(container.scrollView.documentView).frame.width
      #expect(documentWidth > 520)

      // Recycled hosts reset the limit for ordinary transcript rows.
      markdown.tableBleedLimit = .greatestFiniteMagnitude
      layout()
      #expect(container.bleed == 40)
    }
  }
#endif
