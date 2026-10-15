import QuartzCore
import SwiftUI
#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

public struct ShimmerModifier: ViewModifier {
  var active: Bool

  public func body(content: Content) -> some View {
    content.overlay {
      if active {
        ShimmerSweep(shape: content)
      }
    }
  }
}

private struct ShimmerSweep<Shape: View>: View {
  let shape: Shape
  @Environment(\.colorScheme) private var colorScheme

  public var body: some View {
    PlatformShimmerView(colorScheme: colorScheme)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .mask(shape)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

@MainActor
final class ShimmerSweepLayer: CAGradientLayer {
  static let animationKey = "codevisor.text-shimmer"
  static let duration: CFTimeInterval = 1.2

  var mediaTime: () -> CFTimeInterval = CACurrentMediaTime
  private var animatedSize: CGSize = .zero
  private var renderedColorScheme: ColorScheme?

  override init() {
    super.init()
    startPoint = CGPoint(x: 0, y: 0.5)
    endPoint = CGPoint(x: 1, y: 0.5)
    locations = [0, 0.18, 0.42, 0.5, 0.58, 0.82, 1]
  }

  override init(layer: Any) {
    super.init(layer: layer)
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  func update(size: CGSize, colorScheme: ColorScheme) {
    guard size.width > 0, size.height > 0 else { return }

    let bandWidth = max(size.width * 0.33, 1)
    let geometryChanged = animatedSize != size
    if geometryChanged {
      removeAnimation(forKey: Self.animationKey)
    }

    if geometryChanged || renderedColorScheme != colorScheme {
      let primary = CGColor(
        gray: colorScheme == .dark ? 1 : 0,
        alpha: 1
      )
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      frame = CGRect(x: 0, y: 0, width: bandWidth, height: size.height)
      colors = [
        primary.copy(alpha: 0)!,
        primary.copy(alpha: 0)!,
        primary.copy(alpha: 0.9)!,
        primary,
        primary.copy(alpha: 0.9)!,
        primary.copy(alpha: 0)!,
        primary.copy(alpha: 0)!,
      ]
      CATransaction.commit()
    }

    animatedSize = size
    renderedColorScheme = colorScheme
    ensureAnimation(containerWidth: size.width, bandWidth: bandWidth)
  }

  private func ensureAnimation(containerWidth: CGFloat, bandWidth: CGFloat) {
    guard animation(forKey: Self.animationKey) == nil else { return }

    let sweep = CABasicAnimation(keyPath: "transform.translation.x")
    sweep.fromValue = -bandWidth
    sweep.toValue = containerWidth
    sweep.duration = Self.duration
    sweep.repeatCount = .infinity
    sweep.timingFunction = CAMediaTimingFunction(name: .linear)
    sweep.isRemovedOnCompletion = false
    let now = mediaTime()
    sweep.beginTime = convertTime(now, from: nil) - now.truncatingRemainder(dividingBy: Self.duration)
    add(sweep, forKey: Self.animationKey)
  }
}

#if canImport(AppKit)
  private struct PlatformShimmerView: NSViewRepresentable {
    let colorScheme: ColorScheme

    func makeNSView(context: Context) -> ShimmerLayerHostView {
      let view = ShimmerLayerHostView(frame: .zero)
      view.colorScheme = colorScheme
      return view
    }

    func updateNSView(_ nsView: ShimmerLayerHostView, context: Context) {
      nsView.colorScheme = colorScheme
      nsView.updateShimmer()
    }
  }

  @MainActor
  private final class ShimmerLayerHostView: NSView {
    let shimmerLayer = ShimmerSweepLayer()
    var colorScheme: ColorScheme = .light

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      wantsLayer = true
      layer?.addSublayer(shimmerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
      super.layout()
      updateShimmer()
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      updateShimmer()
    }

    func updateShimmer() {
      shimmerLayer.update(size: bounds.size, colorScheme: colorScheme)
    }
  }
#elseif canImport(UIKit)
  private struct PlatformShimmerView: UIViewRepresentable {
    let colorScheme: ColorScheme

    func makeUIView(context: Context) -> ShimmerLayerHostView {
      let view = ShimmerLayerHostView(frame: .zero)
      view.colorScheme = colorScheme
      return view
    }

    func updateUIView(_ uiView: ShimmerLayerHostView, context: Context) {
      uiView.colorScheme = colorScheme
      uiView.updateShimmer()
    }
  }

  @MainActor
  private final class ShimmerLayerHostView: UIView {
    let shimmerLayer = ShimmerSweepLayer()
    var colorScheme: ColorScheme = .light

    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false
      layer.addSublayer(shimmerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      updateShimmer()
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      updateShimmer()
    }

    func updateShimmer() {
      shimmerLayer.update(size: bounds.size, colorScheme: colorScheme)
    }
  }
#endif

extension View {
  public func shimmering(_ active: Bool = true) -> some View {
    modifier(ShimmerModifier(active: active))
  }
}

public struct ShimmeringText: View {
  var text: String = "Thinking..."
  var font: Font = .callout

  public init(text: String = "Thinking...", font: Font = .callout) {
    self.text = text
    self.font = font
  }

  public var body: some View {
    Text(text)
      .font(font)
      .foregroundStyle(.secondary)
      .shimmering()
      .accessibilityLabel(text)
  }

  public static var thinking: ShimmeringText {
    ShimmeringText(text: "Thinking...")
  }

  public static var startingAgent: ShimmeringText {
    ShimmeringText(text: "Starting agent...")
  }
}

#Preview {
  VStack(alignment: .leading, spacing: 8) {
    ShimmeringText.thinking
    ShimmeringText.startingAgent
  }
  .padding()
}
