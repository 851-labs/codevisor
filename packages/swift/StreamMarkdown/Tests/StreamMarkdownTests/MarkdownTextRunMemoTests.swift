import MarkdownCore
import SwiftUI
import Testing

@testable import StreamMarkdown

@MainActor
struct MarkdownTextRunMemoTests {
  @Test("Rendering a document as it streams in matches rendering the finished text from scratch")
  func streamedRenderMatchesFullRender() {
    let document = """
      # Findings

      The **layout** pass runs `twice` and links to [docs](https://example.com).

      - first item with `code`
      - second item

      > a quoted line that keeps growing as it streams
      """
    let memo = MarkdownTextRunMemo()
    var parser = IncrementalMarkdownParser()
    var source = ""
    for character in document {
      source.append(character)
      let blocks = parser.parse(source)
      let streamed = memo.rendered(for: blocks, theme: .default, foregroundColor: .primary)
      let full = MarkdownTextRunRenderer.attributedString(for: blocks, theme: .default, foregroundColor: .primary)

      #expect(streamed.string == full.string)
      #expect(Self.attributeRuns(streamed) == Self.attributeRuns(full))
    }
  }

  private static func attributeRuns(_ text: NSAttributedString) -> [String] {
    var runs: [String] = []
    text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
      let keys = attributes.keys.map(\.rawValue).sorted().joined(separator: ",")
      runs.append("\(range.location)+\(range.length):\(keys)")
    }
    return runs
  }
}
