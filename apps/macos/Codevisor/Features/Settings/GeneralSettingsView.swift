import SwiftUI
import CodevisorCore

struct GeneralSettingsView: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var showingConfirmation = false

  var body: some View {
    Form {
      generalSection
      privacySection
      dataSection
    }
    .formStyle(.grouped)
    .confirmationDialog(
      "Delete all Codevisor data?",
      isPresented: $showingConfirmation,
      titleVisibility: .visible
    ) {
      Button("Delete everything", role: .destructive) {
        environment.deleteAllData()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This can't be undone. You'll be taken back through setup.")
    }
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

  private var privacySection: some View {
    Section {
      Toggle("Share usage analytics", isOn: shareAnalytics)
        .toggleStyle(.switch)
      Toggle("Send crash and error reports", isOn: shareCrashReports)
        .toggleStyle(.switch)
    } header: {
      Text("Privacy")
    } footer: {
      Text(
        "Anonymous. Prompts, responses, code, file paths, browser content, and terminal commands are never included."
      )
    }
  }

  private var dataSection: some View {
    Section("Data") {
      HStack(alignment: .center, spacing: 16) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Delete all data")
          Text("Removes all projects, chats, and settings, then restarts setup.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        Button("Delete…", role: .destructive) {
          showingConfirmation = true
        }
        .fixedSize()
      }
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

  private var shareAnalytics: Binding<Bool> {
    Binding(
      get: { environment.settings.shareAnalytics },
      set: { environment.setShareAnalytics($0) }
    )
  }

  private var shareCrashReports: Binding<Bool> {
    Binding(
      get: { environment.settings.shareCrashReports },
      set: { environment.setShareCrashReports($0) }
    )
  }

}
