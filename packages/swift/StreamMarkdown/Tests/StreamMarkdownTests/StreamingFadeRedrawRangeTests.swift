import Foundation
import Testing

@testable import StreamMarkdown

struct StreamingFadeRedrawRangeTests {
  private let finished = NSRange(location: 0, length: 4)
  private let fading = [NSRange(location: 5, length: 3), NSRange(location: 9, length: 2)]

  private var text: NSAttributedString {
    let text = NSMutableAttributedString(string: "done one two three")
    let fade = StreamingTextAnimationSpec.fadeDuration
    text.addAttribute(.streamMarkdownFade, value: StreamingTextFadeMetadata(startTime: -fade * 2), range: finished)
    for range in fading {
      text.addAttribute(.streamMarkdownFade, value: StreamingTextFadeMetadata(startTime: 0), range: range)
    }
    return text
  }

  @Test("One redraw covers every range still fading and skips finished ones")
  func unionsUnfinishedRanges() {
    let range = StreamingFadeRedrawRange.union(
      of: [finished] + fading, in: text, at: 0, includesCompletedRanges: false)

    #expect(range == NSRange(location: 5, length: 6))
  }

  @Test("A final redraw also covers ranges whose fade has finished")
  func includesCompletedRangesWhenAsked() {
    let range = StreamingFadeRedrawRange.union(
      of: [finished] + fading, in: text, at: 0, includesCompletedRanges: true)

    #expect(range == NSRange(location: 0, length: 11))
  }

  @Test("Nothing is redrawn once every fade has finished")
  func returnsNilWhenSettled() {
    let range = StreamingFadeRedrawRange.union(
      of: [finished], in: text, at: 0, includesCompletedRanges: false)

    #expect(range == nil)
  }
}
