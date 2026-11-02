import SwiftUI

struct ServerAvailabilityActions: View {
  let machineName: String
  let restart: (() -> Void)?
  let restartIsProminent: Bool
  let useLocalMachine: (() -> Void)?

  var body: some View {
    HStack(spacing: 10) {
      if let restart {
        RestartServerButton(isProminent: restartIsProminent, action: restart)
      }
      if let useLocalMachine {
        Button("Use This Mac Instead", action: useLocalMachine)
          .buttonStyle(.bordered)
          .accessibilityHint("Start new chats on this Mac instead of \(machineName)")
      }
    }
  }
}

private struct RestartServerButton: View {
  let isProminent: Bool
  let action: () -> Void

  var body: some View {
    if isProminent {
      Button("Restart", action: action)
        .buttonStyle(.borderedProminent)
    } else {
      Button("Restart", action: action)
        .buttonStyle(.bordered)
    }
  }
}
