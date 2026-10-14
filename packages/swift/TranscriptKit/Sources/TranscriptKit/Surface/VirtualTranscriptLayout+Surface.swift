import CoreGraphics
import Foundation

extension VirtualTranscriptLayout {
  /// The keys at the given indices, ignoring indices outside the layout.
  public func keys(in range: Range<Int>) -> Set<String> {
    Set(range.compactMap { index in keys.indices.contains(index) ? keys[index] : nil })
  }

  /// The contiguous index range covering exactly `keys`, or nil when the
  /// keys are empty, partly unknown, or not contiguous.
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

  /// The rendered window to persist for `keys`: anchored at the first known
  /// key and spanning through the last, even if the keys are not contiguous.
  public func renderedWindow(covering keys: Set<String>) -> (anchorKey: String, count: Int)? {
    let indices = keys.compactMap { indexByKey[$0] }.sorted()
    guard let first = indices.first, let last = indices.last,
      self.keys.indices.contains(first)
    else { return nil }
    return (self.keys[first], last - first + 1)
  }
}
