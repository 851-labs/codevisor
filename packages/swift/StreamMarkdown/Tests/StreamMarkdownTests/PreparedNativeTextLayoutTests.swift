#if canImport(AppKit)
  import AppKit
  import Testing
  @testable import StreamMarkdown

  @MainActor
  struct PreparedNativeTextLayoutTests {
    @Test func displayUsesTheStackPreparedByTheWorker() async throws {
      let source = NSAttributedString(
        string: String(repeating: "Wrapped text with café and 日本語. ", count: 300),
        attributes: [.font: NSFont.systemFont(ofSize: 15)]
      )
      let input = ImmutableText(source)
      let prepared = try await Task.detached {
        try PreparedNativeTextLayout(text: input.text, width: 360)
      }.value
      #expect(prepared.manager.firstUnlaidCharacterIndex() == source.length)
      let view = SelectableTextKitView(preparedLayout: prepared)
      #expect(view.layoutManager === prepared.manager)
      #expect(view.textStorage === prepared.storage)
      #expect(view.textContainer === prepared.container)
      #expect(view.string == source.string)
      #expect(view.contentHeight(forWidth: 360) == prepared.size.height)
      #expect(prepared.manager.firstUnlaidCharacterIndex() == source.length)
      view.setSelectedRange(NSRange(location: 0, length: 7))
      #expect(view.selectedRange() == NSRange(location: 0, length: 7))
    }

    @Test func resizeAndHighlightKeepSelectionAndPreparedGeometry() async throws {
      let source = ImmutableText(
        NSAttributedString(
          string: String(repeating: "let value = 42\n", count: 400),
          attributes: [.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)]
        ))
      let first = try await Task.detached { try PreparedNativeTextLayout(text: source.text, width: 360) }.value
      let view = SelectableTextKitView(preparedLayout: first)
      let selection = NSRange(location: 4, length: 5)
      view.setSelectedRange(selection)
      let resized = try await Task.detached { try PreparedNativeTextLayout(text: source.text, width: 220) }.value
      view.adoptPreparedLayout(resized)
      #expect(view.selectedRange() == selection)
      #expect(view.contentHeight(forWidth: 220) == resized.size.height)
      #expect(resized.manager.firstUnlaidCharacterIndex() == source.text.length)

      let colored = NSMutableAttributedString(attributedString: source.text)
      colored.addAttribute(
        .foregroundColor, value: NSColor.systemBlue, range: NSRange(location: 0, length: colored.length))
      resized.updateForegroundColors(from: colored)
      #expect(view.selectedRange() == selection)
      #expect(resized.manager.firstUnlaidCharacterIndex() == source.text.length)
      #expect(
        resized.manager.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor
          == .systemBlue)
    }

    @Test func preparedTableRetainsNativeCellsAndTSVCopying() async throws {
      let content = PreparedTextContent.table(
        headers: ["Name", "Value"], alignments: [.leading, .trailing],
        rows: [["Alpha", "42"], ["日本語", ""]], theme: .default
      )
      let layout = try await Task.detached { try content.prepare(width: 360, wrapsText: true) }.value
      let view = TableTextView(frame: CGRect(origin: .zero, size: layout.size), textContainer: layout.container)
      view.preparedWidth = layout.size.width
      #expect(view.layoutManager === layout.manager)
      #expect(layout.manager.firstUnlaidCharacterIndex() == layout.text.length)
      #expect(
        TableTextView.tsv(from: layout.storage, in: NSRange(location: 0, length: layout.text.length))
          == "Name\tValue\nAlpha\t42\n日本語\t")
    }

    private struct ImmutableText: @unchecked Sendable {
      let text: NSAttributedString
      init(_ text: NSAttributedString) { self.text = text }
    }
  }
#endif
