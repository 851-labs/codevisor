import AppKit
import SwiftUI

struct WorkspaceInspectorMeter: View {
  struct Segment {
    let color: Color
    let value: Double
  }

  struct Marker {
    let color: Color
    let value: Double
  }

  static let height: CGFloat = 8
  private static let track = adaptive(light: 0.065, dark: 0.08, increasedContrast: 0.16)
  private static let rim = adaptive(light: 0.08, dark: 0.04, increasedContrast: 0.5)
  private static let markerWidth: CGFloat = 2
  private static let markerHeight: CGFloat = 12
  private static let markerGap: CGFloat = 1

  let segments: [Segment]
  let total: Double
  var markers: [Marker] = []

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Self.track)
          .overlay(Capsule().strokeBorder(Self.rim, lineWidth: 0.5))
        HStack(spacing: 1) {
          ForEach(Array(segments.filter { $0.value > 0 }.enumerated()), id: \.offset) { _, segment in
            Rectangle()
              .fill(segment.color)
              .frame(width: max(width * fraction(segment.value) - 1, 1))
          }
        }
        .clipShape(Capsule())
        .mask { markerGaps(width: width) }
        ForEach(Array(markers.enumerated()), id: \.offset) { _, marker in
          Capsule()
            .fill(marker.color)
            .frame(width: Self.markerWidth, height: Self.markerHeight)
            .position(x: markerX(marker, width: width), y: Self.height / 2)
        }
      }
    }
    .frame(height: Self.height)
    .padding(.vertical, (Self.markerHeight - Self.height) / 2)
    .accessibilityRepresentation {
      ProgressView(value: fraction(segments.reduce(0) { $0 + $1.value }))
    }
  }

  private static func adaptive(light: CGFloat, dark: CGFloat, increasedContrast: CGFloat) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let alpha =
          NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? increasedContrast : isDark ? dark : light
        return (isDark ? NSColor.white : NSColor.black).withAlphaComponent(alpha)
      })
  }

  private func fraction(_ value: Double) -> Double {
    total > 0 ? min(max(value / total, 0), 1) : 0
  }

  private func markerX(_ marker: Marker, width: CGFloat) -> CGFloat {
    let inset = Self.markerWidth / 2 + Self.markerGap
    return min(max(width * fraction(marker.value), inset), width - inset)
  }

  private func markerGaps(width: CGFloat) -> some View {
    ZStack(alignment: .leading) {
      Rectangle()
      ForEach(Array(markers.enumerated()), id: \.offset) { _, marker in
        Rectangle()
          .frame(width: Self.markerWidth + Self.markerGap * 2)
          .position(x: markerX(marker, width: width), y: Self.height / 2)
          .blendMode(.destinationOut)
      }
    }
    .compositingGroup()
  }
}
