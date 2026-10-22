import AppKit
import CodevisorCore
import SwiftUI

struct FirstLaunchSetupView: View {
  let setup: FirstLaunchSetup

  var body: some View {
    VStack(spacing: 22) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 72, height: 72)
        .shadow(color: .black.opacity(0.18), radius: 9, y: 5)
        .accessibilityHidden(true)
      FirstLaunchSetupTitle(isFinished: setup.isComplete)
      VStack(alignment: .leading, spacing: 10) {
        ForEach(FirstLaunchStep.allCases) { step in
          FirstLaunchStepRow(
            step: step,
            outcome: setup.revealed(step),
            details: setup.detailCandidates(for: step)
          )
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 16)
      .frame(width: 440)
      .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Getting things set up")
  }
}
