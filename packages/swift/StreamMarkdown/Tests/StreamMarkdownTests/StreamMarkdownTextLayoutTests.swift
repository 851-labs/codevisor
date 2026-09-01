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
}
