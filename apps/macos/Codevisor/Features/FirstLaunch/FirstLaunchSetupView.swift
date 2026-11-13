import CodevisorCore
import CodevisorUI
import SwiftUI

struct FirstLaunchSetupView<Footer: View>: View {
  let setup: FirstLaunchSetup
  let phase: FirstLaunchOverlayPhase
  let composerFrame: CGRect?
  let composerCornerRadius: CGFloat
  @ViewBuilder let footer: () -> Footer
  @State private var cardFrame: CGRect?

  var body: some View {
    let morph = FirstLaunchMorph(
      phase: phase,
      cardFrame: cardFrame,
      composerFrame: composerFrame,
      composerCornerRadius: composerCornerRadius
    )
    IconAnchoredStack {
      CodevisorAppIconView(size: 72)
        .animation(FirstLaunchMorph.contentFade) { $0.opacity(morph.contentOpacity) }
      FirstLaunchSetupTitle(isFinished: setup.isComplete)
        .animation(FirstLaunchMorph.contentFade) { $0.opacity(morph.contentOpacity) }
      card(morph)
      footer()
        .animation(FirstLaunchMorph.contentFade) { $0.opacity(morph.contentOpacity) }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .ignoresSafeArea()
    .accessibilityElement(children: .contain)
    .accessibilityLabel(FirstLaunchSetupTitle.settingUp)
  }

  private func card(_ morph: FirstLaunchMorph) -> some View {
    ProgressStepList(steps: FirstLaunchStep.allCases.map(progressStep))
      .animation(FirstLaunchMorph.contentFade) { $0.opacity(morph.contentOpacity) }
      .background { FirstLaunchCardGlass(shape: morph.glass) }
      .modifier(FirstLaunchMeasurement(isFrozen: phase.isLeaving) { cardFrame = $0 })
  }

  private func progressStep(_ step: FirstLaunchStep) -> ProgressStep {
    ProgressStep(
      id: "\(step)",
      title: step.title,
      state: Self.state(for: setup.revealed(step)),
      details: setup.detailCandidates(for: step)
    )
  }

  private static func state(for outcome: FirstLaunchStepOutcome) -> ProgressStepState {
    switch outcome {
    case .pending: .pending
    case .running: .running
    case .done: .done
    case .skipped: .skipped
    case .failed: .failed
    }
  }
}
