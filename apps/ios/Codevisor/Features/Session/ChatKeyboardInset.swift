import QuartzCore
import SwiftUI
import UIKit

@MainActor
final class ChatKeyboardInset {
  static let animation = Animation.interpolatingSpring(mass: 1, stiffness: 400, damping: 40)
  static let trackingStepLimit: CGFloat = 40
  static let trackingFrameGap: CFTimeInterval = 0.05
  static let cancelledTransitionTimeout: Duration = .seconds(1)

  weak var anchor: UIView?
  private var lastMeasurementTime: CFTimeInterval = 0
  private var heldOverlap: CGFloat?
  private var awaitsKeyboardReturn = false
  private var holdGeneration = 0
  private var appliesNextImmediately = true

  enum Adoption {
    case hold
    case apply(animated: Bool)
  }

  func adoption(
    of measured: CGFloat,
    from current: CGFloat,
    release: @escaping @MainActor () -> Void
  ) -> Adoption {
    let now = CACurrentMediaTime()
    defer { lastMeasurementTime = now }
    if let heldOverlap {
      guard awaitsKeyboardReturn, abs(measured - heldOverlap) < 0.5 else { return .hold }
      endHold()
    } else if let coordinator = leavingTransitionCoordinator() {
      beginHold(at: current, coordinator: coordinator, release: release)
      return .hold
    }
    if appliesNextImmediately {
      appliesNextImmediately = false
      return .apply(animated: false)
    }
    let step = abs(measured - current)
    let isTracking = step <= Self.trackingStepLimit && now - lastMeasurementTime < Self.trackingFrameGap
    return .apply(animated: !isTracking)
  }

  private func beginHold(
    at overlap: CGFloat,
    coordinator: any UIViewControllerTransitionCoordinator,
    release: @escaping @MainActor () -> Void
  ) {
    heldOverlap = overlap
    awaitsKeyboardReturn = false
    holdGeneration &+= 1
    let generation = holdGeneration
    coordinator.animate(alongsideTransition: nil) { [weak self] context in
      guard let self, self.holdGeneration == generation else { return }
      if context.isCancelled {
        self.awaitsKeyboardReturn = true
        release()
        Task { @MainActor [weak self] in
          try? await Task.sleep(for: Self.cancelledTransitionTimeout)
          guard let self, self.holdGeneration == generation, self.heldOverlap != nil else { return }
          self.endHold()
          release()
        }
      } else {
        self.endHold()
        self.appliesNextImmediately = true
        release()
      }
    }
  }

  private func endHold() {
    heldOverlap = nil
    awaitsKeyboardReturn = false
    holdGeneration &+= 1
  }

  private func leavingTransitionCoordinator() -> (any UIViewControllerTransitionCoordinator)? {
    guard let anchor, anchor.window != nil else { return nil }
    var responder: UIResponder? = anchor
    while let next = responder?.next {
      if let navigation = (next as? UIViewController)?.navigationController,
        let coordinator = navigation.transitionCoordinator
      {
        guard let leaving = coordinator.view(forKey: .from) ?? coordinator.viewController(forKey: .from)?.view,
          anchor.isDescendant(of: leaving)
        else { return nil }
        return coordinator
      }
      responder = next
    }
    return nil
  }
}

struct ChatKeyboardInsetAnchor: UIViewRepresentable {
  let inset: ChatKeyboardInset

  func makeUIView(context _: Context) -> UIView {
    let view = UIView()
    view.isUserInteractionEnabled = false
    view.isAccessibilityElement = false
    inset.anchor = view
    return view
  }

  func updateUIView(_ view: UIView, context _: Context) {
    inset.anchor = view
  }
}
