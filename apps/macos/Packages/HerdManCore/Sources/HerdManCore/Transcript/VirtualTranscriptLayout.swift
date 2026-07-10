import CoreGraphics
import Foundation

/// Platform-neutral geometry for a bottom-anchored, variable-height transcript.
///
/// AppKit and UIKit adapters can share this layout: the platform scroll view
/// supplies its viewport while this type owns estimates, measured heights,
/// and bottom-relative visible-range lookup.
public struct VirtualTranscriptLayout: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let key: String
        public let estimatedHeight: CGFloat

        public init(key: String, estimatedHeight: CGFloat) {
            self.key = key
            self.estimatedHeight = estimatedHeight
        }
    }

    public let keys: [String]
    public let heights: [CGFloat]
    public let topOffsets: [CGFloat]
    public let bottomOffsets: [CGFloat]
    public let totalHeight: CGFloat
    public let indexByKey: [String: Int]

    public init(
        items: [Item],
        measuredHeights: [String: CGFloat],
        spacing: CGFloat
    ) {
        var keys: [String] = []
        var heights: [CGFloat] = []
        var topOffsets: [CGFloat] = []
        var indexByKey: [String: Int] = [:]
        keys.reserveCapacity(items.count)
        heights.reserveCapacity(items.count)
        topOffsets.reserveCapacity(items.count)
        indexByKey.reserveCapacity(items.count)

        var cursor: CGFloat = 0
        for (index, item) in items.enumerated() {
            let height = max(1, measuredHeights[item.key] ?? item.estimatedHeight)
            keys.append(item.key)
            heights.append(height)
            topOffsets.append(cursor)
            indexByKey[item.key] = index
            cursor += height
            if index < items.count - 1 {
                cursor += spacing
            }
        }

        self.keys = keys
        self.heights = heights
        self.topOffsets = topOffsets
        self.totalHeight = cursor
        self.indexByKey = indexByKey
        self.bottomOffsets = topOffsets.enumerated().map { index, top in
            cursor - top - heights[index]
        }
    }

    public var isEmpty: Bool { keys.isEmpty }

    public func frame(at index: Int) -> CGRect {
        guard keys.indices.contains(index) else { return .zero }
        return CGRect(x: 0, y: topOffsets[index], width: 0, height: heights[index])
    }

    public func viewportTop(distanceFromBottom: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        max(0, totalHeight - max(0, viewportHeight) - max(0, distanceFromBottom))
    }

    public func distanceFromBottom(viewportTop: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        max(0, totalHeight - (max(0, viewportTop) + max(0, viewportHeight)))
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

    private func firstIndexWhoseBottomExceeds(_ value: CGFloat) -> Int {
        var low = 0
        var high = keys.count
        while low < high {
            let mid = (low + high) / 2
            let bottom = topOffsets[mid] + heights[mid]
            if bottom <= value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return min(low, keys.count - 1)
    }

    private func firstIndexWhoseTopReaches(_ value: CGFloat) -> Int {
        var low = 0
        var high = keys.count
        while low < high {
            let mid = (low + high) / 2
            if topOffsets[mid] < value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}
