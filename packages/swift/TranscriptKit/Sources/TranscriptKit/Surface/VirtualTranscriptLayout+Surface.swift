import CoreGraphics
import Foundation

extension VirtualTranscriptLayout {
  public func keys(in range: Range<Int>) -> Set<String> {
    Set(range.compactMap { index in keys.indices.contains(index) ? keys[index] : nil })
  }

  public func contiguousRange(of keys: Set<String>) -> Range<Int>? {
    guard !keys.isEmpty else { return nil }
    let indices = keys.compactMap { indexByKey[$0] }.sorted()
    guard indices.count == keys.count,
      let first = indices.first,
      let last = indices.last,
      last - first + 1 == indices.count
    else { return nil }
    return first..<(last + 1)
  }

  public func renderedWindow(covering keys: Set<String>) -> (anchorKey: String, count: Int)? {
    let indices = keys.compactMap { indexByKey[$0] }.sorted()
    guard let first = indices.first, let last = indices.last,
      self.keys.indices.contains(first)
    else { return nil }
    return (self.keys[first], last - first + 1)
  }
}
