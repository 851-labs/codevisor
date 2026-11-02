import CodevisorClient
import CodevisorCore
import CodevisorUI
import SwiftUI

struct ServerDataUpgradePresentation: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.openSettings) private var openSettings

  func body(content: Content) -> some View {
    content
      .sheet(isPresented: Binding(get: { presentation != nil }, set: { _ in })) {
        if let presentation {
          ServerDataUpgradeSheet(
            progress: presentation.progress,
            startupProgress: environment.localServer?.startupProgress,
            failureMessage: presentation.failureMessage,
            restart: { AppRelauncher.relaunch() },
            checkForUpdates: {
              SettingsRouter.shared.showUpdates()
              openSettings()
            }
          )
          .interactiveDismissDisabled(true)
        }
      }
  }

  private var presentation: ServerDataUpgradePresentationState? {
    guard let localServer = environment.localServer else { return nil }
    return ServerDataUpgradePresentationState(
      progress: localServer.dataUpgradeProgress,
      serverState: localServer.state
    )
  }
}

struct ServerDataUpgradePresentationState: Equatable {
  let progress: LocalDataUpgradeProgress
  let failureMessage: String?

  init?(progress: LocalDataUpgradeProgress?, serverState: LocalCodevisorServerState) {
    guard let progress else { return nil }
    switch progress.state {
    case "failed":
      self.progress = progress
      failureMessage = progress.error ?? "Codevisor couldn't finish updating the server's data."
    case "running":
      self.progress = progress
      if case let .unavailable(message) = serverState {
        failureMessage = message
      } else {
        failureMessage = nil
      }
    default:
      return nil
    }
  }
}

struct ServerDataUpgradeSheet: View {
  let progress: LocalDataUpgradeProgress
  let startupProgress: LocalServerStartupProgress?
  let failureMessage: String?
  let restart: () -> Void
  var checkForUpdates: (() -> Void)? = nil

  private var isFailed: Bool { failureMessage != nil }

  var body: some View {
    ProgressStepScreen(
      title: isFailed ? "Server Data Update Failed" : "Updating Server Data",
      steps: LocalServerStartupSteps.steps(for: startupProgress, isFailed: isFailed, currentDetails: migrationDetails),
      note: failureMessage
    ) {
      if isFailed {
        ServerDataUpgradeFailureActions(restart: restart, checkForUpdates: checkForUpdates)
      }
    }
    .frame(width: 520)
  }

  private var migrationDetails: [String] {
    ProgressStepDetailText.count(name: progress.name, completed: progress.completed, total: progress.total)
  }
}

private struct ServerDataUpgradeFailureActions: View {
  let restart: () -> Void
  let checkForUpdates: (() -> Void)?

  var body: some View {
    HStack(spacing: 10) {
      Button("Restart", action: restart)
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
      if let checkForUpdates {
        Button("Check for Updates…", action: checkForUpdates)
          .buttonStyle(.bordered)
          .help("Opens Settings › Updates. A newer Codevisor may fix this.")
      }
    }
  }
}

#Preview("Running") {
  ServerDataUpgradeSheet(
    progress: LocalDataUpgradeProgress(
      state: "running", id: "canonical-session-chat-v1", name: "Updating chat history",
      completed: 40, total: 100),
    startupProgress: LocalServerStartupProgress(stage: "openingDatabase", completed: 3),
    failureMessage: nil,
    restart: {}
  )
}

#Preview("Failed") {
  ServerDataUpgradeSheet(
    progress: LocalDataUpgradeProgress(
      state: "failed", id: "database-startup", name: "Applying update", completed: 0, total: 0,
      error: "SQLITE_FULL: database or disk is full"),
    startupProgress: LocalServerStartupProgress(stage: "openingDatabase", completed: 3),
    failureMessage: "SQLITE_FULL: database or disk is full",
    restart: {},
    checkForUpdates: {}
  )
}
