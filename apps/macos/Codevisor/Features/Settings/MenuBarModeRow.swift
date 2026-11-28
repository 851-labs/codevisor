import SwiftUI

struct MenuBarModeRow: View {
  @State private var isConfirmingRestart = false

  var body: some View {
    Toggle("Menu bar mode", isOn: isOn)
      .toggleStyle(.switch)
      .confirmationDialog(restartTitle, isPresented: $isConfirmingRestart, titleVisibility: .visible) {
        Button("Restart") { MenuBarMode.restart(enabled: !MenuBarMode.isEnabled) }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(restartMessage)
      }
  }

  private var isOn: Binding<Bool> {
    Binding(
      get: { MenuBarMode.isEnabled },
      set: { _ in isConfirmingRestart = true }
    )
  }

  private var restartTitle: String {
    if MenuBarMode.isEnabled {
      "Turn off menu bar mode?"
    } else {
      "Turn on menu bar mode?"
    }
  }

  private var restartMessage: String {
    if MenuBarMode.isEnabled {
      "Codevisor will restart as a regular app. Your chats keep running."
    } else {
      "Codevisor will restart in the menu bar and stop sending notifications on this Mac. Your chats keep running."
    }
  }
}
