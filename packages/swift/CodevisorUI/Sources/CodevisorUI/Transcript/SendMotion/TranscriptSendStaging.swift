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
    let depart: @MainActor () -> Void
    let anticipate: @MainActor (CFTimeInterval) -> Void
  }

  private var landingProviders: [ObjectIdentifier: [LandingProvider]] = [:]

  public func setLandingProvider(
    for session: ObjectIdentifier,
    owner: AnyObject,
    holds: @escaping @MainActor () -> Bool = { false },
    landing: @escaping @MainActor () -> TranscriptSendLanding?,
    depart: @escaping @MainActor () -> Void = {},
    anticipate: @escaping @MainActor (CFTimeInterval) -> Void = { _ in }
  ) {
    var providers = (landingProviders[session] ?? []).filter { $0.owner != nil && $0.owner !== owner }
    providers.append(
      LandingProvider(owner: owner, landing: landing, holds: holds, depart: depart, anticipate: anticipate))
    landingProviders[session] = providers
  }

  public func removeLandingProvider(for session: ObjectIdentifier, owner: AnyObject) {
    let providers = (landingProviders[session] ?? []).filter { $0.owner != nil && $0.owner !== owner }
    landingProviders[session] = providers.isEmpty ? nil : providers
  }

  public func releaseHeldSend(session: ObjectIdentifier) {
    guard let stage = stages[session] else { return }
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
    let corner = stage.track.convert(
      overlay.point(inHostWindow: CGPoint(x: landing.trailing, y: landing.top)), from: overlay)
    provider.depart()
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
    guard let session = stages.first(where: { $0.value === stage })?.key else { return }
    let next = removal(of: stage, session: session)
    stage.timeout = next
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: next)
  }

  private func removal(of stage: TranscriptSendStage, session: ObjectIdentifier) -> DispatchWorkItem {
    DispatchWorkItem { [weak self, weak stage] in
      guard let self, let stage, stages[session] === stage else { return }
      stages[session] = nil
      stage.remove(animated: true)
    }
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
    bubble: Color,
    revealsBubbleInFlight: Bool = false,
    followsComposer: Bool = true,
    attachmentIDs: [String] = []
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
    let track = overlay.makeTrack()
    let source = StageSource(
      view: textView,
      glyphs: glyphs,
      editorFrame: track.convert(Self.visibleBounds(of: textView), from: textView),
      glyphRect: track.convert(textRect, from: textView),
      lineHeight: lineHeight,
      text: Self.attributedText(of: textView),
      bubble: bubble,
      revealsBubbleInFlight: revealsBubbleInFlight
    )
    let pieces = departingPieces(attachmentIDs, in: window, track: track)
    begin(source, session: session, overlay: overlay, track: track, pieces: pieces, followsComposer: followsComposer)
  }

  public func stage(
    session: ObjectIdentifier,
    from view: TranscriptSendPlatformView,
    textRect: CGRect,
    text: NSAttributedString,
    bubble: Color,
    revealsBubbleInFlight: Bool = false
  ) {
    cancel(session: session)
    let width = Self.lineWidth(of: text, from: textRect)
    guard let window = view.window,
      let overlay = TranscriptSendOverlayView.overlay(in: window),
      let (glyphs, height) = Self.renderedText(text, width: width, appearanceOf: view)
    else { return }
    let track = overlay.makeTrack()
    let lines = CGRect(x: textRect.minX, y: textRect.midY - height / 2, width: width, height: height)
    let frame = track.convert(lines, from: view)
    let source = StageSource(
      view: view, glyphs: glyphs, editorFrame: frame, glyphRect: frame, lineHeight: height, text: text,
      bubble: bubble, revealsBubbleInFlight: revealsBubbleInFlight)
    begin(source, session: session, overlay: overlay, track: track, pieces: [], followsComposer: false)
  }

  private static let maxLineStretch: CGFloat = 1.5

  private static func lineWidth(of text: NSAttributedString, from textRect: CGRect) -> CGFloat {
    let natural = ceil(text.size().width)
    return min(max(textRect.width, natural), textRect.width * maxLineStretch)
  }

  private struct StageSource {
    let view: TranscriptSendPlatformView
    let glyphs: TranscriptSendPlatformView
    let editorFrame: CGRect
    let glyphRect: CGRect
    let lineHeight: CGFloat
    let text: NSAttributedString?
    let bubble: Color
    let revealsBubbleInFlight: Bool
  }

  private func departingPieces(
    _ attachmentIDs: [String], in window: TranscriptSendPlatformWindow, track: TranscriptSendTrack
  ) -> [TranscriptSendAttachmentPiece] {
    let sources = TranscriptSendAttachmentAnchorView.sources(in: window, ids: Set(attachmentIDs))
    let pieces = attachmentIDs.compactMap { id in sources.first { $0.attachmentID == id } }
      .compactMap { TranscriptSendAttachmentPiece(source: $0, frame: track.convert($0.bounds, from: $0)) }
    TranscriptSendAttachmentDepartures.shared.depart(pieces)
    return pieces
  }

  private func begin(
    _ source: StageSource,
    session: ObjectIdentifier,
    overlay: TranscriptSendOverlayView,
    track: TranscriptSendTrack,
    pieces: [TranscriptSendAttachmentPiece],
    followsComposer: Bool
  ) {
    let pill = pill(for: source)
    for piece in pieces { track.addSubview(piece) }
    track.addSubview(pill)
    transcriptSendLog.debug("staged glyphs with \(pieces.count) attachments")
    let stage = TranscriptSendStage(
      snapshot: pill,
      editorFrame: source.editorFrame,
      textRect: source.glyphRect,
      lineHeight: source.lineHeight,
      text: source.text,
      pieces: pieces,
      track: track
    )
    let timeout = removal(of: stage, session: session)
    stage.timeout = timeout
    stages[session] = stage
    let lifetime = holds(session) ? TranscriptSendMotion.heldStagingTimeout : TranscriptSendMotion.stagingTimeout
    if let found = landing(for: session) {
      beginMorph(stage, toward: found.0, provider: found.1, in: overlay)
    } else {
      #if canImport(UIKit)
        if followsComposer, let container = source.view.superview {
          stage.board(TranscriptSendCarrier(content: container, overlay: overlay))
        }
      #endif
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + lifetime, execute: timeout)
  }

  private func pill(for source: StageSource) -> TranscriptSendPillView {
    let pill = TranscriptSendPillView(
      frame: TranscriptSendMorphGeometry.startBubble(editorFrame: source.editorFrame, textRect: source.glyphRect),
      cornerRadius: UserBubbleBackground.cornerRadius(for: Self.dynamicTypeSize(of: source.view)))
    pill.setFill(
      backdrop: Self.resolved(UserBubbleBackground.transcriptBackdrop(), in: source.view),
      tint: Self.resolved(source.bubble, in: source.view))
    pill.hidesFill = source.revealsBubbleInFlight
    source.glyphs.frame = source.editorFrame.offsetBy(dx: -pill.frame.minX, dy: -pill.frame.minY)
    pill.addSubview(source.glyphs)
    return pill
  }

  static func attributedText(of view: TranscriptSendPlatformView) -> NSAttributedString? {
    #if canImport(UIKit)
      (view as? UITextView)?.attributedText.map { NSAttributedString(attributedString: $0) }
    #else
      (view as? NSTextView).map { NSAttributedString(attributedString: $0.attributedString()) }
    #endif
  }

  static func renderedGlyphs(of view: TranscriptSendPlatformView) -> TranscriptSendPlatformView? {
    guard !view.bounds.isEmpty else { return nil }
    #if canImport(UIKit)
      return drawn(view, traits: view.traitCollection)
    #else
      return snapshot(of: view, bounds: view.bounds)
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
      view.overrideUserInterfaceStyle = source.traitCollection.userInterfaceStyle
      return (drawn(view, traits: source.traitCollection), height)
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

    private static func drawn(_ view: UIView, traits: UITraitCollection) -> UIView {
      view.layoutIfNeeded()
      var image = UIImage()
      traits.performAsCurrent {
        image = UIGraphicsImageRenderer(bounds: view.bounds).image { context in
          view.layer.render(in: context.cgContext)
        }
      }
      let drawn = UIImageView(image: image)
      drawn.isUserInteractionEnabled = false
      return drawn
    }

    private static func snapshot(of view: UIView, bounds: CGRect) -> UIView? {
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

    private static func snapshot(of view: NSView, bounds: CGRect) -> NSView? {
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
