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

    @Test func aLiveViewThatDoesNotDrawGlyphsLeavesNoInk() throws {
      let text = NSAttributedString(
        string: "seamless", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black])
      let layout = try PreparedNativeTextLayout(text: text, width: 200)
      let live = SelectableTextKitView(preparedLayout: layout)
      live.frame = NSRect(origin: .zero, size: layout.size)

      live.drawsGlyphs = false
      let hidden = Self.ink(of: live)
      live.drawsGlyphs = true
      let drawn = Self.ink(of: live)

      #expect(hidden == 0)
      #expect(drawn > 0)
    }

    @Test func hoveringALinkUnderlinesTheWholeLinkBelowItsBaseline() async throws {
      let linkRange = NSRange(location: 8, length: 4)
      let request = StaticTextRequest(identity: 3, layout: .wrapping(width: 400, inset: 0), scale: 1, appearance: .aqua)
      {
        let text = NSMutableAttributedString(
          string: "see the docs here", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        text.addAttribute(.link, value: URL(string: "https://example.com")!, range: linkRange)
        return text
      }
      let prepared = try #require(await PreparedStaticText.prepare(request))
      let linkRect = try #require(StaticTextHitTesting.rects(in: prepared, for: linkRange).first)

      let hovered = StaticTextHitTesting.linkRange(in: prepared, at: NSPoint(x: linkRect.midX, y: linkRect.midY))
      let underlines = StaticTextHitTesting.underlineRects(in: prepared, for: linkRange)

      #expect(hovered == linkRange)
      #expect(underlines.count == 1)
      #expect(abs((underlines.first?.minX ?? 0) - linkRect.minX) < 1)
      #expect((underlines.first?.midY ?? 0) > linkRect.midY)
      #expect((underlines.first?.maxY ?? .infinity) <= linkRect.maxY + 1)
    }

    private static func ink(of view: NSView) -> Int {
      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
      view.cacheDisplay(in: view.bounds, to: rep)
      var total = 0
      for x in 0..<rep.pixelsWide {
        for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { total += 1 }
      }
      return total
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
