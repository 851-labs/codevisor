import CoreGraphics
import Foundation

/// A stable pixel coordinate inside one virtual row. Unlike a raw
/// bottom-relative distance, this survives height corrections elsewhere in
/// the document without moving the reader's visible content.
public struct VirtualTranscriptAnchor: Sendable, Equatable {
  public let key: String
  public let offsetFromRowTop: CGFloat

  public init(key: String, offsetFromRowTop: CGFloat) {
    self.key = key
    self.offsetFromRowTop = offsetFromRowTop
  }
}

/// Platform-neutral geometry for a bottom-anchored, variable-height transcript.
///
/// AppKit and UIKit adapters can share this layout: the platform scroll view
/// supplies its viewport while this type owns estimates, measured heights,
/// and bottom-relative visible-range lookup.
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

  /// Full geometry exports for persistence and diagnostics. Frame-time callers
  /// use `frame(at:)` so they only visit the rows they need.
  public var heights: [CGFloat] { heightIndex.allRows().map(\.height) }
  public var topOffsets: [CGFloat] {
    var top: CGFloat = 0
    return heightIndex.allRows().map { row in
      defer { top += row.extent }
      return top
    }
  }
  public var bottomOffsets: [CGFloat] {
    var top: CGFloat = 0
    return heightIndex.allRows().map { row in
      defer { top += row.extent }
      return totalHeight - top - row.height
    }
  }
  var updatedHeightNodeCount: Int { heightIndex.updatedNodeCount }

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

  public func updatingHeight(forKey key: String, to height: CGFloat) -> VirtualTranscriptLayout? {
    updatingHeights([key: height])
  }

  /// Copies only affected height-index paths. Existing layout snapshots keep
  /// their original geometry for restoration and animation. Unknown keys
  /// require a topology rebuild; unchanged subtrees are reused.
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

  /// The row containing `offset` (measured from the top of the first row).
  /// Spacing between two rows belongs to the nearer one, and offsets above
  /// or below the transcript clamp to its first and last row.
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

  /// Translates a bottom-relative viewport coordinate across a layout
  /// change while keeping the same row fixed in the viewport. Changes below
  /// the anchor increase the distance from the bottom; changes above it do
  /// not move the reader's content.
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

  /// Rows intersecting the viewport plus a small row-count overscan. Long
  /// chat turns make row-count overscan more useful than a fixed pixel band.
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
    let first = firstIndexWhoseBottomExceeds(viewportTop)
    let end = firstIndexWhoseTopReaches(viewportBottom)
    let start = max(0, first - max(0, overscanCount))
    let overscannedEnd = min(keys.count, max(first + 1, end) + max(0, overscanCount))
    return start..<overscannedEnd
  }

  /// Rows intersecting a viewport plus a geometry-based runway on either
  /// side. Unlike row-count overscan, this guarantees roughly the same
  /// amount of prepared scrolling across transcripts whose turns vary from
  /// one line to several screens tall.
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
    let first = firstIndexWhoseBottomExceeds(preparedTop)
    let end = firstIndexWhoseTopReaches(preparedBottom)
    return first..<min(keys.count, max(first + 1, end))
  }

  /// Stops row-count overscan at a heavy-content boundary. The boundary is
  /// still preloaded while approaching it, but overscan never reaches
  /// through to content on its far side. If a boundary is already visible,
  /// only naturally visible rows are returned.
  public static func overscanRange(
    visibleRange: Range<Int>,
    overscannedRange: Range<Int>,
    stoppingAt boundaryIndices: [Int]
  ) -> Range<Int> {
    guard !boundaryIndices.isEmpty else { return overscannedRange }
    if boundaryIndices.contains(where: { visibleRange.contains($0) }) {
      return visibleRange
    }
    if let below = boundaryIndices.first(where: { $0 >= visibleRange.upperBound }) {
      return visibleRange.lowerBound..<min(overscannedRange.upperBound, below + 1)
    }
    if let above = boundaryIndices.last(where: { $0 < visibleRange.lowerBound }) {
      return max(overscannedRange.lowerBound, above)..<visibleRange.upperBound
    }
    return overscannedRange
  }

  /// Recreates a previously rendered virtual window around its first key.
  /// Saved windows are advisory: missing keys fall back to the ordinary
  /// distance-based range and counts are clamped to the current transcript.
  public func renderedRange(anchorKey: String, count: Int) -> Range<Int>? {
    guard let start = indexByKey[anchorKey] else { return nil }
    return start..<min(keys.count, start + max(1, count))
  }

  /// Captures the row at the viewport's top edge and the exact pixel offset
  /// into that row. A top edge inside inter-row spacing is represented as a
  /// negative offset from the following row, preserving the gap exactly.
  public func viewportAnchor(at viewportTop: CGFloat) -> VirtualTranscriptAnchor? {
    guard !keys.isEmpty else { return nil }
    let index = firstIndexWhoseBottomExceeds(viewportTop)
    return VirtualTranscriptAnchor(
      key: keys[index],
      offsetFromRowTop: viewportTop - frame(at: index).minY
    )
  }

  /// Resolves a previously captured row-relative pixel coordinate in the
  /// current geometry. Missing rows deliberately return nil so callers can
  /// fall back to their bottom-relative coordinate.
  public func viewportTop(restoring anchor: VirtualTranscriptAnchor) -> CGFloat? {
    guard let index = indexByKey[anchor.key] else { return nil }
    return frame(at: index).minY + anchor.offsetFromRowTop
  }

  private func firstIndexWhoseBottomExceeds(_ value: CGFloat) -> Int {
    heightIndex.firstBottomExceeding(value)
  }

  private func firstIndexWhoseTopReaches(_ value: CGFloat) -> Int {
    heightIndex.firstTopReaching(value)
  }
}

/// Presentation-only displacement for rows retained across a send.
///
/// The scroll view commits the new layout and jumps to its bottom immediately.
/// A retained row can then start at this translation and animate to zero,
/// producing the visual "make room" motion without animating scroll state or
/// compromising the virtual layout's authoritative geometry.
public enum TranscriptSendHistoryTransition {
  /// FLIP displacement between a retained row's actual viewport positions.
  /// Using screen geometry makes a clamped short transcript produce zero
  /// motion while a bottom-pinned, scrollable transcript still makes room.
  public static func translationY(
    fromScreenY previousScreenY: CGFloat,
    toScreenY currentScreenY: CGFloat
  ) -> CGFloat {
    previousScreenY - currentScreenY
  }
}

/// Insets-aware scroll coordinates for the native transcript adapters.
///
/// UIKit represents the fully scrolled-to-top position as a negative content
/// offset when content is inset below navigation chrome. Keeping that range in
/// one platform-neutral value prevents the iOS virtualizer from accidentally
/// clamping the scroll view back to zero (which both loses the navigation-bar
/// underlap and corrupts bottom-relative restoration).
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
