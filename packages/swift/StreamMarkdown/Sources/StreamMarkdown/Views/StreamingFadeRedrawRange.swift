import Foundation

enum StreamingFadeRedrawRange {
  static func union(
    of activeRanges: [NSRange],
    in text: NSAttributedString,
    at time: TimeInterval,
    includesCompletedRanges: Bool
  ) -> NSRange? {
    activeRanges.reduce(nil) { union, range in
      guard needsRedraw(range, in: text, at: time, includesCompletedRanges: includesCompletedRanges) else {
        return union
      }
      return union.map { NSUnionRange($0, range) } ?? range
    }
  }

  private static func needsRedraw(
    _ range: NSRange,
    in text: NSAttributedString,
    at time: TimeInterval,
    includesCompletedRanges: Bool
  ) -> Bool {
    guard NSMaxRange(range) <= text.length,
      let fade = text.attribute(.streamMarkdownFade, at: range.location, effectiveRange: nil)
        as? StreamingTextFadeMetadata
    else { return false }

    return includesCompletedRanges || fade.animationEndTime > time
  }
}
