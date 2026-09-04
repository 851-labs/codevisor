#if canImport(AppKit)
  import AppKit
  import Testing
  @testable import Autocomplete

  @Suite("Autocomplete item geometry")
  @MainActor
  struct ItemGeometryTests {
    private func host(height: CGFloat = 300) -> Autocomplete.Host {
      let host = Autocomplete.Host()
      host.popupHeight = height
      host.contents.targets = [
        .init(id: "first", kind: .item),
        .init(id: "last", kind: .item),
      ]
      return host
    }

    @Test("A filtered final result uses ordinary corners above unused list space")
    func filteredResult() {
      let host = host()
      host.contents = .init(query: "fast", targets: [.init(id: "fast", kind: .item)])
      #expect(!host.isBottomItem("fast", bottom: 88, inset: 4))

      // A popup that actually shrinks to that result can still be concentric.
      host.popupHeight = 92
      #expect(host.isBottomItem("fast", bottom: 88, inset: 4))
    }

    @Test("Only the last row at the visible bottom gets concentric corners")
    func finalRow() {
      let host = host()
      #expect(host.isBottomItem("last", bottom: 296, inset: 4))
      #expect(!host.isBottomItem("first", bottom: 296, inset: 4))
      #expect(!host.isBottomItem("last", bottom: 270, inset: 4))
      #expect(!host.isBottomItem("last", bottom: 320, inset: 4))
    }

    @Test("Pinned footers use their own inset and exclude the final scrolling row")
    func pinnedFooter() {
      let host = host()
      host.contents.targets.append(.init(id: "footer", kind: .item))
      #expect(!host.isBottomItem("last", bottom: 296, inset: 4))
      #expect(host.isBottomItem("footer", bottom: 295, inset: 5))
      #expect(!host.isBottomItem("footer", bottom: 270, inset: 5))
    }

    @Test("Geometry must be measured before a row uses concentric corners")
    func unmeasuredLayout() {
      let host = host()
      #expect(!host.isBottomItem("last", bottom: nil, inset: 4))
      host.popupHeight = nil
      #expect(!host.isBottomItem("last", bottom: 296, inset: 4))
      host.popupHeight = 0
      #expect(!host.isBottomItem("last", bottom: -4, inset: 4))
    }

    @Test("A fractional layout difference preserves bottom alignment")
    func layoutRounding() {
      let host = host()
      #expect(host.isBottomItem("last", bottom: 295.5, inset: 4))
      #expect(host.isBottomItem("last", bottom: 296.5, inset: 4))
    }
  }
#endif
