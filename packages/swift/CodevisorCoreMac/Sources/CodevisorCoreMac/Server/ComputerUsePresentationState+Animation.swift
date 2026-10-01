import AppKit
import CodevisorCore
import CoreGraphics
import Foundation
import QuartzCore

extension ComputerUsePresentationState {
  /// A bounded compositor animation, without pumping/re-entering the main
  /// run loop or delaying the actual input. Idle cursors never animate.
  func animateClick(presentation: SessionPresentation, at point: CGPoint) {
    let pulse = CABasicAnimation(keyPath: "opacity")
    pulse.fromValue = 0.45
    pulse.toValue = 1
    pulse.duration = 0.18
    presentation.cursorView.layer?.add(pulse, forKey: "computer-use-click")
  }

  func place(
    presentation: SessionPresentation,
    tip: CGPoint,
    rotation: CGFloat,
    bodyOffset: CGVector,
    rotationAroundCenter: Bool = false
  ) {
    let origin = computerUseCursorPanelOrigin(for: tip)
    if presentation.cursorPanel.frame.origin != origin {
      presentation.cursorPanel.setFrameOrigin(origin)
    }
    presentation.cursorView.rotation = rotation
    presentation.cursorView.rotationAroundCenter = rotationAroundCenter
    presentation.cursorView.bodyOffset = bodyOffset
    presentation.cursorView.needsDisplay = true
  }

  func configureCursorPanel(_ panel: NSPanel) {
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    // Stay in the normal window band and pin immediately above the target.
    // A floating panel would incorrectly draw over unrelated foreground
    // windows that merely overlap the controlled window.
    panel.level = .normal
    panel.collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
      .stationary,
      .ignoresCycle,
    ]
    panel.animationBehavior = .none
  }

}
