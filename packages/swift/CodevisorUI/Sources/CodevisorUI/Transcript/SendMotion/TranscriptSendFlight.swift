import OSLog
import QuartzCore
import SwiftUI

#if canImport(UIKit)
  import UIKit
  public typealias TranscriptSendPlatformView = UIView
#else
  import AppKit
  public typealias TranscriptSendPlatformView = NSView
#endif

let transcriptSendLog = Logger(subsystem: "dev.codevisor.transcript", category: "send")

public final class TranscriptSendOverlayView: TranscriptSendPlatformView {
  #if canImport(UIKit)
    init(window: UIWindow) {
      super.init(frame: window.bounds)
      autoresizingMask = [.flexibleWidth, .flexibleHeight]
      isUserInteractionEnabled = false
      accessibilityElementsHidden = true
      backgroundColor = .clear
    }

    static func overlay(in window: UIWindow) -> TranscriptSendOverlayView? {
      let overlay =
        window.subviews.lazy.compactMap { $0 as? TranscriptSendOverlayView }.first
        ?? TranscriptSendOverlayView(window: window)
      if overlay.superview !== window { window.addSubview(overlay) }
      window.bringSubviewToFront(overlay)
      return overlay
    }

    var hostWindow: UIWindow? { window }

    func releaseIfIdle() {}
  #else
    init() {
      super.init(frame: .zero)
      autoresizingMask = [.width, .height]
      wantsLayer = true
    }

    override public var isFlipped: Bool { true }
    override public func hitTest(_: NSPoint) -> NSView? { nil }

    private(set) weak var hostWindow: NSWindow?

    static func overlay(in window: NSWindow) -> TranscriptSendOverlayView? {
      let overlayWindow =
        (window.childWindows ?? []).lazy.compactMap { $0 as? TranscriptSendOverlayWindow }.first
        ?? TranscriptSendOverlayWindow()
      overlayWindow.level = window.level
      overlayWindow.setFrame(window.frame, display: false)
      if overlayWindow.parent !== window {
        window.addChildWindow(overlayWindow, ordered: .above)
      }
      let overlay = overlayWindow.overlay
      overlay.hostWindow = window
      overlay.frame = overlayWindow.contentView?.bounds ?? .zero
      return overlay
    }

    func releaseIfIdle() {
      guard subviews.isEmpty, let overlayWindow = window, let parent = overlayWindow.parent else { return }
      parent.removeChildWindow(overlayWindow)
      overlayWindow.orderOut(nil)
    }
  #endif

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

  func rect(of view: TranscriptSendPlatformView, _ rect: CGRect) -> CGRect {
    #if canImport(UIKit)
      return convert(rect, from: view)
    #else
      guard let viewWindow = view.window, let ownWindow = window, viewWindow !== ownWindow else {
        return convert(rect, from: view)
      }
      let onScreen = viewWindow.convertToScreen(view.convert(rect, to: nil))
      return convert(ownWindow.convertFromScreen(onScreen), from: nil)
    #endif
  }
}

#if canImport(AppKit) && !canImport(UIKit)
  final class TranscriptSendOverlayWindow: NSWindow {
    let overlay = TranscriptSendOverlayView()

    init() {
      super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
      isOpaque = false
      backgroundColor = .clear
      hasShadow = false
      ignoresMouseEvents = true
      isReleasedWhenClosed = false
      collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
      let content = NSView()
      content.wantsLayer = true
      contentView = content
      overlay.frame = content.bounds
      content.addSubview(overlay)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
  }
#endif

final class TranscriptSendPillView: TranscriptSendPlatformView {
  var fill: CGColor? {
    didSet { transcriptSendLayer?.backgroundColor = fill }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    #if canImport(UIKit)
      isUserInteractionEnabled = false
      clipsToBounds = false
    #else
      wantsLayer = true
    #endif
    transcriptSendLayer?.cornerRadius = UserBubbleBackground.cornerRadius
    transcriptSendLayer?.cornerCurve = .continuous
  }

  #if !canImport(UIKit)
    override var isFlipped: Bool { true }
    override func hitTest(_: NSPoint) -> NSView? { nil }
  #endif

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor
public final class TranscriptSendStage {
  let snapshot: TranscriptSendPlatformView
  let editorFrame: CGRect
  let textRect: CGRect
  let lineHeight: CGFloat
  weak var overlay: TranscriptSendOverlayView?
  fileprivate var timeout: DispatchWorkItem?

  init(
    snapshot: TranscriptSendPlatformView,
    editorFrame: CGRect,
    textRect: CGRect,
    lineHeight: CGFloat,
    overlay: TranscriptSendOverlayView
  ) {
    self.snapshot = snapshot
    self.editorFrame = editorFrame
    self.textRect = textRect
    self.lineHeight = lineHeight
    self.overlay = overlay
  }

  func remove(animated: Bool) {
    timeout?.cancel()
    timeout = nil
    let snapshot = snapshot
    let overlay = overlay
    guard animated, snapshot.superview != nil else {
      snapshot.removeFromSuperview()
      overlay?.releaseIfIdle()
      return
    }
    CATransaction.begin()
    CATransaction.setCompletionBlock {
      MainActor.assumeIsolated {
        snapshot.removeFromSuperview()
        overlay?.releaseIfIdle()
      }
    }
    snapshot.transcriptSendLayer?.add(
      TranscriptSendLayerAnimations.fade(from: 1, to: 0, duration: 0.15),
      forKey: TranscriptSendAnimationKeys.follower
    )
    snapshot.setTranscriptSendOpacity(0)
    CATransaction.commit()
  }
}

@MainActor
public final class TranscriptSendStaging {
  public static let shared = TranscriptSendStaging()

  private var stages: [ObjectIdentifier: TranscriptSendStage] = [:]

  public func stage(
    session: ObjectIdentifier,
    textView: TranscriptSendPlatformView,
    textRect: CGRect,
    lineHeight: CGFloat,
    bubble: Color,
    theme: Theme
  ) {
    cancel(session: session)
    guard let window = textView.window,
      let overlay = TranscriptSendOverlayView.overlay(in: window),
      let glyphs = Self.snapshot(of: textView)
    else {
      transcriptSendLog.debug(
        "stage failed: window=\(textView.window != nil) visible=\(Self.visibleBounds(of: textView).debugDescription)")
      return
    }
    let editorFrame = overlay.rect(of: textView, Self.visibleBounds(of: textView))
    let glyphRect = overlay.rect(of: textView, textRect)
    var visibleText = glyphRect.intersection(editorFrame)
    if visibleText.isNull || visibleText.isEmpty { visibleText = glyphRect }
    let insets = TranscriptSendFlightGeometry.bubbleTextInsets
    let pill = TranscriptSendPillView(
      frame: visibleText.insetBy(dx: -insets.horizontal, dy: -insets.vertical))
    pill.fill = Self.compositedColor(
      bubble, over: UserBubbleBackground.transcriptBackdrop(for: theme), in: textView)
    glyphs.frame = editorFrame.offsetBy(dx: -pill.frame.minX, dy: -pill.frame.minY)
    pill.addSubview(glyphs)
    overlay.addSubview(pill)
    transcriptSendLog.debug("staged composer glyphs")
    let stage = TranscriptSendStage(
      snapshot: pill,
      editorFrame: editorFrame,
      textRect: glyphRect,
      lineHeight: lineHeight,
      overlay: overlay
    )
    let timeout = DispatchWorkItem { [weak self, weak stage] in
      guard let self, let stage, stages[session] === stage else { return }
      stages[session] = nil
      stage.remove(animated: true)
    }
    stage.timeout = timeout
    stages[session] = stage
    DispatchQueue.main.asyncAfter(
      deadline: .now() + TranscriptSendMotion.stagingTimeout, execute: timeout)
  }

  private static func compositedColor(
    _ top: Color, over bottom: Color, in view: TranscriptSendPlatformView
  ) -> CGColor {
    func components(_ color: Color) -> [CGFloat] {
      #if canImport(UIKit)
        let resolved = UIColor(color).resolvedColor(with: view.traitCollection)
        var (r, g, b, a) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a]
      #else
        var result: [CGFloat] = [0, 0, 0, 0]
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
          let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .clear
          result = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent, resolved.alphaComponent]
        }
        return result
      #endif
    }
    let t = components(top)
    let u = components(bottom)
    let alpha = t[3] + u[3] * (1 - t[3])
    guard alpha > 0 else { return CGColor(red: 0, green: 0, blue: 0, alpha: 0) }
    func blend(_ index: Int) -> CGFloat { (t[index] * t[3] + u[index] * u[3] * (1 - t[3])) / alpha }
    return CGColor(red: blend(0), green: blend(1), blue: blend(2), alpha: alpha)
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

    private static func snapshot(of view: UIView) -> UIView? {
      let tint = view.tintColor
      view.tintColor = .clear
      defer { view.tintColor = tint }
      let snapshot = view.snapshotView(afterScreenUpdates: true)
      snapshot?.isUserInteractionEnabled = false
      return snapshot
    }
  #else
    private static func visibleBounds(of view: NSView) -> CGRect { view.visibleRect }

    private static func snapshot(of view: NSView) -> NSView? {
      let bounds = view.visibleRect
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

@MainActor
public final class TranscriptSendFlight {
  private let stage: TranscriptSendStage
  private let proxy: TranscriptSendPlatformView
  #if canImport(UIKit)
    private let proxyController: UIHostingController<AnyView>
  #endif
  private weak var overlay: TranscriptSendOverlayView?
  private var targetOrigin: CGPoint
  private var shiftSerial: UInt64 = 0
  private var completion: (@MainActor () -> Void)?
  private var hasEnded = false

  public static var duration: TimeInterval { TranscriptSendMotion.bubble.settlingDuration() }

  public static func begin(
    session: ObjectIdentifier,
    rowContent: AnyView,
    target: TranscriptSendPlatformView,
    completion: @escaping @MainActor () -> Void
  ) -> TranscriptSendFlight? {
    guard let window = target.window, !target.bounds.isEmpty,
      let stage = TranscriptSendStaging.shared.take(session: session)
    else { return nil }
    guard let overlay = TranscriptSendOverlayView.overlay(in: window) else {
      stage.remove(animated: false)
      return nil
    }
    if stage.overlay !== overlay {
      overlay.addSubview(stage.snapshot)
      stage.overlay = overlay
    }
    return TranscriptSendFlight(
      stage: stage,
      overlay: overlay,
      rowContent: rowContent,
      target: target,
      completion: completion
    )
  }

  private init(
    stage: TranscriptSendStage,
    overlay: TranscriptSendOverlayView,
    rowContent: AnyView,
    target: TranscriptSendPlatformView,
    completion: @escaping @MainActor () -> Void
  ) {
    self.stage = stage
    self.overlay = overlay
    self.completion = completion
    let rowFrame = overlay.rect(of: target, target.bounds)
    targetOrigin = rowFrame.origin
    let content = AnyView(rowContent.environment(\.isTranscriptSendProxy, true))

    #if canImport(UIKit)
      let controller = UIHostingController(rootView: content)
      controller.view.backgroundColor = .clear
      controller.view.isUserInteractionEnabled = false
      controller.safeAreaRegions = []
      proxyController = controller
      let height = controller.sizeThatFits(
        in: CGSize(width: rowFrame.width, height: .greatestFiniteMagnitude)
      ).height
      let size = CGSize(width: rowFrame.width, height: height)
      proxy = UIView(frame: CGRect(origin: rowFrame.origin, size: size))
      proxy.isUserInteractionEnabled = false
      controller.view.frame = CGRect(origin: .zero, size: size)
      proxy.addSubview(controller.view)
      overlay.addSubview(proxy)
      proxy.layoutIfNeeded()
    #else
      let hosting = NSHostingView(rootView: content)
      hosting.frame = CGRect(origin: .zero, size: CGSize(width: rowFrame.width, height: 1))
      let size = CGSize(width: rowFrame.width, height: hosting.fittingSize.height)
      hosting.frame.size = size
      let container = NSView(frame: CGRect(origin: rowFrame.origin, size: size))
      container.wantsLayer = true
      container.addSubview(hosting)
      proxy = container
      overlay.addSubview(container)
      container.layoutSubtreeIfNeeded()
    #endif

    let anchor = proxy.transcriptSendDescendant(ofType: UserBubbleAnchorView.self)
    let bubbleFrame = anchor.map { overlay.rect(of: $0, $0.bounds) }
    let geometry = bubbleFrame.flatMap { frame in
      frame.isEmpty
        ? nil
        : TranscriptSendFlightGeometry(
          editorFrame: stage.editorFrame, textRect: stage.textRect, bubbleFrame: frame)
    }
    let rowOffset =
      geometry?.rowOffset
      ?? CGSize(width: 0, height: stage.editorFrame.maxY - proxy.frame.maxY)
    let scaleOrigin =
      geometry?.textOrigin
      ?? CGPoint(x: proxy.frame.midX, y: proxy.frame.maxY)

    CATransaction.begin()
    CATransaction.setDisableActions(true)

    let startScale = TranscriptSendMotion.bubbleStartScale
    func addFlight(to layer: CALayer?, travel: CGSize) -> CASpringAnimation? {
      guard let layer else { return nil }
      let pivot = CGSize(
        width: (1 - startScale) * (scaleOrigin.x - layer.position.x),
        height: (1 - startScale) * (scaleOrigin.y - layer.position.y)
      )
      let move = TranscriptSendLayerAnimations.translation(
        CGSize(width: travel.width + pivot.width, height: travel.height + pivot.height),
        spring: TranscriptSendMotion.bubble
      )
      layer.add(move, forKey: "codevisor.send-flight.move")
      layer.add(
        TranscriptSendLayerAnimations.additiveSpring(
          keyPath: "transform.scale",
          offset: startScale - 1,
          zero: CGFloat(0),
          spring: TranscriptSendMotion.bubble
        ),
        forKey: "codevisor.send-flight.scale")
      return move
    }

    let crossfades =
      geometry.map {
        $0.isSingleLine(textRect: stage.textRect.intersection(stage.editorFrame), lineHeight: stage.lineHeight)
      } ?? false
    let snapshot = stage.snapshot
    snapshot.frame = snapshot.frame.offsetBy(dx: -rowOffset.width, dy: -rowOffset.height)
    if crossfades {
      _ = addFlight(to: snapshot.transcriptSendLayer, travel: rowOffset)
      snapshot.transcriptSendLayer?.add(
        TranscriptSendLayerAnimations.fade(from: 1, to: 0, duration: TranscriptSendMotion.crossfadeDuration),
        forKey: "codevisor.send-flight.fade")
    }
    snapshot.setTranscriptSendOpacity(0)

    let move = addFlight(to: proxy.transcriptSendLayer, travel: rowOffset)
    move?.delegate = TranscriptSendAnimationCompletion { [weak self] finished in
      MainActor.assumeIsolated {
        transcriptSendLog.debug("flight animation stopped finished=\(finished)")
        self?.land()
      }
    }
    if let move { proxy.transcriptSendLayer?.add(move, forKey: "codevisor.send-flight.move") }
    if crossfades {
      proxy.transcriptSendLayer?.add(
        TranscriptSendLayerAnimations.fade(from: 0, to: 1, duration: TranscriptSendMotion.crossfadeDuration),
        forKey: "codevisor.send-flight.fade")
    }

    CATransaction.commit()
  }

  public func follow(_ target: TranscriptSendPlatformView) {
    guard !hasEnded, let overlay else { return }
    guard target.window != nil, target.window === overlay.hostWindow else {
      transcriptSendLog.debug("flight target left its window; landing")
      land()
      return
    }
    let origin = overlay.rect(of: target, target.bounds).origin
    let delta = CGSize(width: origin.x - targetOrigin.x, height: origin.y - targetOrigin.y)
    guard abs(delta.width) > 0.5 || abs(delta.height) > 0.5 else { return }
    targetOrigin = origin
    shiftSerial &+= 1
    let key = TranscriptSendAnimationKeys.shiftPrefix + String(shiftSerial)
    let back = CGSize(width: -delta.width, height: -delta.height)

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for view in [proxy, stage.snapshot] {
      view.frame = view.frame.offsetBy(dx: delta.width, dy: delta.height)
      view.transcriptSendLayer?.add(
        TranscriptSendLayerAnimations.translation(back, spring: TranscriptSendMotion.content), forKey: key)
    }
    CATransaction.commit()
  }

  public func land() {
    guard !hasEnded else { return }
    hasEnded = true
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    proxy.removeFromSuperview()
    stage.remove(animated: false)
    overlay?.releaseIfIdle()
    let completion = completion
    self.completion = nil
    completion?()
    CATransaction.commit()
  }
}

extension TranscriptSendPlatformView {
  var transcriptSendLayer: CALayer? { layer }

  func setTranscriptSendOpacity(_ opacity: CGFloat) {
    #if canImport(UIKit)
      alpha = opacity
    #else
      alphaValue = opacity
    #endif
  }

  func transcriptSendDescendant<View: TranscriptSendPlatformView>(ofType type: View.Type) -> View? {
    for subview in subviews {
      if let match = subview as? View { return match }
      if let match = subview.transcriptSendDescendant(ofType: type) { return match }
    }
    return nil
  }
}
