import Foundation
import Testing

@testable import StreamMarkdown

struct StreamingWordSegmentationTests {
  @Test(
    "Segmenting text as it grows matches segmenting the whole text at once",
    arguments: [
      "The layout pass runs twice, then settles. Done!",
      "Emoji 👩🏽‍💻 and 日本語テキスト mixed with ASCII words, then more text 🚀 here.",
      "  leading spaces and trailing punctuation...",
      "First paragraph — with a dash.\nSecond 日本語テキスト line\n🚀 emoji opens this one\r\nand don't split it.",
      "Plain ASCII don't first\nthen naïve café text\n\nand a third paragraph's words.",
    ])
  func growingTextMatchesFullSegmentation(_ document: String) {
    var segmentation = StreamingWordSegmentation()
    var text = ""
    for character in document {
      text.append(character)
      #expect(segmentation.segments(for: text) == StreamingWordSegmenter.segments(in: text), "Text: \(text)")
    }
  }

  @Test("An edit that rewrites earlier text segments the new text from scratch")
  func rewriteFallsBackToFullSegmentation() {
    var segmentation = StreamingWordSegmentation()
    _ = segmentation.segments(for: "one two three")

    #expect(segmentation.segments(for: "uno dos") == StreamingWordSegmenter.segments(in: "uno dos"))
  }
}
