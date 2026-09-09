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

  var body: some View {
    BrailleSpinnerLayer(color: color, colorScheme: colorScheme, isAnimated: !reduceMotion)
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

  private static let animationKey = "brailleFrames"

  @MainActor
  final class Coordinator {
    var appliedKey: String?
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.isUserInteractionEnabled = false
    view.layer.contentsGravity = .resizeAspect
    return view
  }

  func updateUIView(_ view: UIView, context: Context) {
    let layer = view.layer
    let scale = view.window?.screen.scale ?? UIScreen.main.scale
    let key = "\(color.hashValue)-\(colorScheme)-\(scale)-\(isAnimated)"
    guard context.coordinator.appliedKey != key else { return }
    context.coordinator.appliedKey = key

    let images = BrailleSpinnerFrames.images(color: color, colorScheme: colorScheme, scale: scale)
    guard let first = images.first else { return }
    layer.contentsScale = scale
    layer.removeAnimation(forKey: Self.animationKey)
    layer.contents = first
    guard isAnimated, images.count > 1 else { return }

    let animation = CAKeyframeAnimation(keyPath: "contents")
    animation.values = images
    animation.calculationMode = .discrete
    animation.duration = BrailleSpinnerFrames.cycleDuration
    animation.repeatCount = .infinity
    let now = CACurrentMediaTime()
    let phase = now.truncatingRemainder(dividingBy: animation.duration)
    animation.beginTime = layer.convertTime(now, from: nil) - phase
    layer.add(animation, forKey: Self.animationKey)
  }
}
