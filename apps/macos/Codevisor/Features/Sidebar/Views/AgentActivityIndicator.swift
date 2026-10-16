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
    let appearance: NSAppearance.Name
    let scale: CGFloat
  }

  private static var cache: [Key: [CGImage]] = [:]

  static func images(color: Color, appearance: NSAppearance, scale: CGFloat) -> [CGImage] {
    let key = Key(color: color, appearance: appearance.name, scale: scale)
    if let cached = cache[key] { return cached }
    let images = glyphs.compactMap {
      render($0, color: color, appearance: appearance, scale: scale)
    }
    guard images.count == glyphs.count else { return images }
    cache[key] = images
    return images
  }

  private static func render(
    _ glyph: String,
    color: Color,
    appearance: NSAppearance,
    scale: CGFloat
  ) -> CGImage? {
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
    appearance.performAsCurrentDrawingAppearance {
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

  func makeNSView(context: Context) -> BrailleSpinnerView {
    BrailleSpinnerView()
  }

  func updateNSView(_ view: BrailleSpinnerView, context: Context) {
    view.configure(color: color, isAnimated: isAnimated)
  }
}

private final class BrailleSpinnerView: NSView {
  private static let animationKey = "brailleFrames"

  private struct AppliedState: Hashable {
    let color: Color
    let appearance: NSAppearance.Name
    let scale: CGFloat
    let isAnimated: Bool
  }

  private var color: Color = .secondary
  private var isAnimated = true
  private var applied: AppliedState?
  private var frames: [CGImage] = []

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layerContentsPlacement = .scaleProportionallyToFit
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(color: Color, isAnimated: Bool) {
    self.color = color
    self.isAnimated = isAnimated
    refresh()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    refresh()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refresh()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    refresh()
  }

  private func refresh() {
    guard let layer, let window else { return }
    let state = AppliedState(
      color: color,
      appearance: effectiveAppearance.name,
      scale: window.backingScaleFactor,
      isAnimated: isAnimated
    )
    if state != applied {
      let images = BrailleSpinnerFrames.images(
        color: color,
        appearance: effectiveAppearance,
        scale: state.scale
      )
      guard images.count == BrailleSpinnerFrames.glyphs.count else { return }
      applied = state
      frames = images
      layer.contentsScale = state.scale
      layer.removeAnimation(forKey: Self.animationKey)
      layer.contents = images[0]
    }
    guard state.isAnimated, layer.animation(forKey: Self.animationKey) == nil else { return }

    let animation = CAKeyframeAnimation(keyPath: "contents")
    animation.values = frames
    animation.calculationMode = .discrete
    animation.duration = BrailleSpinnerFrames.cycleDuration
    animation.repeatCount = .infinity
    let now = CACurrentMediaTime()
    let phase = now.truncatingRemainder(dividingBy: animation.duration)
    animation.beginTime = layer.convertTime(now, from: nil) - phase
    layer.add(animation, forKey: Self.animationKey)
  }
}
