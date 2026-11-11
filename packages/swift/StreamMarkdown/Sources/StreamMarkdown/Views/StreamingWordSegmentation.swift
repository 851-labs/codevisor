import Foundation

struct StreamingWordSegmentation {
  private var text = ""
  private var isASCII = true
  private var segments: [StreamingWordSegment] = []

  mutating func segments(for next: String) -> [StreamingWordSegment] {
    guard !Self.isSame(next, text) else { return segments }

    let grows = Self.grows(next, from: text)
    let nextIsASCII = grows && isASCII ? Self.tailIsASCII(next, after: text) : StreamingWordSegmenter.isASCII(next)
    segments = resegmented(next, grows: grows, nextIsASCII: nextIsASCII)
    text = next
    isASCII = nextIsASCII
    return segments
  }

  mutating func reset() {
    self = StreamingWordSegmentation()
  }

  private func resegmented(_ next: String, grows: Bool, nextIsASCII: Bool) -> [StreamingWordSegment] {
    guard grows, let restart = stableRestart(nextIsASCII: nextIsASCII) else {
      return StreamingWordSegmenter.segments(in: next, isASCII: nextIsASCII)
    }

    let location = segments[restart].range.location
    let tail = (next as NSString).substring(from: location)
    return segments[..<restart]
      + StreamingWordSegmenter.segments(in: tail, isASCII: nextIsASCII).map { $0.offset(by: location) }
  }

  private func stableRestart(nextIsASCII: Bool) -> Int? {
    guard !segments.isEmpty else { return nil }
    if nextIsASCII { return segments.count - 1 }
    guard !isASCII else { return nil }

    return lastParagraphStart()
  }

  private func lastParagraphStart() -> Int? {
    let string = text as NSString
    return segments.indices.last { StreamingWordSegmenter.isParagraphStart(segments[$0].range.location, in: string) }
  }

  private static func isSame(_ next: String, _ text: String) -> Bool {
    next.utf8.count == text.utf8.count && grows(next, from: text)
  }

  private static func grows(_ next: String, from text: String) -> Bool {
    var next = next
    var text = text
    return next.withUTF8 { nextBytes in
      text.withUTF8 { textBytes in
        guard nextBytes.count >= textBytes.count else { return false }
        guard let nextBase = nextBytes.baseAddress, let textBase = textBytes.baseAddress else { return true }
        return memcmp(nextBase, textBase, textBytes.count) == 0
      }
    }
  }

  private static func tailIsASCII(_ next: String, after text: String) -> Bool {
    next.utf8.dropFirst(text.utf8.count).allSatisfy { $0 <= 0x7f }
  }
}
