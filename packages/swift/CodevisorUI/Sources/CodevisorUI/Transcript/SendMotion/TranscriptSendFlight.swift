import OSLog
import QuartzCore
import SwiftUI

#if canImport(UIKit)
  import UIKit
  public typealias TranscriptSendPlatformView = UIView
  typealias TranscriptSendTextView = UITextView
#else
  import AppKit
  public typealias TranscriptSendPlatformView = NSView
  typealias TranscriptSendTextView = NSTextView
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
  private var pieces: [TranscriptSendAttachmentPiece] = []
  private var pendingSettles = 1

  public static func begin(
    session: ObjectIdentifier,
    rowContent: AnyView,
    target: TranscriptSendPlatformView,
    settleRowHeight: @MainActor (CGFloat) -> Void,
    completion: @escaping @MainActor () -> Void
  ) -> TranscriptSendFlight? {
    guard let window = target.window, !target.bounds.isEmpty,
      let stage = TranscriptSendStaging.shared.take(session: session)
    else {
      transcriptSendLog.debug(
        "flight blocked: window=\(target.window != nil) bounds=\(target.bounds.debugDescription) staged=\(TranscriptSendStaging.shared.hasStage(for: session))"
      )
      return nil
    }
    guard let overlay = TranscriptSendOverlayView.overlay(in: window) else {
      stage.remove(animated: false)
      return nil
    }
    if stage.overlay !== overlay, !Self.rides(stage) {
      overlay.addSubview(stage.track)
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
      if stage.morph == nil, stage.carrier != nil {
        stage.board(TranscriptSendCarrier(content: target, overlay: overlay))
      }
      let space: TranscriptSendPlatformView = stage.carrier?.view ?? stage.track
    #else
      let space: TranscriptSendPlatformView = stage.track
    #endif
    self.space = space
    var rowFrame = Self.rect(of: target, target.bounds, in: space)
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
      space.addSubview(container)
      container.layoutSubtreeIfNeeded()
    #endif

    if abs(proxy.frame.height - rowFrame.height) > 0.5 {
      settleRowHeight(proxy.frame.height)
      #if canImport(UIKit)
        stage.carrier?.sync()
      #endif
      rowFrame = Self.rect(of: target, target.bounds, in: space)
      proxy.frame.origin = rowFrame.origin
      targetOrigin = rowFrame.origin
    }

    let anchor = proxy.transcriptSendDescendant(ofType: UserBubbleAnchorView.self)
    let bubbleFrame =
      anchor
      .map { Self.rect(of: $0, $0.bounds, in: space) }
      .flatMap { $0.isEmpty ? nil : $0 }
    let targets = proxy.transcriptSendDescendants(ofType: TranscriptSendAttachmentAnchorView.self)
      .filter { $0.role == .target }
    var flying: [(piece: TranscriptSendAttachmentPiece, target: TranscriptSendAttachmentAnchorView, frame: CGRect)] =
      []
    var strays: [TranscriptSendAttachmentPiece] = []
    for piece in stage.releasePieces() {
      if let target = targets.first(where: { $0.attachmentID == piece.attachmentID }) {
        let frame = Self.rect(of: target, target.bounds, in: space)
        if !frame.isEmpty {
          flying.append((piece, target, frame))
          continue
        }
      }
      strays.append(piece)
    }
    pieces = flying.map(\.piece)
    pendingSettles = (bubbleFrame != nil || flying.isEmpty ? 1 : 0) + flying.count
    let landing: @MainActor () -> Void = { [weak self] in self?.settle() }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let snapshot = stage.snapshot
    TranscriptSendAttachmentDepartures.shared.arrive(strays)
    for stray in strays { stray.fadeOut() }
    for (piece, target, frame) in flying {
      piece.fly(to: target, in: proxy, frame: frame, onSettle: landing)
    }
    if let bubbleFrame {
      morphLanding = landing
      if let morph = stage.morph {
        morph.retarget(to: bubbleFrame, onSettle: landing)
      } else {
        stage.beginMorph(toward: bubbleFrame, onSettle: landing)
      }
      if let textView = proxy.transcriptSendDescendant(ofType: TranscriptSendTextView.self),
        let glyphs = TranscriptSendStaging.renderedGlyphs(of: textView)
      {
        let textFrame = Self.rect(of: textView, textView.bounds, in: space)
        stage.adoptGlyphs(glyphs, frame: textFrame.offsetBy(dx: -bubbleFrame.minX, dy: -bubbleFrame.minY))
      } else if stage.isMultiline {
        stage.rewrap(
          toTextWidth: bubbleFrame.width - TranscriptSendFlightGeometry.bubbleTextInsets.horizontal * 2)
      }
      proxy.setTranscriptSendOpacity(0)
    } else if !flying.isEmpty {
      snapshot.transcriptSendLayer?.add(
        TranscriptSendLayerAnimations.fade(from: 1, to: 0, duration: TranscriptSendMotion.followerFadeDuration),
        forKey: "codevisor.send-flight.fade")
      snapshot.setTranscriptSendOpacity(0)
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
    guard target.window != nil, target.window === overlay.window else {
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
    let origin = Self.rect(of: target, target.bounds, in: space).origin
    let delta = CGSize(width: origin.x - targetOrigin.x, height: origin.y - targetOrigin.y)
    guard abs(delta.width) > 0.5 || abs(delta.height) > 0.5 else { return }
    targetOrigin = origin
    shiftSerial &+= 1
    let key = TranscriptSendAnimationKeys.shiftPrefix + String(shiftSerial)
    if let morph = stage.morph, let landing = morphLanding {
      proxy.frame = proxy.frame.offsetBy(dx: delta.width, dy: delta.height)
      morph.retarget(to: morph.end.offsetBy(dx: delta.width, dy: delta.height), onSettle: landing)
      for piece in pieces { piece.shift(by: delta, key: key) }
      return
    }
    let back = CGSize(width: -delta.width, height: -delta.height)

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for piece in pieces { piece.shift(by: delta, key: key) }
    for view in [proxy, stage.snapshot] {
      view.frame = view.frame.offsetBy(dx: delta.width, dy: delta.height)
      view.transcriptSendLayer?.add(
        TranscriptSendLayerAnimations.translation(back, spring: TranscriptSendMotion.content), forKey: key)
    }
    CATransaction.commit()
  }

  public func rideScroll(of target: TranscriptSendPlatformView, in document: TranscriptSendPlatformView) {
    guard !hasEnded, !Self.rides(stage), let space, stage.track.superview !== document,
      target.window === space.window, document.window === space.window
    else { return }
    let origin = Self.rect(of: target, target.bounds, in: space).origin
    stage.track.shift(by: CGSize(width: origin.x - targetOrigin.x, height: origin.y - targetOrigin.y))
    stage.track.move(into: document)
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
    in space: TranscriptSendPlatformView
  ) -> CGRect {
    space.convert(rect, from: view)
  }

  private func settle() {
    pendingSettles -= 1
    guard pendingSettles <= 0 else { return }
    transcriptSendLog.debug("flight settled")
    land()
  }

  public func land() {
    guard !hasEnded else { return }
    hasEnded = true
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    TranscriptSendAttachmentDepartures.shared.arrive(pieces)
    for piece in pieces { piece.removeFromSuperview() }
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

  func transcriptSendDescendants<View: TranscriptSendPlatformView>(ofType type: View.Type) -> [View] {
    subviews.flatMap { subview in
      (subview as? View).map { [$0] } ?? subview.transcriptSendDescendants(ofType: type)
    }
  }

  func transcriptSendDescendant<View: TranscriptSendPlatformView>(ofType type: View.Type) -> View? {
    for subview in subviews {
      if let match = subview as? View { return match }
      if let match = subview.transcriptSendDescendant(ofType: type) { return match }
    }
    return nil
  }
}
