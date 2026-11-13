import CodevisorCore
import SwiftUI

struct LaunchFailureButtons: View {
  let failure: LaunchFailure
  let actions: LaunchActions
  @Environment(\.openURL) private var openURL

  var body: some View {
    VStack(spacing: 14) {
      HStack(spacing: 10) {
        Button("Try Again") { actions.tryAgain(failure) }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
        secondaryButton
      }
      .controlSize(.large)
      Button("Report Issue…") { openURL(report.url) }
        .buttonStyle(.link)
        .help("Opens a new GitHub issue with these details filled in. Check them before you post.")
    }
  }

  @ViewBuilder
  private var secondaryButton: some View {
    if failure.canContinue {
      Button("Continue Anyway") { actions.continueAnyway(failure) }
        .help("Opens Codevisor without this Mac. Your other machines keep working.")
    } else {
      Button("Show Data Folder", action: actions.showDataFolder)
    }
  }

  private var report: LaunchIssueReport {
    LaunchIssueReport(
      failure: failure,
      appVersion: AppUpdateModel.bundleVersion(),
      systemVersion: ProcessInfo.processInfo.operatingSystemVersionString
    )
  }
}
