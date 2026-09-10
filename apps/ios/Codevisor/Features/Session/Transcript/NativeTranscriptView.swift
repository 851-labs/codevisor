import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import UIKit

enum TranscriptSendAnimationMetrics {
  static let duration = TranscriptSendAnimationContract.duration

  static func plan(
    sourceY: CGFloat,
    targetY: CGFloat,
    reduceMotion: Bool = false
  ) -> TranscriptSendAnimationPlan? {
    TranscriptSendAnimationContract.plan(
      sourceY: sourceY,
      targetY: targetY,
      reduceMotion: reduceMotion
    )
  }

  /// Creates a fresh Core Animation group from the shared motion plan.
  /// Ordinary rows and the cross-sheet snapshot both call this factory, so
  /// their position, fade, duration, and easing cannot drift apart.
  static func layerAnimation(
    plan: TranscriptSendAnimationPlan,
    fadesIn: Bool
  ) -> CAAnimationGroup {
    TranscriptSendAnimationLayerAnimations.flight(plan: plan, fadesIn: fadesIn)
  }

  static var propertyTimingParameters: UICubicTimingParameters {
    UICubicTimingParameters(
      controlPoint1: TranscriptSendAnimationContract.controlPoint1,
      controlPoint2: TranscriptSendAnimationContract.controlPoint2
    )
  }
}

/// SwiftUI boundary around the UIKit virtualizer. One dedicated container
/// controller owns every row host, keeping transcript content out of the
/// surrounding navigation controller's containment tree.
struct NativeTranscriptView: UIViewControllerRepresentable {
  let presentationSurface: TranscriptPresentationSurface
  let input: TranscriptSurfaceInput
  let callbacks: TranscriptSurfaceCallbacks

  func makeUIViewController(context _: Context) -> TranscriptContainerViewController {
    let container = TranscriptContainerViewController()
    let controller = container.attach(presentationSurface)
    controller.configure(input, callbacks: callbacks)
    return container
  }

  func updateUIViewController(
    _ container: TranscriptContainerViewController,
    context _: Context,
  ) {
    container.attach(presentationSurface).configure(input, callbacks: callbacks)
  }

  static func dismantleUIViewController(
    _ container: TranscriptContainerViewController,
    coordinator _: Void,
  ) {
    container.releaseSurface()
  }
}
