import CodevisorCore
import CodevisorUI
import SwiftUI

struct CloudSettingsView: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var showsServer = false
  @State private var showsConnections = false
  @State private var showsEmailSignIn = false
  @State private var isConfirmingDataDeletion = false

  var body: some View {
    Form {
      CloudAccountSections(
        cloud: environment.cloud,
        manageConnections: { showsConnections = true },
        configureServer: { showsServer = true },
        signInWithEmail: { showsEmailSignIn = true }
      )
      privacySection
      dataSection
    }
    .formStyle(.grouped)
    .confirmationDialog(
      "Delete all Codevisor data?",
      isPresented: $isConfirmingDataDeletion,
      titleVisibility: .visible
    ) {
      Button("Delete everything", role: .destructive) {
        environment.deleteAllData()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This can't be undone. You'll be taken back through setup.")
    }
    .sheet(isPresented: $showsEmailSignIn) { CloudEmailAuthSheet(cloud: environment.cloud) }
    .sheet(isPresented: $showsServer) {
      NavigationStack {
        CloudServerSettings(cloud: environment.cloud)
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") { showsServer = false }
            }
          }
      }
      .frame(width: 460, height: 340)
    }
    .sheet(isPresented: $showsConnections) {
      NavigationStack {
        CloudConnectedAccountsSettings(cloud: environment.cloud)
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") { showsConnections = false }
            }
          }
      }
      .frame(width: 460, height: 400)
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
          isConfirmingDataDeletion = true
        }
        .fixedSize()
      }
    }
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
