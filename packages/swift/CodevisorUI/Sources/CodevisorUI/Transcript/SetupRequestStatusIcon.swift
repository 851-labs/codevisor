import SwiftUI
import TranscriptKit

struct SetupRequestStatusIcon: View {
  let state: TranscriptSetupRequest.State

  var body: some View {
    switch state {
    case .pending:
      EmptyView()
    case .setUp:
      Image(systemName: "checkmark.circle.fill")
        .imageScale(.large)
        .foregroundStyle(.green)
        .accessibilityLabel("Set up")
    case .declined:
      Image(systemName: "circle")
        .imageScale(.large)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Declined")
    }
  }
}
