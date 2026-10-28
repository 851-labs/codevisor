#if canImport(AppKit)
  import CoreGraphics
  import SwiftUI

  extension Autocomplete {
    struct PopperPlacement: Equatable {
      enum Edge: Equatable { case below, above }

      static let nativeMenuGap: CGFloat = 3
      static let screenInset: CGFloat = 5

      let frame: CGRect
      let edge: Edge

      static func resolve(
        size: CGSize, anchor: CGRect, visibleFrame: CGRect,
        layoutDirection: LayoutDirection = .leftToRight, preferring preferred: Edge = .below
      ) -> Self {
        let edge = edge(height: size.height, anchor: anchor, visibleFrame: visibleFrame, preferring: preferred)
        let origin = CGPoint(
          x: x(width: size.width, anchor: anchor, visibleFrame: visibleFrame, layoutDirection: layoutDirection),
          y: y(height: size.height, edge: edge, anchor: anchor, visibleFrame: visibleFrame))
        return Self(frame: CGRect(origin: origin, size: size), edge: edge)
      }

      static func availableHeight(anchor: CGRect, visibleFrame: CGRect) -> CGFloat {
        max(space(on: .below, anchor: anchor, visibleFrame: visibleFrame), space(on: .above, anchor: anchor, visibleFrame: visibleFrame))
      }

      private static func edge(height: CGFloat, anchor: CGRect, visibleFrame: CGRect, preferring preferred: Edge)
        -> Edge
      {
        let other: Edge = preferred == .below ? .above : .below
        let room = { (edge: Edge) in space(on: edge, anchor: anchor, visibleFrame: visibleFrame) }
        if room(preferred) >= height { return preferred }
        if room(other) >= height { return other }
        return room(preferred) >= room(other) ? preferred : other
      }

      private static func space(on edge: Edge, anchor: CGRect, visibleFrame: CGRect) -> CGFloat {
        switch edge {
        case .below: anchor.minY - nativeMenuGap - (visibleFrame.minY + screenInset)
        case .above: visibleFrame.maxY - screenInset - (anchor.maxY + nativeMenuGap)
        }
      }

      private static func x(width: CGFloat, anchor: CGRect, visibleFrame: CGRect, layoutDirection: LayoutDirection)
        -> CGFloat
      {
        let leading = layoutDirection == .rightToLeft ? anchor.maxX - width : anchor.minX
        let lowest = visibleFrame.minX + screenInset
        let highest = visibleFrame.maxX - screenInset - width
        return max(min(leading, highest), lowest)
      }

      private static func y(height: CGFloat, edge: Edge, anchor: CGRect, visibleFrame: CGRect) -> CGFloat {
        let attached = edge == .below ? anchor.minY - nativeMenuGap - height : anchor.maxY + nativeMenuGap
        let lowest = visibleFrame.minY + screenInset
        let highest = visibleFrame.maxY - screenInset - height
        return min(max(attached, lowest), highest)
      }
    }
  }
#endif
