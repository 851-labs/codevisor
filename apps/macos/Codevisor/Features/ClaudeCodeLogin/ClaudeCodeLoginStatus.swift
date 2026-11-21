import CodevisorCore
import SwiftUI

struct ClaudeCodeLoginStatus: View {
  let login: FirstRunClaudeCodeLogin

  var body: some View {
    if login.isAnswering {
      Label {
        Text("Working…")
      } icon: {
        ProgressView().controlSize(.small)
      }
      .font(.callout)
      .foregroundStyle(.secondary)
    } else if let errorMessage = login.errorMessage {
      Label(errorMessage, systemImage: "exclamationmark.triangle")
        .font(.callout)
        .foregroundStyle(.red)
        .multilineTextAlignment(.center)
    }
  }
}
