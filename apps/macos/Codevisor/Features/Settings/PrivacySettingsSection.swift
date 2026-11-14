import CodevisorCore
import SwiftUI

struct PrivacySettingsSection: View {
  @Environment(AppEnvironment.self) private var environment

  var body: some View {
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
