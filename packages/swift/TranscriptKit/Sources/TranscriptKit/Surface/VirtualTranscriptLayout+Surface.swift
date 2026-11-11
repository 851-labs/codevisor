import CoreGraphics
import Foundation

extension VirtualTranscriptLayout {
  public func keys(in range: Range<Int>) -> Set<String> {
    Set(range.compactMap { index in keys.indices.contains(index) ? keys[index] : nil })
  }

  public func contiguousRange(of keys: Set<String>) -> Range<Int>? {
    guard !keys.isEmpty else { return nil }

    var lower = Int.max
    var upper = Int.min
    for key in keys {
      guard let index = indexByKey[key] else { return nil }
      lower = min(lower, index)
      upper = max(upper, index)
    }
    guard upper - lower + 1 == keys.count else { return nil }

    return lower..<(upper + 1)
  }

  public func renderedWindow(covering keys: Set<String>) -> (anchorKey: String, count: Int)? {
    let indices = keys.compactMap { indexByKey[$0] }.sorted()
    guard let first = indices.first, let last = indices.last,
      self.keys.indices.contains(first)
    else { return nil }
    return (self.keys[first], last - first + 1)
  }
}
