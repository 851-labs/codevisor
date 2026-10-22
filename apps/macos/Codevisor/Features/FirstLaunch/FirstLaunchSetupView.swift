import AppKit
import CodevisorCore
import SwiftUI

struct FirstLaunchSetupView: View {
  let setup: FirstLaunchSetup
  let stage: FirstLaunchStage
  @State private var frames = FirstLaunchFrames()

  var body: some View {
    let move = FirstLaunchChoreography(stage: stage, frames: frames)
    VStack(spacing: 22) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 72, height: 72)
        .shadow(color: .black.opacity(0.18), radius: 9, y: 5)
        .accessibilityHidden(true)
        .modifier(measure { frames.icon = $0 })
        .modifier(move.icon())
      FirstLaunchSetupTitle(isFinished: setup.isComplete)
        .modifier(move.chrome())
      card(move)
      FirstLaunchGetStartedButton(isReady: setup.canGetStarted) { setup.getStarted() }
        .modifier(move.chrome())
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Getting things set up")
  }

  private func card(_ move: FirstLaunchChoreography) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(FirstLaunchStep.allCases) { step in
        FirstLaunchStepRow(
          step: step,
          outcome: setup.revealed(step),
          details: setup.detailCandidates(for: step),
          count: step == .projects ? setup.visibleProjectCount : nil
        )
        .modifier(measure { frames.rows[step] = $0 })
        .modifier(move.row(step))
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
    .frame(width: 440)
    .background { FirstLaunchCardGlass(shape: move.glass()) }
    .modifier(measure { frames.card = $0 })
    .modifier(move.card())
  }

  private func measure(_ report: @escaping (CGRect) -> Void) -> FirstLaunchMeasurement {
    FirstLaunchMeasurement(isFrozen: stage.isLeaving, report: report)
  }
}
