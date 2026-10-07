#if canImport(AppKit)
  import AppKit
  import MarkdownCore
  import Testing

  @testable import StreamMarkdown

  @MainActor
  @Suite("Table hosting")
  struct TableHostingTests {
    private final class RecordingTranscript: NSScrollView {
      var scrollEvents = 0

      override func scrollWheel(with event: NSEvent) {
        scrollEvents += 1
      }
    }

    private struct MountedTable {
      let markdown: SettledMarkdownView
      let transcript: RecordingTranscript
      let scrollView: TableScrollView
    }

    private static let proseRows: [[MarkdownText]] = (1...6).map { index in
      [
        MarkdownText("\(index)"),
        MarkdownText("Label logic (`AssistantTurnActivity.resolve`)"),
        MarkdownText(
          String(
            repeating: "Returns nil when a session status takes over or a tool call is running. ", count: index % 3 + 1)
        ),
      ]
    }

    private func mountTable(rows: [[MarkdownText]], width: CGFloat = 520) throws -> MountedTable {
      let transcript = RecordingTranscript(frame: NSRect(x: 0, y: 0, width: width + 80, height: 400))
      transcript.hasVerticalScroller = true
      let document = NSView(frame: NSRect(x: 0, y: 0, width: width + 80, height: 2_000))
      transcript.documentView = document
      let markdown = SettledMarkdownView(frame: NSRect(x: 40, y: 0, width: width, height: 1))
      document.addSubview(markdown)
      markdown.setContent(
        blocks: [
          .table(
            headers: [MarkdownText("#"), MarkdownText("Where"), MarkdownText("What hides it")],
            alignments: [],
            rows: rows
          )
        ],
        theme: .default,
        streamID: "table-hosting",
        linkAction: nil
      )
      markdown.frame.size.height = markdown.contentHeight(forWidth: width)
      markdown.layoutSubtreeIfNeeded()
      let table = try #require(markdown.subviews.first as? NativeMarkdownTableBlockView)
      let container = try #require(table.subviews.first as? TableBleedContainer)
      return MountedTable(markdown: markdown, transcript: transcript, scrollView: container.scrollView)
    }

    private func horizontalSwipe() throws -> NSEvent {
      let cgEvent = try #require(
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -24, wheel3: 0))
      return try #require(NSEvent(cgEvent: cgEvent))
    }

    @Test("The bordered table is exactly as tall as its measured row from the first layout")
    func tableMatchesMeasuredHeight() throws {
      let mounted = try mountTable(rows: Self.proseRows)
      let measured = mounted.markdown.contentHeight(forWidth: 520)
      let scrollView = mounted.scrollView

      #expect(scrollView.frame.height == measured)
      #expect(scrollView.documentView?.frame.height == measured)
      #expect(scrollView.tableTextView.frame.height == measured)
    }

    @Test("A table that fits hands horizontal swipes to the transcript; an overflowing one scrolls")
    func horizontalSwipesScrollOnlyOverflowingTables() throws {
      let fitting = try mountTable(rows: Self.proseRows)
      fitting.scrollView.scrollWheel(with: try horizontalSwipe())
      #expect(fitting.transcript.scrollEvents == 1)
      #expect(fitting.scrollView.contentView.bounds.minX == -fitting.scrollView.contentInsets.left)

      let wide = try mountTable(rows: [
        [MarkdownText(String(repeating: "unbreakable", count: 20)), MarkdownText("x"), MarkdownText("y")]
      ])
      wide.scrollView.scrollWheel(with: try horizontalSwipe())
      #expect(wide.transcript.scrollEvents == 0)
    }

    @Test("A redraw over a row separator reaches the text the separator is painted with")
    func separatorRedrawReachesText() throws {
      let textView = try mountTable(rows: Self.proseRows).scrollView.tableTextView
      let layoutManager = try #require(textView.layoutManager)
      let container = try #require(textView.textContainer)
      let storage = try #require(textView.textStorage)
      layoutManager.ensureLayout(for: container)

      var separators: [CGFloat] = []
      storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) {
        value, range, _ in
        guard let block = (value as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock,
          block.startingColumn == 0, block.startingRow < Self.proseRows.count
        else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        separators.append(layoutManager.boundsRect(for: block, glyphRange: glyphs).maxY)
      }
      #expect(separators.count == Self.proseRows.count)

      for separator in separators {
        let strip = NSRect(x: 0, y: separator - 1, width: textView.bounds.width, height: 1)
        // AppKit paints cell decorations only alongside glyphs; the
        // separator's own strip has none.
        #expect(layoutManager.glyphRange(forBoundingRect: strip, in: container).length == 0)
        let redraw = TableTextView.redrawRect(covering: strip, in: textView.bounds)
        #expect(layoutManager.glyphRange(forBoundingRect: redraw, in: container).length > 0)
      }
    }
  }
#endif
