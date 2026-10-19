import SwiftUI
import CodevisorCore

struct GeneralSettingsView: View {
  @Environment(AppEnvironment.self) private var environment

  var body: some View {
    Form {
      generalSection
    }
    .formStyle(.grouped)
  }

  private var generalSection: some View {
    Section {
      Toggle("Ask before quitting", isOn: confirmBeforeQuitting)
        .toggleStyle(.switch)
      Toggle("Ask before closing a working chat", isOn: confirmBeforeClosingWorkingChat)
        .toggleStyle(.switch)
    } header: {
      Text("General")
    } footer: {
      Text(
        "Shows a confirmation when you press ⌘Q, or close a chat while its agent is still working, so a stray keystroke can't close something you're relying on."
      )
    }
  }

  private var confirmBeforeQuitting: Binding<Bool> {
    Binding(
      get: { environment.settings.confirmBeforeQuitting },
      set: { environment.settings.setConfirmBeforeQuitting($0) }
    )
  }

  private var confirmBeforeClosingWorkingChat: Binding<Bool> {
    Binding(
      get: { environment.settings.confirmBeforeClosingWorkingChat },
      set: { environment.settings.setConfirmBeforeClosingWorkingChat($0) }
    )
  }
}
