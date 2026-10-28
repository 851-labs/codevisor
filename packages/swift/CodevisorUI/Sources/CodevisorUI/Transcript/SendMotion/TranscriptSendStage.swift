import QuartzCore
import SwiftUI

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

@MainActor
public final class TranscriptSendStage {
  let snapshot: TranscriptSendPillView
  private(set) var editorFrame: CGRect
  private(set) var textRect: CGRect
  let lineHeight: CGFloat
  let text: NSAttributedString?
  private(set) var pieces: [TranscriptSendAttachmentPiece]
  private(set) var wrappedTextWidth: CGFloat?
  let track: TranscriptSendTrack
  var timeout: DispatchWorkItem?
  #if canImport(UIKit)
    private(set) var carrier: TranscriptSendCarrier?
  #endif
  private(set) var morph: TranscriptSendMorph?

  init(
    snapshot: TranscriptSendPillView,
    editorFrame: CGRect,
    textRect: CGRect,
    lineHeight: CGFloat,
    text: NSAttributedString?,
    pieces: [TranscriptSendAttachmentPiece],
    track: TranscriptSendTrack
  ) {
    self.snapshot = snapshot
    self.editorFrame = editorFrame
    self.textRect = textRect
    self.lineHeight = lineHeight
    self.text = text
    self.pieces = pieces
    self.track = track
  }

  var overlay: TranscriptSendOverlayView? { track.superview as? TranscriptSendOverlayView }

  func releasePieces() -> [TranscriptSendAttachmentPiece] {
    defer { pieces = [] }
    return pieces
  }

  private var visibleTextRect: CGRect {
    let visible = textRect.intersection(editorFrame)
    return visible.isNull || visible.isEmpty ? textRect : visible
  }

  var isMultiline: Bool {
    lineHeight > 0 && visibleTextRect.height >= lineHeight * 1.5
  }

  func adoptGlyphs(_ glyphs: TranscriptSendPlatformView, frame: CGRect) {
    for old in snapshot.subviews { old.removeFromSuperview() }
    glyphs.frame = frame
    snapshot.addSubview(glyphs)
    wrappedTextWidth = frame.width
  }

  @discardableResult
  func rewrap(toTextWidth width: CGFloat) -> CGFloat? {
    if let wrappedTextWidth, abs(wrappedTextWidth - width) < 1 { return nil }
    guard let text, width > 0,
      let (glyphs, height) = TranscriptSendStaging.renderedText(text, width: width, appearanceOf: snapshot)
    else { return nil }
    let insets = TranscriptSendFlightGeometry.bubbleTextInsets
    for old in snapshot.subviews { old.removeFromSuperview() }
    glyphs.frame = CGRect(x: insets.horizontal, y: insets.vertical, width: width, height: height)
    snapshot.addSubview(glyphs)
    wrappedTextWidth = width
    return height
  }

  func beginMorph(toward end: CGRect, onSettle: (() -> Void)? = nil) {
    guard morph == nil else { return }
    snapshot.revealFill()
    morph = TranscriptSendMorph(pill: snapshot, from: snapshot.frame, to: end, onSettle: onSettle)
  }

  func beginMorph(toward landing: TranscriptSendLanding) {
    var landing = landing
    let spacing = TranscriptSendFlightGeometry.attachmentSpacing
    let column = TranscriptSendAttachmentGeometry.column(
      sizes: pieces.map(\.sentSize), trailing: landing.trailing, top: landing.top, spacing: spacing)
    for (piece, frame) in zip(pieces, column) { piece.fly(toward: frame) }
    if let bottom = column.map(\.maxY).max() { landing.top = bottom + spacing }
    var end = TranscriptSendMorphGeometry.predictedEnd(
      start: snapshot.frame, editorFrame: editorFrame, textRect: textRect,
      lineHeight: lineHeight, landing: landing)
    let insets = TranscriptSendFlightGeometry.bubbleTextInsets
    let textWidth = end.width - insets.horizontal * 2
    if isMultiline || visibleTextRect.width > textWidth + 0.5 {
      if let height = rewrap(toTextWidth: textWidth) {
        end.size.height = height + insets.vertical * 2
      }
    }
    beginMorph(toward: end)
  }

  #if canImport(UIKit)
    func board(_ carrier: TranscriptSendCarrier?) {
      guard let overlay else { return }
      let space: UIView = carrier?.view ?? track
      func boarded(_ view: UIView) -> CGRect {
        let onScreen: CGRect
        if let layer = view.layer.presentation(), let overlayLayer = overlay.layer.presentation() {
          onScreen = layer.convert(layer.bounds, to: overlayLayer)
        } else {
          onScreen = overlay.convert(view.bounds, from: view)
        }
        return carrier?.rect(displayedAt: onScreen, in: overlay) ?? track.convert(onScreen, from: overlay)
      }
      let frame = boarded(snapshot)
      let pieceFrames = pieces.map(boarded)
      let dx = frame.minX - snapshot.frame.minX
      let dy = frame.minY - snapshot.frame.minY
      UIView.performWithoutAnimation {
        for (piece, pieceFrame) in zip(pieces, pieceFrames) {
          space.addSubview(piece)
          piece.frame = pieceFrame
        }
        space.addSubview(snapshot)
        snapshot.frame = frame
      }
      editorFrame = editorFrame.offsetBy(dx: dx, dy: dy)
      textRect = textRect.offsetBy(dx: dx, dy: dy)
      self.carrier?.remove()
      self.carrier = carrier
    }
  #endif

  func remove(animated: Bool) {
    timeout?.cancel()
    timeout = nil
    let snapshot = snapshot
    let track = track
    let overlay = overlay
    let pieces = releasePieces()
    TranscriptSendAttachmentDepartures.shared.arrive(pieces)
    #if canImport(UIKit)
      let carrier = carrier
      self.carrier = nil
    #endif
    guard animated, snapshot.superview != nil else {
      for piece in pieces { piece.removeFromSuperview() }
      snapshot.removeFromSuperview()
      track.removeFromSuperview()
      #if canImport(UIKit)
        carrier?.remove()
      #endif
      overlay?.releaseIfIdle()
      return
    }
    CATransaction.begin()
    CATransaction.setCompletionBlock {
      MainActor.assumeIsolated {
        for piece in pieces { piece.removeFromSuperview() }
        snapshot.removeFromSuperview()
        track.removeFromSuperview()
        #if canImport(UIKit)
          carrier?.remove()
        #endif
        overlay?.releaseIfIdle()
      }
    }
    snapshot.transcriptSendLayer?.add(
      TranscriptSendLayerAnimations.fade(from: 1, to: 0, duration: 0.15),
      forKey: TranscriptSendAnimationKeys.follower
    )
    snapshot.setTranscriptSendOpacity(0)
    for piece in pieces {
      piece.transcriptSendLayer?.add(
        TranscriptSendLayerAnimations.fade(from: 1, to: 0, duration: 0.15),
        forKey: TranscriptSendAnimationKeys.follower
      )
      piece.setTranscriptSendOpacity(0)
    }
    CATransaction.commit()
  }
}
