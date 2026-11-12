import CodevisorCore
import SwiftUI

struct PaneChatUnavailableView: View {
  enum Reason {
    case connecting(PaneChatMachine)
    case offline(PaneChatMachine)
    case missing
  }

  let reason: Reason
  var action: (() -> Void)?

  var body: some View {
    VStack(spacing: 12) {
      if case .connecting = reason {
        ProgressView()
          .controlSize(.small)
      }
      Text(message)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      if let action, let actionTitle {
        Button(actionTitle, action: action)
      }
    }
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var message: String {
    switch reason {
    case let .connecting(machine): "Connecting to \(machine.name)…"
    case let .offline(machine): "\(machine.name) is offline"
    case .missing: "This chat no longer exists"
    }
  }

  private var actionTitle: String? {
    switch reason {
    case .connecting: nil
    case .offline: "Retry"
    case .missing: "Reset Tab"
    }
  }
}
