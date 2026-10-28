import AppKit
import CodevisorUI
import SwiftUI

struct WorkspaceInspectorMeter: View {
  struct Segment: Equatable {
    let color: Color
    let value: Double
  }

  struct Marker: Equatable {
    let color: Color
    let value: Double
  }

  private struct Reveal: Equatable {
    var count = 0
    var delay: TimeInterval = 0
  }

  static let height: CGFloat = 8
  private static let track = adaptive(light: 0.065, dark: 0.08, increasedContrast: 0.16)
  private static let rim = adaptive(light: 0.08, dark: 0.04, increasedContrast: 0.5)
  private static let markerWidth: CGFloat = 2
  private static let markerHeight: CGFloat = 12
  private static let markerGap: CGFloat = 1
  private static let inspectorSlideDuration = Motion.splitDuration

  let segments: [Segment]
  let total: Double
  var markers: [Marker] = []
  @Environment(\.self) private var environment
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isWorkspaceInspectorVisible) private var isInspectorVisible
  @State private var reveal = Reveal()

  var body: some View {
    KeyframeAnimator(initialValue: 1.0, trigger: reveal) { progress in
      bar(progress: progress)
    } keyframes: { _ in
      MoveKeyframe(0.0)
      if reveal.delay > 0 {
        LinearKeyframe(0.0, duration: reveal.delay)
      } else {
        MoveKeyframe(0.0)
      }
      SpringKeyframe(1.0, duration: Motion.meterDuration, spring: .smooth(duration: Motion.meterDuration))
    }
    .frame(height: Self.height)
    .onAppear { if isInspectorVisible { replayReveal(after: 0) } }
    .onChange(of: isInspectorVisible) { _, isVisible in
      if isVisible { replayReveal(after: Self.inspectorSlideDuration) }
    }
    .padding(.vertical, (Self.markerHeight - Self.height) / 2)
    .accessibilityRepresentation {
      ProgressView(value: fraction(segments.reduce(0) { $0 + $1.value }))
    }
  }

  private func bar(progress: Double) -> some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Self.track)
          .overlay(Capsule().strokeBorder(Self.rim, lineWidth: 0.5))
        HStack(spacing: 0) {
          ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
            let span = span(segment, width: width) * progress
            WorkspaceInspectorMeterFill(shape: Rectangle(), color: segment.color.resolve(in: environment))
              .frame(width: max(span - 1, 0))
              .padding(.trailing, min(span, 1))
          }
        }
        .clipShape(Capsule())
        .mask { markerGaps(width: width, progress: progress) }
        ForEach(Array(markers.enumerated()), id: \.offset) { _, marker in
          WorkspaceInspectorMeterFill(shape: Capsule(), color: marker.color.resolve(in: environment))
            .frame(width: Self.markerWidth, height: Self.markerHeight)
            .position(x: markerX(marker, width: width, progress: progress), y: Self.height / 2)
        }
      }
      .animation(Motion.meter(reduceMotion: reduceMotion), value: segments)
      .animation(Motion.meter(reduceMotion: reduceMotion), value: markers)
      .animation(Motion.meter(reduceMotion: reduceMotion), value: total)
    }
  }

  private func replayReveal(after delay: TimeInterval) {
    guard !reduceMotion else { return }
    reveal = Reveal(count: reveal.count + 1, delay: delay)
  }

  private static func adaptive(light: CGFloat, dark: CGFloat, increasedContrast: CGFloat) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let alpha =
          if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            increasedContrast
          } else if isDark {
            dark
          } else {
            light
          }
        return (isDark ? NSColor.white : NSColor.black).withAlphaComponent(alpha)
      })
  }

  private func fraction(_ value: Double) -> Double {
    total > 0 ? min(max(value / total, 0), 1) : 0
  }

  private func span(_ segment: Segment, width: CGFloat) -> CGFloat {
    segment.value > 0 ? max(width * fraction(segment.value), 2) : 0
  }

  private func markerX(_ marker: Marker, width: CGFloat, progress: Double) -> CGFloat {
    let inset = Self.markerWidth / 2 + Self.markerGap
    return min(max(width * fraction(marker.value) * progress, inset), width - inset)
  }

  private func markerGaps(width: CGFloat, progress: Double) -> some View {
    ZStack(alignment: .leading) {
      Rectangle()
      ForEach(Array(markers.enumerated()), id: \.offset) { _, marker in
        Rectangle()
          .frame(width: Self.markerWidth + Self.markerGap * 2)
          .position(x: markerX(marker, width: width, progress: progress), y: Self.height / 2)
          .blendMode(.destinationOut)
      }
    }
    .compositingGroup()
  }
}

private struct WorkspaceInspectorMeterFill<S: Shape>: View, Animatable {
  let shape: S
  var color: Color.Resolved

  var animatableData: Color.Resolved.AnimatableData {
    get { color.animatableData }
    set { color.animatableData = newValue }
  }

  var body: some View {
    shape.fill(Color(color))
  }
}
