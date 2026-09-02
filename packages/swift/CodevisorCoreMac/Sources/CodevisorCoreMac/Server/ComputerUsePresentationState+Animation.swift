import AppKit
import CodevisorCore
import CoreGraphics
import Foundation
import QuartzCore

extension ComputerUsePresentationState {
  func animateMove(
    presentation: inout SessionPresentation,
    sessionID: String,
    to target: CGPoint
  ) {
    let start =
      presentation.displayedTip
      ?? constrained(
        CGPoint(x: target.x - 74, y: target.y + 42)
      )
    let distance = hypot(target.x - start.x, target.y - start.y)
    if distance < 1 {
      place(presentation: presentation, tip: target, rotation: 0, bodyOffset: .zero)
      return
    }

    presentation.cursorPanel.alphaValue = presentation.displayedTip == nil ? 0 : 1
    order(presentation.cursorPanel, relativeTo: presentation.targetWindowID)
    let duration = min(0.62, max(0.22, 0.18 + Double(distance / 1_350)))
    let direction = CGVector(dx: target.x - start.x, dy: target.y - start.y)
    let unit = CGVector(dx: direction.dx / distance, dy: direction.dy / distance)
    let normal = CGVector(dx: -unit.dy, dy: unit.dx)
    let side: CGFloat = computerUseStableHash(sessionID) & 1 == 0 ? 1 : -1
    let arc = min(86, max(18, distance * 0.16)) * side
    let control1 = CGPoint(
      x: start.x + direction.dx * 0.34 + normal.dx * arc,
      y: start.y + direction.dy * 0.34 + normal.dy * arc
    )
    let control2 = CGPoint(
      x: target.x - direction.dx * 0.26 + normal.dx * arc * 0.42,
      y: target.y - direction.dy * 0.26 + normal.dy * arc * 0.42
    )

    let startTime = CACurrentMediaTime()
    var previous = start
    while true {
      let elapsed = CACurrentMediaTime() - startTime
      let raw = min(1, max(0, elapsed / duration))
      let t = CGFloat(1 - pow(1 - raw, 3))
      let point = cubicBezier(start, control1, control2, target, t: t)
      let velocity = CGVector(dx: point.x - previous.x, dy: point.y - previous.y)
      let rotation = min(0.18, max(-0.18, atan2(velocity.dy, velocity.dx) * 0.08))
      let bodyOffset = CGVector(
        dx: min(3.2, max(-3.2, velocity.dx * -0.13)),
        dy: min(3.2, max(-3.2, velocity.dy * -0.13))
      )
      place(
        presentation: presentation,
        tip: point,
        rotation: rotation,
        bodyOffset: bodyOffset
      )
      presentation.cursorPanel.alphaValue = min(1, presentation.cursorPanel.alphaValue + 0.12)
      previous = point
      if raw >= 1 { break }
      pumpFrame()
    }
    place(presentation: presentation, tip: target, rotation: 0, bodyOffset: .zero)
  }

  func startIdleAnimation(sessionID: String) {
    guard var presentation = sessions[sessionID], presentation.displayedTip != nil else {
      return
    }
    presentation.idleTimer?.invalidate()
    presentation.idlePhase = 0
    let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
      // Scheduled on RunLoop.main, so the fast path always runs; the
      // dispatch fallback only guards against a stray off-main fire
      // trapping `MainActor.assumeIsolated`.
      let tick: @MainActor () -> Void = {
        self?.tickIdleAnimation(sessionID: sessionID)
      }
      if Thread.isMainThread {
        MainActor.assumeIsolated(tick)
      } else {
        DispatchQueue.main.async(execute: tick)
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    presentation.idleTimer = timer
    sessions[sessionID] = presentation
  }

  private func tickIdleAnimation(sessionID: String) {
    guard var presentation = sessions[sessionID], let tip = presentation.displayedTip else {
      return
    }
    presentation.idlePhase += 0.05
    let angle = sin(presentation.idlePhase * 0.8) * 0.09
    place(
      presentation: presentation,
      tip: tip,
      rotation: angle,
      bodyOffset: .zero,
      rotationAroundCenter: true
    )
    sessions[sessionID] = presentation
  }

  func animateClick(presentation: SessionPresentation, at point: CGPoint) {
    let duration: CFTimeInterval = 0.18
    let start = CACurrentMediaTime()
    while true {
      let progress = min(1, max(0, (CACurrentMediaTime() - start) / duration))
      presentation.cursorView.clickProgress = CGFloat(sin(progress * .pi))
      presentation.cursorView.needsDisplay = true
      if progress >= 1 { break }
      pumpFrame()
    }
    presentation.cursorView.clickProgress = 0
    presentation.cursorView.needsDisplay = true
    place(presentation: presentation, tip: point, rotation: 0, bodyOffset: .zero)
  }

  func place(
    presentation: SessionPresentation,
    tip: CGPoint,
    rotation: CGFloat,
    bodyOffset: CGVector,
    rotationAroundCenter: Bool = false
  ) {
    presentation.cursorPanel.setFrameOrigin(computerUseCursorPanelOrigin(for: tip))
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

  private func cubicBezier(
    _ p0: CGPoint,
    _ p1: CGPoint,
    _ p2: CGPoint,
    _ p3: CGPoint,
    t: CGFloat
  ) -> CGPoint {
    let u = 1 - t
    return CGPoint(
      x: u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x,
      y: u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y
    )
  }

  private func pumpFrame() {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(1 / 120))
  }
}
