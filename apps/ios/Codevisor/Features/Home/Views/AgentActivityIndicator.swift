import SwiftUI
import UIKit

/// The macOS sidebar's Herdr-inspired working glyph, ported: ten braille
/// frames advancing at roughly eight steps per second in a chat row's icon
/// slot.
///
/// As on macOS, the frame cycle is a `CAKeyframeAnimation` on a layer's
/// `contents` rather than a `TimelineView` — the render server keeps it
/// stepping through main-thread hitches (a transcript rebuild, a large list
/// diff) that would freeze any SwiftUI-driven frame swap. The glyphs are
/// rasterized against the row's color, so callers pass the color the row
/// would otherwise have applied.
struct AgentActivityIndicator: View {
  var color: Color = .secondary

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    BrailleSpinnerLayer(
      color: color, colorScheme: colorScheme,
      isAnimated: !reduceMotion && scenePhase == .active
    )
    .frame(width: BrailleSpinnerFrames.size.width, height: BrailleSpinnerFrames.size.height)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Working")
  }
}

/// The ten braille frames, pre-rasterized per (color, appearance, scale).
@MainActor
private enum BrailleSpinnerFrames {
  static let glyphs = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  /// A braille cell is narrow and about half an em tall, so it renders a
  /// size up from the row text to read at the same visual weight as the
  /// kind glyphs beside it.
  static let pointSize: CGFloat = 20
  static let size = CGSize(width: 20, height: 20)
  static let cycleDuration = Double(glyphs.count) / 8

  private struct Key: Hashable {
    let color: Color
    let colorScheme: ColorScheme
    let scale: CGFloat
  }

  private static var cache: [Key: [CGImage]] = [:]

  static func images(color: Color, colorScheme: ColorScheme, scale: CGFloat) -> [CGImage] {
    let key = Key(color: color, colorScheme: colorScheme, scale: scale)
    if let cached = cache[key] { return cached }
    let images = glyphs.compactMap { render($0, color: color, colorScheme: colorScheme, scale: scale) }
    guard images.count == glyphs.count else { return images }
    cache[key] = images
    return images
  }

  private static func render(
    _ glyph: String,
    color: Color,
    colorScheme: ColorScheme,
    scale: CGFloat
  ) -> CGImage? {
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = false
    // `.secondary` and friends resolve per appearance; bake them against
    // the row's current scheme.
    let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
    let resolved = UIColor(color).resolvedColor(with: traits)
    let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
      let text = NSAttributedString(
        string: glyph,
        attributes: [
          .font: UIFont.monospacedSystemFont(ofSize: pointSize, weight: .regular),
          .foregroundColor: resolved,
        ]
      )
      let bounds = text.boundingRect(
        with: size, options: [.usesLineFragmentOrigin], context: nil
      )
      text.draw(
        at: CGPoint(
          x: (size.width - bounds.width) / 2,
          y: (size.height - bounds.height) / 2
        ))
    }
    return image.cgImage
  }
}

/// Hosts the pre-rasterized frames on a layer and cycles them in the render
/// server, phase-aligned so every spinner on screen steps in lockstep.
private struct BrailleSpinnerLayer: UIViewRepresentable {
  let color: Color
  let colorScheme: ColorScheme
  let isAnimated: Bool

  func makeUIView(context: Context) -> BrailleSpinnerView {
    BrailleSpinnerView(frame: .zero)
  }

  func updateUIView(_ view: BrailleSpinnerView, context: Context) {
    view.update(color: color, colorScheme: colorScheme, isAnimated: isAnimated)
  }
}

/// Owns the animation independently of SwiftUI's row updates. A cached pixel
/// configuration does not imply that an animation survived a window change.
@MainActor
final class BrailleSpinnerView: UIView {
  private static let animationKey = "brailleFrames"
  private let glyphLayer = CALayer()
  private var color: Color = .secondary
  private var colorScheme: ColorScheme = .light
  private var isAnimated = false
  private var renderedConfiguration: RenderConfiguration?
  private var images: [CGImage] = []

  private struct RenderConfiguration: Equatable {
    let color: Color
    let colorScheme: ColorScheme
    let scale: CGFloat
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    glyphLayer.contentsGravity = .resizeAspect
    layer.addSublayer(glyphLayer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(color: Color, colorScheme: ColorScheme, isAnimated: Bool) {
    self.color = color
    self.colorScheme = colorScheme
    self.isAnimated = isAnimated
    updateAnimation()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    updateAnimation()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    glyphLayer.frame = bounds
    CATransaction.commit()
    updateAnimation()
  }

  private func updateAnimation() {
    let configuration = RenderConfiguration(
      color: color, colorScheme: colorScheme,
      scale: window?.screen.scale ?? traitCollection.displayScale
    )
    if renderedConfiguration != configuration {
      images = BrailleSpinnerFrames.images(
        color: color, colorScheme: colorScheme, scale: configuration.scale
      )
      glyphLayer.removeAnimation(forKey: Self.animationKey)
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      glyphLayer.contentsScale = configuration.scale
      glyphLayer.contents = images.first
      CATransaction.commit()
      renderedConfiguration = configuration
    }

    guard isAnimated, window != nil, images.count > 1 else {
      glyphLayer.removeAnimation(forKey: Self.animationKey)
      return
    }
    // UIKit may remove animations while a List row is detached. Check the
    // layer itself even when the color, scale, and activity are unchanged.
    guard glyphLayer.animation(forKey: Self.animationKey) == nil else { return }

    let animation = CAKeyframeAnimation(keyPath: "contents")
    animation.values = images
    animation.calculationMode = .discrete
    animation.duration = BrailleSpinnerFrames.cycleDuration
    animation.repeatCount = .infinity
    let now = CACurrentMediaTime()
    let phase = now.truncatingRemainder(dividingBy: animation.duration)
    animation.beginTime = glyphLayer.convertTime(now, from: nil) - phase
    glyphLayer.add(animation, forKey: Self.animationKey)
  }
}
