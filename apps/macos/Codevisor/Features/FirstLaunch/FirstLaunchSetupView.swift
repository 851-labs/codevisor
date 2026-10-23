import AppKit
import CodevisorCore
import SwiftUI

struct FirstLaunchSetupView: View {
  let setup: FirstLaunchSetup
  let phase: FirstLaunchOverlayPhase
  let composerFrame: CGRect?
  let composerCornerRadius: CGFloat
  @State private var cardFrame: CGRect?

  var body: some View {
    let morph = FirstLaunchMorph(
      phase: phase,
      cardFrame: cardFrame,
      composerFrame: composerFrame,
      composerCornerRadius: composerCornerRadius
    )
    VStack(spacing: 22) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 72, height: 72)
        .shadow(color: .black.opacity(0.18), radius: 9, y: 5)
        .accessibilityHidden(true)
        .animation(FirstLaunchMorph.contentFade) { $0.opacity(morph.contentOpacity) }
      FirstLaunchSetupTitle(isFinished: setup.isComplete)
        .animation(FirstLaunchMorph.contentFade) { $0.opacity(morph.contentOpacity) }
      card(morph)
      FirstLaunchGetStartedButton(isReady: setup.canGetStarted) { setup.getStarted() }
        .animation(FirstLaunchMorph.contentFade) { $0.opacity(morph.contentOpacity) }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Getting things set up")
  }

  private func card(_ morph: FirstLaunchMorph) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(FirstLaunchStep.allCases) { step in
        FirstLaunchStepRow(
          step: step,
          outcome: setup.revealed(step),
          details: setup.detailCandidates(for: step),
          count: step == .projects ? setup.visibleProjectCount : nil
        )
      }
    }
    .animation(FirstLaunchMorph.contentFade) { $0.opacity(morph.contentOpacity) }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
    .frame(width: 440)
    .background { FirstLaunchCardGlass(shape: morph.glass) }
    .modifier(FirstLaunchMeasurement(isFrozen: phase.isLeaving) { cardFrame = $0 })
  }
}
