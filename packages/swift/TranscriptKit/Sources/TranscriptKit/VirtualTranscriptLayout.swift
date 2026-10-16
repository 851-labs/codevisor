import CoreGraphics
import Foundation

public struct VirtualTranscriptAnchor: Sendable, Equatable {
  public let key: String
  public let offsetFromRowTop: CGFloat

  public init(key: String, offsetFromRowTop: CGFloat) {
    self.key = key
    self.offsetFromRowTop = offsetFromRowTop
  }
}

public struct VirtualTranscriptLayout: Sendable, Equatable {
  public struct Item: Sendable, Equatable {
    public let key: String
    public let estimatedHeight: CGFloat
    public let spacingAfter: CGFloat?

    public init(key: String, estimatedHeight: CGFloat, spacingAfter: CGFloat? = nil) {
      self.key = key
      self.estimatedHeight = estimatedHeight
      self.spacingAfter = spacingAfter
    }
  }

  public let keys: [String]
  private let heightIndex: TranscriptHeightIndex
  public let indexByKey: [String: Int]
  public var totalHeight: CGFloat { heightIndex.totalHeight }

  public init(
    items: [Item],
    measuredHeights: [String: CGFloat],
    spacing: CGFloat
  ) {
    keys = items.map(\.key)
    indexByKey = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($0.element, $0.offset) })
    heightIndex = TranscriptHeightIndex(
      rows: items.enumerated().map { index, item in
        .init(
          height: max(1, measuredHeights[item.key] ?? item.estimatedHeight),
          spacing: index < items.count - 1 ? item.spacingAfter ?? spacing : 0
        )
      })
  }

  private init(keys: [String], indexByKey: [String: Int], heightIndex: TranscriptHeightIndex) {
    self.keys = keys
    self.indexByKey = indexByKey
    self.heightIndex = heightIndex
  }

  public func updatingHeights(_ updates: [String: CGFloat]) -> VirtualTranscriptLayout? {
    guard !updates.isEmpty else { return self }
    var replacements: [(index: Int, height: CGFloat)] = []
    replacements.reserveCapacity(updates.count)
    for (key, height) in updates {
      guard let index = indexByKey[key] else { return nil }
      replacements.append((index, max(1, height)))
    }
    return VirtualTranscriptLayout(
      keys: keys, indexByKey: indexByKey, heightIndex: heightIndex.replacing(replacements)
    )
  }

  public var isEmpty: Bool { keys.isEmpty }

  public func index(nearestToOffset offset: CGFloat) -> Int? {
    guard !keys.isEmpty else { return nil }
    let next = heightIndex.firstTopReaching(offset)
    if next < keys.count, frame(at: next).minY == offset { return next }
    let low = max(0, min(keys.count - 1, next - 1))
    let bottom = frame(at: low).maxY
    if offset > bottom, low + 1 < keys.count,
      offset - bottom > frame(at: low + 1).minY - offset
    {
      return low + 1
    }
    return low
  }

  public func frame(at index: Int) -> CGRect {
    guard keys.indices.contains(index) else { return .zero }
    let geometry = heightIndex.geometry(at: index)
    return CGRect(x: 0, y: geometry.top, width: 0, height: geometry.height)
  }

  public func viewportTop(distanceFromBottom: CGFloat, viewportHeight: CGFloat) -> CGFloat {
    max(0, totalHeight - max(0, viewportHeight) - max(0, distanceFromBottom))
  }

  public func distanceFromBottom(viewportTop: CGFloat, viewportHeight: CGFloat) -> CGFloat {
    max(0, totalHeight - (max(0, viewportTop) + max(0, viewportHeight)))
  }

  public func distanceFromBottom(
    preservingAnchor key: String,
    previousLayout: VirtualTranscriptLayout,
    previousDistanceFromBottom: CGFloat
  ) -> CGFloat? {
    guard let previousIndex = previousLayout.indexByKey[key],
      let nextIndex = indexByKey[key]
    else { return nil }
    let previousAnchorTopFromBottom = previousLayout.totalHeight - previousLayout.frame(at: previousIndex).minY
    let nextAnchorTopFromBottom = totalHeight - frame(at: nextIndex).minY
    return max(
      0,
      previousDistanceFromBottom
        + nextAnchorTopFromBottom
        - previousAnchorTopFromBottom
    )
  }

  public func visibleRange(
    distanceFromBottom: CGFloat,
    viewportHeight: CGFloat,
    overscanCount: Int
  ) -> Range<Int> {
    guard !keys.isEmpty else { return 0..<0 }
    let viewportTop = viewportTop(
      distanceFromBottom: distanceFromBottom,
      viewportHeight: viewportHeight
    )
    let viewportBottom = min(totalHeight, viewportTop + max(0, viewportHeight))
    let first = heightIndex.firstBottomExceeding(viewportTop)
    let end = heightIndex.firstTopReaching(viewportBottom)
    let start = max(0, first - max(0, overscanCount))
    let overscannedEnd = min(keys.count, max(first + 1, end) + max(0, overscanCount))
    return start..<overscannedEnd
  }

  public func visibleRange(
    distanceFromBottom: CGFloat,
    viewportHeight: CGFloat,
    runwayBefore: CGFloat,
    runwayAfter: CGFloat
  ) -> Range<Int> {
    guard !keys.isEmpty else { return 0..<0 }
    let viewportTop = viewportTop(
      distanceFromBottom: distanceFromBottom,
      viewportHeight: viewportHeight
    )
    let preparedTop = max(0, viewportTop - max(0, runwayBefore))
    let preparedBottom = min(
      totalHeight,
      viewportTop + max(0, viewportHeight) + max(0, runwayAfter)
    )
    let first = heightIndex.firstBottomExceeding(preparedTop)
    let end = heightIndex.firstTopReaching(preparedBottom)
    return first..<min(keys.count, max(first + 1, end))
  }

  public func renderedRange(anchorKey: String, count: Int) -> Range<Int>? {
    guard let start = indexByKey[anchorKey] else { return nil }
    return start..<min(keys.count, start + max(1, count))
  }

  public func viewportAnchor(at viewportTop: CGFloat) -> VirtualTranscriptAnchor? {
    guard !keys.isEmpty else { return nil }
    let index = heightIndex.firstBottomExceeding(viewportTop)
    return VirtualTranscriptAnchor(
      key: keys[index],
      offsetFromRowTop: viewportTop - frame(at: index).minY
    )
  }

  public func viewportTop(restoring anchor: VirtualTranscriptAnchor) -> CGFloat? {
    guard let index = indexByKey[anchor.key] else { return nil }
    return frame(at: index).minY + anchor.offsetFromRowTop
  }
}

public struct VirtualTranscriptViewport: Sendable, Equatable {
  public let contentHeight: CGFloat
  public let viewportHeight: CGFloat
  public let topInset: CGFloat
  public let bottomInset: CGFloat

  public init(
    contentHeight: CGFloat,
    viewportHeight: CGFloat,
    topInset: CGFloat = 0,
    bottomInset: CGFloat = 0
  ) {
    self.contentHeight = max(0, contentHeight)
    self.viewportHeight = max(0, viewportHeight)
    self.topInset = max(0, topInset)
    self.bottomInset = max(0, bottomInset)
  }

  public var minimumOffsetY: CGFloat { -topInset }

  public var maximumOffsetY: CGFloat {
    max(minimumOffsetY, contentHeight - viewportHeight + bottomInset)
  }

  public var maximumDistanceFromBottom: CGFloat {
    max(0, maximumOffsetY - minimumOffsetY)
  }

  public func boundedOffsetY(_ offsetY: CGFloat) -> CGFloat {
    min(max(minimumOffsetY, offsetY), maximumOffsetY)
  }

  public func distanceFromTop(offsetY: CGFloat) -> CGFloat {
    max(0, boundedOffsetY(offsetY) - minimumOffsetY)
  }

  public func distanceFromBottom(offsetY: CGFloat) -> CGFloat {
    max(0, maximumOffsetY - boundedOffsetY(offsetY))
  }

  public func offsetY(distanceFromBottom: CGFloat) -> CGFloat {
    boundedOffsetY(maximumOffsetY - max(0, distanceFromBottom))
  }
}
