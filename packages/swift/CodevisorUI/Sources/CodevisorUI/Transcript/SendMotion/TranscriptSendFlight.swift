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

@MainActor
public final class TranscriptSendFlight {
  private let stage: TranscriptSendStage
  private let proxy: TranscriptSendPlatformView
  #if canImport(UIKit)
    private let proxyController: UIHostingController<AnyView>
  #endif
  private weak var overlay: TranscriptSendOverlayView?
  private weak var space: TranscriptSendPlatformView?
  private var targetOrigin: CGPoint
  private var shiftSerial: UInt64 = 0
  private var completion: (@MainActor () -> Void)?
  private var hasEnded = false
  private var morphLanding: (@MainActor () -> Void)?

  public static var duration: TimeInterval { TranscriptSendMotion.bubble.settlingDuration() }

  public static func begin(
    session: ObjectIdentifier,
    rowContent: AnyView,
    target: TranscriptSendPlatformView,
    settleRowHeight: @MainActor (CGFloat) -> Void,
    completion: @escaping @MainActor () -> Void
  ) -> TranscriptSendFlight? {
    guard let window = target.window, !target.bounds.isEmpty,
      let stage = TranscriptSendStaging.shared.take(session: session)
    else { return nil }
    guard let overlay = TranscriptSendOverlayView.overlay(in: window) else {
      stage.remove(animated: false)
      return nil
    }
    if stage.overlay !== overlay, !Self.rides(stage) {
      overlay.addSubview(stage.snapshot)
      stage.overlay = overlay
    }
    return TranscriptSendFlight(
      stage: stage,
      overlay: overlay,
      rowContent: rowContent,
      target: target,
      settleRowHeight: settleRowHeight,
      completion: completion
    )
  }

  private init(
    stage: TranscriptSendStage,
    overlay: TranscriptSendOverlayView,
    rowContent: AnyView,
    target: TranscriptSendPlatformView,
    settleRowHeight: @MainActor (CGFloat) -> Void,
    completion: @escaping @MainActor () -> Void
  ) {
    self.stage = stage
    self.overlay = overlay
    self.completion = completion
    #if canImport(UIKit)
      if stage.morph == nil {
        stage.board(TranscriptSendCarrier(content: target, overlay: overlay))
      }
      let space: TranscriptSendPlatformView = stage.carrier?.view ?? overlay
    #else
      let space: TranscriptSendPlatformView = overlay
    #endif
    self.space = space
    var rowFrame = Self.rect(of: target, target.bounds, in: space, overlay: overlay)
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
      space.addSubview(proxy)
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

    if abs(proxy.frame.height - rowFrame.height) > 0.5 {
      settleRowHeight(proxy.frame.height)
      #if canImport(UIKit)
        stage.carrier?.sync()
      #endif
      rowFrame = Self.rect(of: target, target.bounds, in: space, overlay: overlay)
      proxy.frame.origin = rowFrame.origin
      targetOrigin = rowFrame.origin
    }

    let anchor = proxy.transcriptSendDescendant(ofType: UserBubbleAnchorView.self)
    let bubbleFrame =
      anchor
      .map { Self.rect(of: $0, $0.bounds, in: space, overlay: overlay) }
      .flatMap { $0.isEmpty ? nil : $0 }
    let landing: @MainActor () -> Void = { [weak self] in
      transcriptSendLog.debug("flight settled")
      self?.land()
    }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let snapshot = stage.snapshot
    if let bubbleFrame {
      morphLanding = landing
      if let morph = stage.morph {
        morph.retarget(to: bubbleFrame, onSettle: landing)
      } else {
        stage.beginMorph(toward: bubbleFrame, onSettle: landing)
      }
      if stage.isMultiline {
        stage.rewrap(
          toTextWidth: bubbleFrame.width - TranscriptSendFlightGeometry.bubbleTextInsets.horizontal * 2)
      }
      proxy.setTranscriptSendOpacity(0)
    } else if let morph = stage.morph {
      morph.retarget(to: proxy.frame, onSettle: landing)
      morph.carry(proxy)
      snapshot.transcriptSendLayer?.add(
        TranscriptSendLayerAnimations.fade(from: 1, to: 0, duration: TranscriptSendMotion.followerFadeDuration),
        forKey: "codevisor.send-flight.fade")
      snapshot.setTranscriptSendOpacity(0)
    } else {
      let travel = CGSize(width: 0, height: stage.editorFrame.maxY - proxy.frame.maxY)
      let scaleOrigin = CGPoint(x: proxy.frame.midX, y: proxy.frame.maxY)
      let startScale = TranscriptSendMotion.bubbleStartScale
      snapshot.setTranscriptSendOpacity(0)
      if let layer = proxy.transcriptSendLayer {
        let pivot = CGSize(
          width: (1 - startScale) * (scaleOrigin.x - layer.position.x),
          height: (1 - startScale) * (scaleOrigin.y - layer.position.y)
        )
        let move = TranscriptSendLayerAnimations.translation(
          CGSize(width: travel.width + pivot.width, height: travel.height + pivot.height),
          spring: TranscriptSendMotion.bubble
        )
        move.delegate = TranscriptSendAnimationCompletion { _ in
          MainActor.assumeIsolated { landing() }
        }
        layer.add(move, forKey: "codevisor.send-flight.move")
        layer.add(
          TranscriptSendLayerAnimations.additiveSpring(
            keyPath: "transform.scale", offset: startScale - 1, zero: CGFloat(0),
            spring: TranscriptSendMotion.bubble),
          forKey: "codevisor.send-flight.scale")
      }
    }
    CATransaction.commit()
  }

  public func follow(_ target: TranscriptSendPlatformView) {
    guard !hasEnded, let overlay, let space else { return }
    guard target.window != nil, target.window === overlay.hostWindow else {
      transcriptSendLog.debug("flight target left its window; landing")
      land()
      return
    }
    #if canImport(UIKit)
      if let carrier = stage.carrier {
        guard carrier.content === target else {
          transcriptSendLog.debug("flight target replaced; landing")
          land()
          return
        }
        carrier.sync()
        return
      }
    #endif
    let origin = Self.rect(of: target, target.bounds, in: space, overlay: overlay).origin
    let delta = CGSize(width: origin.x - targetOrigin.x, height: origin.y - targetOrigin.y)
    guard abs(delta.width) > 0.5 || abs(delta.height) > 0.5 else { return }
    targetOrigin = origin
    if let morph = stage.morph, let landing = morphLanding {
      proxy.frame = proxy.frame.offsetBy(dx: delta.width, dy: delta.height)
      morph.retarget(to: morph.end.offsetBy(dx: delta.width, dy: delta.height), onSettle: landing)
      return
    }
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

  public func syncCarrier() {
    #if canImport(UIKit)
      stage.carrier?.sync()
    #endif
  }

  public static var ridesTranscript: Bool {
    #if canImport(UIKit)
      true
    #else
      false
    #endif
  }

  private static func rides(_ stage: TranscriptSendStage) -> Bool {
    #if canImport(UIKit)
      stage.carrier != nil
    #else
      false
    #endif
  }

  private static func rect(
    of view: TranscriptSendPlatformView,
    _ rect: CGRect,
    in space: TranscriptSendPlatformView,
    overlay: TranscriptSendOverlayView
  ) -> CGRect {
    #if canImport(UIKit)
      space.convert(rect, from: view)
    #else
      overlay.rect(of: view, rect)
    #endif
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
