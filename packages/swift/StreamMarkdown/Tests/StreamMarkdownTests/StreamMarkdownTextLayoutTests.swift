@testable import StreamMarkdown
import Testing

@Suite("Stream Markdown text layout")
struct StreamMarkdownTextLayoutTests {
  @Test("The native row width controls first layout before SwiftUI proposes a width")
  func authoritativeRowWidthControlsFirstLayout() {
    #expect(
      StreamMarkdownTextLayout.resolvedWidth(
        proposalWidth: nil,
        rowLayoutWidth: 320,
        fillsWidth: true,
        naturalWidth: 1_200
      ) == 320
    )
    #expect(
      StreamMarkdownTextLayout.resolvedWidth(
        proposalWidth: nil,
        rowLayoutWidth: 256,
        fillsWidth: false,
        naturalWidth: 1_200
      ) == 256
    )
    #expect(
      StreamMarkdownTextLayout.resolvedWidth(
        proposalWidth: 180,
        rowLayoutWidth: 320,
        fillsWidth: true,
        naturalWidth: 1_200
      ) == 180
    )
  }

  @Test("Updates without a row width keep the displayed width instead of unwrapping")
  func updatesKeepDisplayedWidth() {
    #expect(
      StreamMarkdownTextLayout.displayedWidth(
        currentWidth: 860,
        rowLayoutWidth: nil,
        fillsWidth: true,
        naturalWidth: 4_000
      ) == 860
    )
    #expect(
      StreamMarkdownTextLayout.displayedWidth(
        currentWidth: 0,
        rowLayoutWidth: nil,
        fillsWidth: true,
        naturalWidth: 4_000
      ) == nil
    )
    #expect(
      StreamMarkdownTextLayout.displayedWidth(
        currentWidth: 860,
        rowLayoutWidth: 320,
        fillsWidth: true,
        naturalWidth: 4_000
      ) == 320
    )
  }
}
