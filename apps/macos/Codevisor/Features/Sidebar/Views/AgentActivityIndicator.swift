import AppKit
import SwiftUI

struct AgentActivityIndicator: View {
  var color: Color = .secondary

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    BrailleSpinnerLayer(color: color, isAnimated: !reduceMotion)
      .frame(width: BrailleSpinnerFrames.size.width, height: BrailleSpinnerFrames.size.height)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Working")
      .help("Working")
  }
}

@MainActor
private enum BrailleSpinnerFrames {
  static let glyphs = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  static let size = CGSize(width: 14, height: 14)
  static let cycleDuration = Double(glyphs.count) / 8

  private struct Key: Hashable {
    let color: Color
    let appearance: String
    let scale: CGFloat
  }

  private static var cache: [Key: [CGImage]] = [:]

  static func images(color: Color, scale: CGFloat) -> [CGImage] {
    let key = Key(
      color: color,
      appearance: NSApp.effectiveAppearance.name.rawValue,
      scale: scale
    )
    if let cached = cache[key] { return cached }
    let images = glyphs.compactMap { render($0, color: color, scale: scale) }
    guard images.count == glyphs.count else { return images }
    cache[key] = images
    return images
  }

  private static func render(_ glyph: String, color: Color, scale: CGFloat) -> CGImage? {
    let pixelsWide = Int(size.width * scale)
    let pixelsHigh = Int(size.height * scale)
    guard pixelsWide > 0, pixelsHigh > 0,
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelsWide,
        pixelsHigh: pixelsHigh,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    else { return nil }
    rep.size = NSSize(width: size.width, height: size.height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
      let text = NSAttributedString(
        string: glyph,
        attributes: [
          .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
          .foregroundColor: NSColor(color),
        ]
      )
      let bounds = text.boundingRect(
        with: NSSize(width: size.width, height: size.height),
        options: [.usesLineFragmentOrigin]
      )
      text.draw(
        at: NSPoint(
          x: (size.width - bounds.width) / 2,
          y: (size.height - bounds.height) / 2
        ))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage
  }
}

private struct BrailleSpinnerLayer: NSViewRepresentable {
  let color: Color
  let isAnimated: Bool

  private static let animationKey = "brailleFrames"

  @MainActor
  final class Coordinator {
    var appliedKey: String?
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    view.wantsLayer = true
    view.layer?.contentsGravity = .resizeAspect
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    guard let layer = view.layer else { return }
    let scale =
      view.window?.backingScaleFactor
      ?? NSScreen.main?.backingScaleFactor
      ?? 2
    let key = "\(color.hashValue)-\(scale)-\(isAnimated)-\(NSApp.effectiveAppearance.name.rawValue)"
    guard context.coordinator.appliedKey != key else { return }
    context.coordinator.appliedKey = key

    let images = BrailleSpinnerFrames.images(color: color, scale: scale)
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
