#if canImport(AppKit)
  import AppKit
  import SwiftUI
  import Testing
  @testable import Autocomplete

  @Suite("Autocomplete layout")
  @MainActor
  struct LayoutTests {
    private struct Options {
      var fontSize: CGFloat = 13
      var query = ""
      var sizing = Autocomplete.Sizing.stable
      var rightToLeft = false
      var favorites: [String] = []
      var maximumHeight: CGFloat = 430
      var metrics: Autocomplete.Metrics {
        var metrics = Autocomplete.Metrics()
        metrics.fontSize = fontSize
        metrics.maximumHeight = maximumHeight
        return metrics
      }
    }

    private struct Fixture: View {
      let options: SelectionStore<Options>
      var body: some View {
        Autocomplete.Suggestions(
          query: Binding(
            get: { options.value.query }, set: { options.value.query = $0 })
        ) {
          Autocomplete.Picker("Projects", selection: .constant("none")) {
            Autocomplete.Choice("No project", value: "none", systemImage: "folder")
            Autocomplete.Choice("Résumé", value: "resume", systemImage: "folder.fill")
            Autocomplete.Choice("المشروع", value: "arabic", systemImage: "folder.fill")
          }.favorites(Binding(get: { options.value.favorites }, set: { options.value.favorites = $0 }))
        }
        .autocompleteStyle(.init(metrics: options.value.metrics, itemHighlight: .fill(.yellow, foreground: .black)))
        .autocompleteSizing(options.value.sizing)
        .environment(\.layoutDirection, options.value.rightToLeft ? .rightToLeft : .leftToRight)
        .environment(\.colorScheme, .light)
        .environment(\.locale, Locale(identifier: "en_US_POSIX"))
        .background(.white)
        .fixedSize()
      }
    }

    private func mount(_ options: SelectionStore<Options>) -> NSWindow {
      _ = NSApplication.shared
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.contentView = NSHostingView(rootView: Fixture(options: options))
      return window
    }

    private func settle(_ view: NSView) {
      // Resolve SwiftUI state before measuring, then lay out at the measured size.
      view.needsLayout = true
      view.layoutSubtreeIfNeeded()
      view.setFrameSize(view.fittingSize)
      view.layoutSubtreeIfNeeded()
      view.displayIfNeeded()
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
      if let match = view as? T { return match }
      return view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }

    private func highlightLast(in view: NSView) throws {
      let field = try #require(find(NSSearchField.self, in: view))
      let coordinator = try #require(field.delegate as? Autocomplete.InputField.Coordinator)
      // Search edits restore the first result. Move twice to the third result.
      for _ in 0..<2 {
        _ = coordinator.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:)))
      }
      settle(view)
    }

    private struct HighlightGeometry {
      let bottomGap: CGFloat
      let bottomCornerInset: CGFloat
    }

    /// Measure painted pixels rather than repeating the implementation's height
    /// arithmetic: font line boxes, scroll offsets, and stale geometry all matter.
    private func highlightGeometry(in view: NSView) throws -> HighlightGeometry {
      let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: rep)
      let scale = CGFloat(rep.pixelsWide) / view.bounds.width
      func isHighlight(_ x: Int, _ y: Int) -> Bool {
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
        return color.redComponent > 0.8 && color.greenComponent > 0.65 && color.blueComponent < 0.5
      }
      let bottom = try #require(
        (0..<rep.pixelsHigh).reversed().first { y in
          isHighlight(rep.pixelsWide / 2, y)
        })
      let firstPixel = try #require((0..<rep.pixelsWide).first { isHighlight($0, bottom) })
      return HighlightGeometry(
        bottomGap: CGFloat(rep.pixelsHigh - bottom - 1) / scale,
        bottomCornerInset: CGFloat(firstPixel) / scale - Autocomplete.Metrics.xcodeMenu.listHorizontalInset)
    }

    @Test("The final highlight hugs the bottom while font size changes repeatedly in both directions")
    func liveFontChanges() throws {
      let options = SelectionStore(Options())
      let window = mount(options)
      defer { window.contentView = nil }
      let view = try #require(window.contentView)
      settle(view)
      try highlightLast(in: view)
      // Sweep every size from the report, then stress larger sizes and shrink
      // again without remounting the control or its last row.
      for size in Array(13...24) + [36, 9, 32, 18, 24, 13] {
        options.value.fontSize = CGFloat(size)
        options.value.rightToLeft.toggle()
        settle(view)
        let geometry = try highlightGeometry(in: view)
        #expect(abs(geometry.bottomGap - options.value.metrics.listVerticalInset) <= 0.5, "Font size: \(size)")
        #expect(geometry.bottomCornerInset > 8, "Font size: \(size)")
      }
    }

    @Test("Filtering and favorite promotion update bottom corners without remounting the surface")
    func filteringAndReordering() throws {
      let options = SelectionStore(Options(fontSize: 24))
      let window = mount(options)
      defer { window.contentView = nil }
      let view = try #require(window.contentView)
      settle(view)
      try highlightLast(in: view)
      #expect(try highlightGeometry(in: view).bottomCornerInset > 8)
      options.value.query = "المشروع"
      settle(view)
      let filtered = try highlightGeometry(in: view)
      #expect(filtered.bottomGap > 50)
      #expect(filtered.bottomCornerInset < 8)
      options.value.sizing = .fitResults
      settle(view)
      #expect(try highlightGeometry(in: view).bottomGap <= 4.5)
      #expect(try highlightGeometry(in: view).bottomCornerInset > 8)
      options.value.query = ""
      options.value.sizing = .stable
      settle(view)
      try highlightLast(in: view)
      options.value.favorites = ["arabic"]
      settle(view)
      let promoted = try highlightGeometry(in: view)
      #expect(promoted.bottomGap > 50)
      #expect(promoted.bottomCornerInset < 8)
      options.value.favorites = []
      settle(view)
      #expect(try highlightGeometry(in: view).bottomCornerInset > 8)
    }

    @Test("The last row gains concentric corners after scrolling to the end of a capped list")
    func scrollingToBottom() throws {
      let options = SelectionStore(Options(fontSize: 24, maximumHeight: 160))
      let window = mount(options)
      defer { window.contentView = nil }
      let view = try #require(window.contentView)
      settle(view)
      try highlightLast(in: view)
      let scrollView = try #require(find(NSScrollView.self, in: view))
      let document = try #require(scrollView.documentView)
      document.scroll(NSPoint(x: 0, y: document.bounds.height))
      settle(view)
      let geometry = try highlightGeometry(in: view)
      #expect(geometry.bottomGap <= 4.5)
      #expect(geometry.bottomCornerInset > 8)
    }
  }
#endif
