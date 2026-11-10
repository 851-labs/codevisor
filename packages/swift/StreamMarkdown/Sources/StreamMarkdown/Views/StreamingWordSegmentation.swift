import Foundation

struct StreamingWordSegmentation {
  private var text = ""
  private var segments: [StreamingWordSegment] = []

  mutating func segments(for next: String) -> [StreamingWordSegment] {
    if next != text {
      segments = resegmented(next)
      text = next
    }
    return segments
  }

  mutating func reset() {
    self = StreamingWordSegmentation()
  }

  private func resegmented(_ next: String) -> [StreamingWordSegment] {
    guard let last = segments.last, next.hasPrefix(text), StreamingWordSegmenter.isASCII(next) else {
      return StreamingWordSegmenter.segments(in: next)
    }

    let restart = last.range.location
    let tail = (next as NSString).substring(from: restart)
    return segments.dropLast() + StreamingWordSegmenter.segments(in: tail).map { $0.offset(by: restart) }
  }
}
