import QuartzCore
import SwiftUI

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

extension View {
  public func transcriptSendAttachmentSource(
    id: String?, image: OSImage?, cornerRadius: CGFloat, sentSize: CGSize
  ) -> some View {
    opacity(id.map(TranscriptSendAttachmentDepartures.shared.contains) == true ? 0 : 1)
      .background {
        TranscriptSendAttachmentAnchor(
          role: .source, attachmentID: id, image: image, cornerRadius: cornerRadius, sentSize: sentSize,
          fill: .clear, stroke: .clear)
      }
  }

  public func transcriptSendAttachmentTarget(
    id: String?, cornerRadius: CGFloat, fill: Color, stroke: Color
  ) -> some View {
    modifier(TranscriptSendAttachmentTargetModifier(id: id, cornerRadius: cornerRadius, fill: fill, stroke: stroke))
  }
}

@MainActor
@Observable
final class TranscriptSendAttachmentDepartures {
  static let shared = TranscriptSendAttachmentDepartures()

  private var ids: Set<String> = []

  func contains(_ id: String) -> Bool { ids.contains(id) }

  func depart(_ pieces: [TranscriptSendAttachmentPiece]) {
    update { $0.formUnion(pieces.map(\.attachmentID)) }
  }

  func arrive(_ pieces: [TranscriptSendAttachmentPiece]) {
    update { $0.subtract(pieces.map(\.attachmentID)) }
  }

  private func update(_ change: (inout Set<String>) -> Void) {
    var next = ids
    change(&next)
    guard next != ids else { return }
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) { ids = next }
  }
}

private struct TranscriptSendAttachmentTargetModifier: ViewModifier {
  @Environment(\.isTranscriptSendProxy) private var isProxy
  let id: String?
  let cornerRadius: CGFloat
  let fill: Color
  let stroke: Color

  func body(content: Content) -> some View {
    if isProxy, let id {
      content.background {
        TranscriptSendAttachmentAnchor(
          role: .target, attachmentID: id, image: nil, cornerRadius: cornerRadius, sentSize: .zero, fill: fill,
          stroke: stroke)
      }
    } else {
      content
    }
  }
}

public enum TranscriptSendAttachmentGeometry {
  public static func filling(aspectRatio: CGFloat, in size: CGSize) -> CGSize {
    guard aspectRatio > 0, size.width > 0, size.height > 0 else { return size }
    return size.width / size.height > aspectRatio
      ? CGSize(width: size.width, height: size.width / aspectRatio)
      : CGSize(width: size.height * aspectRatio, height: size.height)
  }

  public static func strip(sizes: [CGSize], trailing: CGFloat, top: CGFloat, spacing: CGFloat) -> [CGRect] {
    var frames: [CGRect] = []
    var edge = trailing
    for size in sizes.reversed() {
      frames.append(CGRect(x: edge - size.width, y: top, width: size.width, height: size.height))
      edge -= size.width + spacing
    }
    return frames.reversed()
  }

  public static func fitting(aspectRatio: CGFloat, in size: CGSize) -> CGSize {
    guard aspectRatio > 0, size.width > 0, size.height > 0 else { return size }
    return size.width / size.height > aspectRatio
      ? CGSize(width: size.height * aspectRatio, height: size.height)
      : CGSize(width: size.width, height: size.width / aspectRatio)
  }
}

private struct TranscriptSendAttachmentAnchor {
  let role: TranscriptSendAttachmentAnchorView.Role
  let attachmentID: String?
  let image: OSImage?
  let cornerRadius: CGFloat
  let sentSize: CGSize
  let fill: Color
  let stroke: Color

  @MainActor func update(_ view: TranscriptSendAttachmentAnchorView) {
    view.attachmentID = attachmentID
    view.image = image
    view.cornerRadius = cornerRadius
    view.sentSize = sentSize
    view.fill = fill
    view.stroke = stroke
  }
}

#if canImport(UIKit)
  extension TranscriptSendAttachmentAnchor: UIViewRepresentable {
    func makeUIView(context _: Context) -> TranscriptSendAttachmentAnchorView {
      TranscriptSendAttachmentAnchorView(role: role)
    }

    func updateUIView(_ view: TranscriptSendAttachmentAnchorView, context _: Context) { update(view) }
  }
#else
  extension TranscriptSendAttachmentAnchor: NSViewRepresentable {
    func makeNSView(context _: Context) -> TranscriptSendAttachmentAnchorView {
      TranscriptSendAttachmentAnchorView(role: role)
    }

    func updateNSView(_ view: TranscriptSendAttachmentAnchorView, context _: Context) { update(view) }
  }
#endif

final class TranscriptSendAttachmentAnchorView: TranscriptSendPlatformView {
  enum Role {
    case source
    case target
  }

  private static let sources = NSHashTable<TranscriptSendAttachmentAnchorView>.weakObjects()

  let role: Role
  var attachmentID: String?
  var image: OSImage?
  var cornerRadius: CGFloat = 0
  var sentSize: CGSize = .zero
  var fill: Color = .clear
  var stroke: Color = .clear

  init(role: Role) {
    self.role = role
    super.init(frame: .zero)
    #if canImport(UIKit)
      isUserInteractionEnabled = false
      accessibilityElementsHidden = true
    #endif
    if role == .source { Self.sources.add(self) }
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

  #if !canImport(UIKit)
    override func hitTest(_: NSPoint) -> NSView? { nil }
  #endif

  static func sources(in window: AnyObject, ids: Set<String>) -> [TranscriptSendAttachmentAnchorView] {
    sources.allObjects.filter { source in
      guard source.window === window, let id = source.attachmentID, ids.contains(id), source.image != nil else {
        return false
      }
      #if canImport(UIKit)
        return !source.bounds.isEmpty
      #else
        return !source.visibleRect.isEmpty
      #endif
    }
  }

  func resolved(_ color: Color) -> CGColor {
    #if canImport(UIKit)
      return UIColor(color).resolvedColor(with: traitCollection).cgColor
    #else
      var resolved = CGColor(gray: 0, alpha: 0)
      effectiveAppearance.performAsCurrentDrawingAppearance {
        resolved = NSColor(color).cgColor
      }
      return resolved
    #endif
  }
}

final class TranscriptSendAttachmentPiece: TranscriptSendPlatformView {
  let attachmentID: String
  let sentSize: CGSize
  private let card = CALayer()
  private let picture = CALayer()
  private let aspectRatio: CGFloat
  private var serial = 0

  init?(source: TranscriptSendAttachmentAnchorView, frame: CGRect) {
    guard let attachmentID = source.attachmentID, let image = source.image,
      let contents = Self.bitmap(of: image), contents.height > 0
    else { return nil }
    self.attachmentID = attachmentID
    sentSize = source.sentSize.width > 0 && source.sentSize.height > 0 ? source.sentSize : frame.size
    aspectRatio = CGFloat(contents.width) / CGFloat(contents.height)
    super.init(frame: frame)
    #if canImport(UIKit)
      isUserInteractionEnabled = false
      clipsToBounds = false
    #else
      wantsLayer = true
    #endif
    card.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    card.masksToBounds = true
    card.cornerCurve = .continuous
    card.cornerRadius = source.cornerRadius
    picture.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    picture.position = .zero
    picture.contents = contents
    picture.contentsGravity = .resize
    card.addSublayer(picture)
    transcriptSendLayer?.addSublayer(card)
    layoutCard(
      size: frame.size,
      pictureSize: TranscriptSendAttachmentGeometry.filling(aspectRatio: aspectRatio, in: frame.size))
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

  #if !canImport(UIKit)
    override var isFlipped: Bool { true }
    override func hitTest(_: NSPoint) -> NSView? { nil }
  #endif

  static var duration: TimeInterval {
    [TranscriptSendMotion.attachmentRise, TranscriptSendMotion.attachmentSlide, TranscriptSendMotion.attachmentGrow]
      .map { $0.settlingDuration() }.max() ?? 0
  }

  func fly(toward end: CGRect) {
    move(
      to: end,
      pictureSize: TranscriptSendAttachmentGeometry.filling(aspectRatio: aspectRatio, in: end.size),
      cornerRadius: card.cornerRadius,
      onSettle: nil)
  }

  func fly(to target: TranscriptSendAttachmentAnchorView, frame end: CGRect, onSettle: @escaping () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    card.backgroundColor = target.resolved(target.fill)
    card.borderColor = target.resolved(target.stroke)
    card.borderWidth = 1
    move(
      to: end,
      pictureSize: TranscriptSendAttachmentGeometry.fitting(aspectRatio: aspectRatio, in: end.size),
      cornerRadius: target.cornerRadius,
      onSettle: onSettle)
    CATransaction.commit()
  }

  private func move(to end: CGRect, pictureSize: CGSize, cornerRadius: CGFloat, onSettle: (() -> Void)?) {
    serial &+= 1
    let start = frame
    let startCorner = card.cornerRadius
    let startPicture = picture.bounds.size

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    setTranscriptSendFrame(end)
    layoutCard(size: end.size, pictureSize: pictureSize)
    card.cornerRadius = cornerRadius

    let rise = TranscriptSendMotion.attachmentRise
    let slide = TranscriptSendMotion.attachmentSlide
    let grow = TranscriptSendMotion.attachmentGrow
    let layer = transcriptSendLayer ?? card
    let animations: [(layer: CALayer, key: String, animation: CASpringAnimation)] =
      [
        (
          layer, "x",
          TranscriptSendLayerAnimations.additiveSpring(
            keyPath: "transform.translation.x", offset: start.midX - end.midX, zero: CGFloat(0), spring: slide)
        ),
        (
          layer, "y",
          TranscriptSendLayerAnimations.additiveSpring(
            keyPath: "transform.translation.y", offset: start.midY - end.midY, zero: CGFloat(0), spring: rise)
        ),
        (
          card, "corner",
          TranscriptSendLayerAnimations.additiveSpring(
            keyPath: "cornerRadius", offset: startCorner - cornerRadius, zero: CGFloat(0), spring: grow)
        ),
      ]
      + Self.resize(card, named: "card", from: start.size, to: end.size, spring: grow)
      + Self.resize(picture, named: "picture", from: startPicture, to: pictureSize, spring: grow)
    if let onSettle {
      let settles = serial
      animations.max { $0.animation.duration < $1.animation.duration }?.animation.delegate =
        TranscriptSendAnimationCompletion { [weak self] _ in
          MainActor.assumeIsolated {
            guard let self, self.serial == settles else { return }
            onSettle()
          }
        }
    }
    for (layer, key, animation) in animations {
      layer.add(animation, forKey: "codevisor.send-attachment.\(key).\(serial)")
    }
    CATransaction.commit()
  }

  func shift(by delta: CGSize, key: String) {
    setTranscriptSendFrame(frame.offsetBy(dx: delta.width, dy: delta.height))
    transcriptSendLayer?.add(
      TranscriptSendLayerAnimations.translation(
        CGSize(width: -delta.width, height: -delta.height), spring: TranscriptSendMotion.content),
      forKey: key)
  }

  func fadeOut() {
    CATransaction.begin()
    CATransaction.setCompletionBlock {
      MainActor.assumeIsolated { self.removeFromSuperview() }
    }
    transcriptSendLayer?.add(
      TranscriptSendLayerAnimations.fade(from: 1, to: 0, duration: TranscriptSendMotion.followerFadeDuration),
      forKey: "codevisor.send-attachment.fade")
    setTranscriptSendOpacity(0)
    CATransaction.commit()
  }

  private func layoutCard(size: CGSize, pictureSize: CGSize) {
    card.position = CGPoint(x: size.width / 2, y: size.height / 2)
    card.bounds = Self.centered(size)
    picture.bounds = Self.centered(pictureSize)
  }

  private static func resize(
    _ layer: CALayer, named name: String, from start: CGSize, to end: CGSize, spring: TranscriptSpring
  ) -> [(layer: CALayer, key: String, animation: CASpringAnimation)] {
    let dw = start.width - end.width
    let dh = start.height - end.height
    guard abs(dw) > 0.01 || abs(dh) > 0.01 else { return [] }
    return [
      (
        layer, "\(name).size",
        TranscriptSendLayerAnimations.additiveSpring(
          keyPath: "bounds.size", offset: NSValue.transcriptSize(CGSize(width: dw, height: dh)),
          zero: NSValue.transcriptSize(.zero), spring: spring)
      ),
      (
        layer, "\(name).origin",
        TranscriptSendLayerAnimations.additiveSpring(
          keyPath: "bounds.origin", offset: NSValue.transcriptPoint(CGPoint(x: -dw / 2, y: -dh / 2)),
          zero: NSValue.transcriptPoint(.zero), spring: spring)
      ),
    ]
  }

  private static func centered(_ size: CGSize) -> CGRect {
    CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
  }

  private func setTranscriptSendFrame(_ frame: CGRect) {
    #if canImport(UIKit)
      UIView.performWithoutAnimation { self.frame = frame }
    #else
      self.frame = frame
    #endif
  }

  private static func bitmap(of image: OSImage) -> CGImage? {
    #if canImport(UIKit)
      if image.imageOrientation == .up, let cgImage = image.cgImage { return cgImage }
      let format = UIGraphicsImageRendererFormat.preferred()
      format.scale = image.scale
      return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
        image.draw(at: .zero)
      }.cgImage
    #else
      return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    #endif
  }
}

extension NSValue {
  static func transcriptPoint(_ point: CGPoint) -> NSValue {
    #if canImport(UIKit)
      NSValue(cgPoint: point)
    #else
      NSValue(point: point)
    #endif
  }
}
