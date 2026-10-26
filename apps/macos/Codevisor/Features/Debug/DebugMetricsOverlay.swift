import AppKit
import CodevisorUI
import Darwin
import Observation
import QuartzCore
import SwiftUI

struct DebugMetricsOverlayModifier: ViewModifier {
  @State private var model = DebugMetricsModel()
  private let actionID = UUID()

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .bottomLeading) {
        if model.isVisible {
          DebugMetricsOverlay(model: model)
            .padding(12)
        }
      }
      .focusedSceneValue(
        \.debugOverlayToggle,
        DebugOverlayToggleAction(id: actionID, isVisible: model.isVisible) { model.toggle() }
      )
  }
}

private struct DebugMetricsOverlay: View {
  let model: DebugMetricsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("Performance", systemImage: "gauge.with.dots.needle.50percent")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.white.opacity(0.72))
        Spacer()
        Text("\(ShortcutCatalog.display(for: .toggleDebugOverlay)) to hide")
          .font(.system(size: Typography.minimumTextSize, weight: .medium, design: .monospaced))
          .foregroundStyle(.white.opacity(0.6))
      }

      HStack(spacing: 8) {
        PrimaryMetric(
          title: "FPS",
          value: model.framesPerSecond.formatted(.number.precision(.fractionLength(1))),
          tint: frameTint
        )
        PrimaryMetric(
          title: "FRAME TIME",
          value: "\(model.frameDurationMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms",
          tint: frameTint
        )
      }

      FrameDurationMeter(samples: model.frameDurations)
        .frame(height: 52)

      Divider()
        .overlay(.white.opacity(0.12))

      ResourceMetric(
        title: "CPU",
        value: "\(model.cpuPercent.formatted(.number.precision(.fractionLength(1))))%",
        fraction: model.cpuPercent / 100,
        tint: .cyan
      )
      ResourceMetric(
        title: "MEMORY",
        value: ByteCountFormatter.string(fromByteCount: Int64(model.memoryBytes), countStyle: .memory),
        fraction: model.memoryFraction,
        tint: .purple
      )
    }
    .padding(12)
    .frame(width: 320)
    .background(.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(.white.opacity(0.18), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
    .overlay { DisplayFrameProbe(model: model).frame(width: 1, height: 1) }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private var frameTint: Color {
    switch model.frameDurationMilliseconds {
    case ..<(model.targetFrameDurationMilliseconds * 1.25): .green
    case ..<(model.targetFrameDurationMilliseconds * 2.25): .yellow
    default: .orange
    }
  }
}

private struct PrimaryMetric: View {
  let title: String
  let value: String
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.system(size: Typography.minimumTextSize, weight: .bold, design: .monospaced))
        .foregroundStyle(.white.opacity(0.6))
      Text(value)
        .font(.system(size: 19, weight: .semibold, design: .monospaced))
        .foregroundStyle(tint)
        .contentTransition(.numericText())
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct ResourceMetric: View {
  let title: String
  let value: String
  let fraction: Double
  let tint: Color

  var body: some View {
    VStack(spacing: 5) {
      HStack {
        Text(title)
          .font(.system(size: Typography.minimumTextSize, weight: .bold, design: .monospaced))
          .foregroundStyle(.white.opacity(0.6))
        Spacer()
        Text(value)
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .foregroundStyle(.white.opacity(0.9))
          .contentTransition(.numericText())
      }
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule().fill(.white.opacity(0.1))
          Capsule()
            .fill(tint)
            .frame(width: proxy.size.width * min(max(fraction, 0), 1))
        }
      }
      .frame(height: 4)
    }
  }
}

private struct FrameDurationMeter: View {
  let samples: [Double]

  var body: some View {
    Canvas { context, size in
      let visibleSamples = Array(samples.suffix(60))
      let maximumSample = min(max(visibleSamples.max() ?? 16.67, 33.33), 100)

      var threshold = Path()
      let thresholdY = size.height - size.height * 16.67 / maximumSample
      threshold.move(to: CGPoint(x: 0, y: thresholdY))
      threshold.addLine(to: CGPoint(x: size.width, y: thresholdY))
      context.stroke(
        threshold, with: .color(.white.opacity(0.16)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

      guard !visibleSamples.isEmpty else { return }
      let spacing = 1.5
      let barWidth = max(
        (size.width - spacing * CGFloat(visibleSamples.count - 1)) / CGFloat(visibleSamples.count), 1)

      for (index, sample) in visibleSamples.enumerated() {
        let cappedSample = min(sample, maximumSample)
        let height = max(size.height * cappedSample / maximumSample, 1)
        let rect = CGRect(
          x: CGFloat(index) * (barWidth + spacing),
          y: size.height - height,
          width: barWidth,
          height: height
        )
        let color: Color =
          switch sample {
          case ..<18: .green
          case ..<34: .yellow
          default: .orange
          }
        context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color.opacity(0.9)))
      }
    }
    .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
  }
}

private struct DisplayFrameProbe: NSViewRepresentable {
  let model: DebugMetricsModel

  func makeNSView(context: Context) -> DisplayFrameProbeView {
    DisplayFrameProbeView(model: model)
  }

  func updateNSView(_ view: DisplayFrameProbeView, context: Context) {
    view.model = model
  }

  static func dismantleNSView(_ view: DisplayFrameProbeView, coordinator: Void) {
    view.stop()
  }
}

private final class DisplayFrameProbeView: NSView {
  weak var model: DebugMetricsModel?
  private var frameDisplayLink: CADisplayLink?

  init(model: DebugMetricsModel) {
    self.model = model
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    stop()

    guard let window else { return }
    model?.configureDisplay(for: window)
    let link = displayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
    let rate = Float(max(1, window.screen?.maximumFramesPerSecond ?? 60))
    link.preferredFrameRateRange = CAFrameRateRange(
      minimum: rate,
      maximum: rate,
      preferred: rate
    )
    link.add(to: .main, forMode: .common)
    frameDisplayLink = link
  }

  func stop() {
    frameDisplayLink?.invalidate()
    frameDisplayLink = nil
  }

  @objc private func displayLinkDidFire(_ displayLink: CADisplayLink) {
    model?.recordFrame(at: displayLink.timestamp)
  }
}

struct DebugOverlayToggleAction: Equatable {
  let id: UUID
  let isVisible: Bool
  let toggle: @MainActor () -> Void

  static func == (lhs: DebugOverlayToggleAction, rhs: DebugOverlayToggleAction) -> Bool {
    lhs.id == rhs.id && lhs.isVisible == rhs.isVisible
  }
}

private struct DebugOverlayToggleKey: FocusedValueKey {
  typealias Value = DebugOverlayToggleAction
}

extension FocusedValues {
  var debugOverlayToggle: DebugOverlayToggleAction? {
    get { self[DebugOverlayToggleKey.self] }
    set { self[DebugOverlayToggleKey.self] = newValue }
  }
}

struct DebugOverlayCommands: Commands {
  var body: some Commands {
    CommandGroup(after: .toolbar) {
      DebugOverlayMenuItem()
    }
  }
}

private struct DebugOverlayMenuItem: View {
  @FocusedValue(\.debugOverlayToggle) private var action

  var body: some View {
    ShortcutButton(.toggleDebugOverlay) { action?.toggle() }
      .disabled(action == nil)
  }
}
