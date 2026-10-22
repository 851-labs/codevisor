#if canImport(AppKit)
  import AppKit
  import CodevisorTestSupport
  import MarkdownCore
  import Testing

  @testable import StreamMarkdown

  @MainActor
  struct StaticTextSurfaceTests {
    @Test func hitTestingMapsPointsAndRangesThroughThePreparedLayout() async throws {
      let string = "first line\nsecond line"
      let request = StaticTextRequest(identity: 1, layout: .wrapping(width: 400, inset: 4), scale: 1, appearance: .aqua)
      {
        NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: 13)])
      }
      let prepared = try #require(await PreparedStaticText.prepare(request))
      let length = (string as NSString).length
      let surface = StaticTextSurfaceView(frame: NSRect(origin: .zero, size: prepared.size))
      surface.show(prepared)

      #expect(surface.transcriptCharacterIndex(at: NSPoint(x: 0, y: 0)) == 0)
      #expect(surface.transcriptCharacterIndex(at: NSPoint(x: 1_000, y: prepared.size.height - 2)) == length)
      let secondLine = surface.transcriptTextRects(for: NSRange(location: 11, length: 6))
      let firstLine = surface.transcriptTextRects(for: NSRange(location: 0, length: 5))
      #expect(secondLine.count == 1)
      #expect((secondLine.first?.minY ?? 0) > (firstLine.first?.minY ?? 0))
      #expect(surface.transcriptPlainText(in: NSRange(location: 6, length: 4)) == "line")
    }

    @Test func leavingTheWindowReleasesThePreparedBitmap() async throws {
      let request = StaticTextRequest(identity: 2, layout: .wrapping(width: 200, inset: 0), scale: 1, appearance: .aqua)
      {
        NSAttributedString(string: "release me", attributes: [.font: NSFont.systemFont(ofSize: 13)])
      }
      let prepared = try #require(await PreparedStaticText.prepare(request))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [], backing: .buffered, defer: true)
      let surface = StaticTextSurfaceView(frame: NSRect(origin: .zero, size: prepared.size))
      window.contentView?.addSubview(surface)
      surface.show(prepared)
      #expect(surface.prepared != nil)

      surface.removeFromSuperview()

      #expect(surface.prepared == nil)
      #expect(surface.transcriptText.length == 0)
    }

    @Test func proseReportsAnEstimateUntilPreparedThenTheExactHeight() async {
      let blocks = MarkdownParser().parse(
        "A paragraph with **bold** text that wraps across a couple of lines in a narrow view.")
      let view = StaticMarkdownTextContentView(
        blocks: blocks, theme: .default, streamID: "static-test-\(UUID().uuidString)", linkAction: nil)
      let prepared = TestSignal()
      view.onContentChange = { prepared.signal() }

      let estimate = view.contentHeight(forWidth: 160)
      #expect(!view.isContentReady)

      await prepared.wait()
      let exact = view.contentHeight(forWidth: 160)
      #expect(view.isContentReady)
      #expect(exact > 1)
      #expect(estimate > 1)
    }
  }
#endif
