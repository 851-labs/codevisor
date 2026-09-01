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
                cursor += item.spacingAfter ?? spacing
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

    /// Memberwise init for incremental copies — see `updatingHeight`.
    private init(
        keys: [String],
        heights: [CGFloat],
        topOffsets: [CGFloat],
        bottomOffsets: [CGFloat],
        totalHeight: CGFloat,
        indexByKey: [String: Int]
    ) {
        self.keys = keys
        self.heights = heights
        self.topOffsets = topOffsets
        self.bottomOffsets = bottomOffsets
        self.totalHeight = totalHeight
        self.indexByKey = indexByKey
    }

    /// A copy of this layout with one row's height replaced and every offset
    /// reconciled. This is the streaming hot path — the active row's height
    /// changes on nearly every flush — and the full initializer's cost is
    /// dominated by re-hashing every key into `indexByKey` (plus, at the call
    /// site, re-materializing every key string). Here `keys`/`indexByKey` are
    /// shared and the numeric arrays take one memcpy + a linear float pass:
    /// no hashing, no string work, no per-row allocation.
    ///
    /// Offset math (bottom-anchored): with `delta = newHeight - oldHeight`,
    /// rows after the change shift their top offsets by `delta`; rows before
    /// it move `delta` farther from the bottom; the changed row's own bottom
    /// offset and every other value are unchanged.
    ///
    /// Returns nil when `key` is absent — the caller must fall back to a full
    /// rebuild (row set changed).
    public func updatingHeight(forKey key: String, to height: CGFloat) -> VirtualTranscriptLayout? {
        updatingHeights([key: height])
    }

    /// Applies a display-frame's complete measurement batch with one numeric
    /// pass. Calling `updatingHeight` repeatedly copied and walked the layout
    /// arrays once per changed row; a window that settled several rows in the
    /// same frame therefore became O(rows × changes). This validates every key
    /// up front and computes the same top- and bottom-relative geometry in
    /// O(rows + changes).
    public func updatingHeights(_ updates: [String: CGFloat]) -> VirtualTranscriptLayout? {
        guard !updates.isEmpty else { return self }
        var replacements: [Int: CGFloat] = [:]
        replacements.reserveCapacity(updates.count)
        for (key, height) in updates {
            guard let index = indexByKey[key] else { return nil }
            replacements[index] = max(1, height)
        }

        var nextHeights = heights
        var nextTopOffsets = topOffsets
        var cumulativeDelta: CGFloat = 0
        for index in nextHeights.indices {
            nextTopOffsets[index] += cumulativeDelta
            guard let replacement = replacements[index] else { continue }
            cumulativeDelta += replacement - nextHeights[index]
            nextHeights[index] = replacement
        }
        guard
            cumulativeDelta != 0
                || replacements.contains(where: {
                    heights[$0.key] != $0.value
                })
        else { return self }

        let nextTotalHeight = totalHeight + cumulativeDelta
        var nextBottomOffsets = bottomOffsets
        for index in nextBottomOffsets.indices {
            nextBottomOffsets[index] =
                nextTotalHeight - nextTopOffsets[index] - nextHeights[index]
        }
        return VirtualTranscriptLayout(
            keys: keys,
            heights: nextHeights,
            topOffsets: nextTopOffsets,
            bottomOffsets: nextBottomOffsets,
            totalHeight: nextTotalHeight,
            indexByKey: indexByKey
        )
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
        let previousAnchorTopFromBottom =
            previousLayout.bottomOffsets[previousIndex]
            + previousLayout.heights[previousIndex]
        let nextAnchorTopFromBottom = bottomOffsets[nextIndex] + heights[nextIndex]
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
            offsetFromRowTop: viewportTop - topOffsets[index]
        )
    }

    /// Resolves a previously captured row-relative pixel coordinate in the
    /// current geometry. Missing rows deliberately return nil so callers can
    /// fall back to their bottom-relative coordinate.
    public func viewportTop(restoring anchor: VirtualTranscriptAnchor) -> CGFloat? {
        guard let index = indexByKey[anchor.key] else { return nil }
        return topOffsets[index] + anchor.offsetFromRowTop
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
