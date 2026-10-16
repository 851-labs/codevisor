import QuartzCore
import SwiftUI

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

@MainActor
public final class TranscriptSendStaging {
  public static let shared = TranscriptSendStaging()

  private var stages: [ObjectIdentifier: TranscriptSendStage] = [:]

  private struct LandingProvider {
    weak var owner: AnyObject?
    let landing: @MainActor () -> TranscriptSendLanding?
    let holds: @MainActor () -> Bool
    let anticipate: @MainActor (CFTimeInterval) -> Void
  }

  private var landingProviders: [ObjectIdentifier: [LandingProvider]] = [:]

  public func setLandingProvider(
    for session: ObjectIdentifier,
    owner: AnyObject,
    holds: @escaping @MainActor () -> Bool = { false },
    landing: @escaping @MainActor () -> TranscriptSendLanding?,
    anticipate: @escaping @MainActor (CFTimeInterval) -> Void = { _ in }
  ) {
    var providers = (landingProviders[session] ?? []).filter { $0.owner != nil && $0.owner !== owner }
    providers.append(LandingProvider(owner: owner, landing: landing, holds: holds, anticipate: anticipate))
    landingProviders[session] = providers
  }

  public func removeLandingProvider(for session: ObjectIdentifier, owner: AnyObject) {
    let providers = (landingProviders[session] ?? []).filter { $0.owner != nil && $0.owner !== owner }
    landingProviders[session] = providers.isEmpty ? nil : providers
  }

  public func releaseHeldSend(session: ObjectIdentifier) {
    guard let stage = stages[session], stage.morph == nil, let overlay = stage.overlay else { return }
    if let found = landing(for: session) {
      beginMorph(stage, toward: found.0, provider: found.1, in: overlay)
    }
    scheduleTimeout(for: stage, after: TranscriptSendMotion.stagingTimeout)
  }

  private func holds(_ session: ObjectIdentifier) -> Bool {
    (landingProviders[session] ?? []).contains { $0.owner != nil && $0.holds() }
  }

  private func beginMorph(
    _ stage: TranscriptSendStage,
    toward landing: TranscriptSendLanding,
    provider: LandingProvider,
    in overlay: TranscriptSendOverlayView
  ) {
    let corner = overlay.point(inHostWindow: CGPoint(x: landing.trailing, y: landing.top))
    stage.beginMorph(
      toward: TranscriptSendLanding(
        trailing: corner.x, top: corner.y, maxBubbleWidth: landing.maxBubbleWidth))
    CATransaction.flush()
    if let beginTime = stage.morph?.riseBeginTime {
      provider.anticipate(beginTime)
    }
  }

  private func scheduleTimeout(for stage: TranscriptSendStage, after delay: TimeInterval) {
    guard let timeout = stage.timeout else { return }
    timeout.cancel()
    let session = stages.first { $0.value === stage }?.key
    let next = DispatchWorkItem { [weak self, weak stage] in
      guard let self, let stage, let session, stages[session] === stage else { return }
      stages[session] = nil
      stage.remove(animated: true)
    }
    stage.timeout = next
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: next)
  }

  private func landing(for session: ObjectIdentifier) -> (TranscriptSendLanding, LandingProvider)? {
    for provider in (landingProviders[session] ?? []).reversed() where provider.owner != nil {
      if let landing = provider.landing() { return (landing, provider) }
    }
    return nil
  }

  func syncCarrier(session: ObjectIdentifier) {
    #if canImport(UIKit)
      stages[session]?.carrier?.sync()
    #endif
  }

  public func stage(
    session: ObjectIdentifier,
    textView: TranscriptSendPlatformView,
    textRect: CGRect,
    lineHeight: CGFloat,
    bubble: Color
  ) {
    cancel(session: session)
    guard let window = textView.window,
      let overlay = TranscriptSendOverlayView.overlay(in: window),
      let glyphs = Self.snapshot(of: textView, bounds: Self.visibleBounds(of: textView))
    else {
      transcriptSendLog.debug(
        "stage failed: window=\(textView.window != nil) visible=\(Self.visibleBounds(of: textView).debugDescription)")
      return
    }
    let editorFrame = overlay.rect(of: textView, Self.visibleBounds(of: textView))
    let glyphRect = overlay.rect(of: textView, textRect)
    let pill = TranscriptSendPillView(
      frame: TranscriptSendMorphGeometry.startBubble(editorFrame: editorFrame, textRect: glyphRect),
      cornerRadius: UserBubbleBackground.cornerRadius(for: Self.dynamicTypeSize(of: textView)))
    pill.setFill(
      backdrop: Self.resolved(UserBubbleBackground.transcriptBackdrop(), in: textView),
      tint: Self.resolved(bubble, in: textView))
    glyphs.frame = editorFrame.offsetBy(dx: -pill.frame.minX, dy: -pill.frame.minY)
    pill.addSubview(glyphs)
    overlay.addSubview(pill)
    transcriptSendLog.debug("staged composer glyphs")
    let stage = TranscriptSendStage(
      snapshot: pill,
      editorFrame: editorFrame,
      textRect: glyphRect,
      lineHeight: lineHeight,
      text: Self.attributedText(of: textView),
      overlay: overlay
    )
    let timeout = DispatchWorkItem { [weak self, weak stage] in
      guard let self, let stage, stages[session] === stage else { return }
      stages[session] = nil
      stage.remove(animated: true)
    }
    stage.timeout = timeout
    stages[session] = stage
    let isHeld = holds(session)
    if isHeld {
      pill.hidesFill = true
    } else if let found = landing(for: session) {
      beginMorph(stage, toward: found.0, provider: found.1, in: overlay)
    } else {
      #if canImport(UIKit)
        if let container = textView.superview {
          stage.board(TranscriptSendCarrier(content: container, overlay: overlay))
        }
      #endif
    }
    DispatchQueue.main.asyncAfter(
      deadline: .now()
        + (isHeld ? TranscriptSendMotion.heldStagingTimeout : TranscriptSendMotion.stagingTimeout),
      execute: timeout)
  }

  static func attributedText(of view: TranscriptSendPlatformView) -> NSAttributedString? {
    #if canImport(UIKit)
      (view as? UITextView)?.attributedText.map { NSAttributedString(attributedString: $0) }
    #else
      (view as? NSTextView).map { NSAttributedString(attributedString: $0.attributedString()) }
    #endif
  }

  static func renderedText(
    _ text: NSAttributedString, width: CGFloat, appearanceOf source: TranscriptSendPlatformView
  ) -> (TranscriptSendPlatformView, CGFloat)? {
    guard text.length > 0 else { return nil }
    #if canImport(UIKit)
      let view = UITextView()
      view.attributedText = text
      view.backgroundColor = .clear
      view.isScrollEnabled = false
      view.textContainerInset = .zero
      view.textContainer.lineFragmentPadding = 0
      let height = ceil(view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
      guard height > 0 else { return nil }
      view.frame = CGRect(x: 0, y: 0, width: width, height: height)
      view.layoutIfNeeded()
      var image = UIImage()
      source.traitCollection.performAsCurrent {
        view.overrideUserInterfaceStyle = source.traitCollection.userInterfaceStyle
        image = UIGraphicsImageRenderer(bounds: view.bounds).image { context in
          view.layer.render(in: context.cgContext)
        }
      }
      let drawn = UIImageView(image: image)
      drawn.isUserInteractionEnabled = false
      return (drawn, height)
    #else
      let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10_000))
      view.textStorage?.setAttributedString(text)
      view.drawsBackground = false
      view.textContainerInset = .zero
      view.textContainer?.lineFragmentPadding = 0
      view.textContainer?.widthTracksTextView = true
      guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
      layout.ensureLayout(for: container)
      let height = ceil(layout.usedRect(for: container).height)
      guard height > 0 else { return nil }
      view.frame.size.height = height
      view.appearance = source.effectiveAppearance
      guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
      source.effectiveAppearance.performAsCurrentDrawingAppearance {
        view.cacheDisplay(in: view.bounds, to: bitmap)
      }
      let image = NSImage(size: view.bounds.size)
      image.addRepresentation(bitmap)
      let drawn = NSImageView(image: image)
      drawn.imageScaling = .scaleAxesIndependently
      drawn.wantsLayer = true
      return (drawn, height)
    #endif
  }

  private static func resolved(_ color: Color, in view: TranscriptSendPlatformView) -> CGColor {
    #if canImport(UIKit)
      return UIColor(color).resolvedColor(with: view.traitCollection).cgColor
    #else
      var resolved = CGColor(gray: 0, alpha: 0)
      view.effectiveAppearance.performAsCurrentDrawingAppearance {
        resolved = NSColor(color).cgColor
      }
      return resolved
    #endif
  }

  public func hasStage(for session: ObjectIdentifier) -> Bool {
    stages[session] != nil
  }

  func take(session: ObjectIdentifier) -> TranscriptSendStage? {
    guard let stage = stages.removeValue(forKey: session) else { return nil }
    stage.timeout?.cancel()
    stage.timeout = nil
    return stage
  }

  public func cancel(session: ObjectIdentifier, animated: Bool = false) {
    stages.removeValue(forKey: session)?.remove(animated: animated)
  }

  #if canImport(UIKit)
    public func bringOverlaysToFront() {
      for scene in UIApplication.shared.connectedScenes {
        guard let scene = scene as? UIWindowScene else { continue }
        for window in scene.windows {
          if let overlay = window.subviews.last(where: { $0 is TranscriptSendOverlayView }) {
            window.bringSubviewToFront(overlay)
          }
        }
      }
    }

    private static func visibleBounds(of view: UIView) -> CGRect { view.bounds }

    private static func dynamicTypeSize(of view: UIView) -> DynamicTypeSize {
      DynamicTypeSize(view.traitCollection.preferredContentSizeCategory) ?? .large
    }

    static func snapshot(of view: UIView, bounds: CGRect) -> UIView? {
      let tint = view.tintColor
      view.tintColor = .clear
      defer { view.tintColor = tint }
      let snapshot = view.resizableSnapshotView(
        from: bounds, afterScreenUpdates: true, withCapInsets: .zero)
      snapshot?.isUserInteractionEnabled = false
      return snapshot
    }
  #else
    private static func visibleBounds(of view: NSView) -> CGRect { view.visibleRect }

    private static func dynamicTypeSize(of _: NSView) -> DynamicTypeSize { .large }

    static func snapshot(of view: NSView, bounds: CGRect) -> NSView? {
      guard !bounds.isEmpty, let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else {
        return nil
      }
      let textView = view as? NSTextView
      let caret = textView?.insertionPointColor
      textView?.insertionPointColor = .clear
      view.cacheDisplay(in: bounds, to: bitmap)
      if let caret { textView?.insertionPointColor = caret }
      let image = NSImage(size: bounds.size)
      image.addRepresentation(bitmap)
      let snapshot = NSImageView(image: image)
      snapshot.imageScaling = .scaleAxesIndependently
      snapshot.wantsLayer = true
      return snapshot
    }
  #endif
}
