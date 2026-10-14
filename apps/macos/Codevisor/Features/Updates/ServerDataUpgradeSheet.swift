import CodevisorClient
import CodevisorCore
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
  let failureMessage: String?
  let restart: () -> Void
  var checkForUpdates: (() -> Void)? = nil

  private var isFailed: Bool { failureMessage != nil }

  var body: some View {
    VStack(spacing: 18) {
      if isFailed {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 38, weight: .medium))
          .foregroundStyle(.orange)
      } else if progress.total > 0 {
        ProgressView(value: progress.fractionCompleted ?? 0)
          .progressViewStyle(.circular)
          .controlSize(.large)
      } else {
        ProgressView()
          .controlSize(.large)
      }

      VStack(spacing: 7) {
        Text(isFailed ? "Server Data Update Failed" : "Updating Server Data")
          .font(.title2.weight(.semibold))
          .multilineTextAlignment(.center)
        Text(message)
          .font(.body)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 400)
      }

      if !isFailed, progress.total > 0 {
        VStack(spacing: 6) {
          ProgressView(value: Double(progress.completed), total: Double(progress.total))
            .accessibilityLabel(progress.name)
          Text("\(progress.completed) of \(progress.total)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: 320)
      }

      if isFailed {
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
    .padding(32)
    .frame(width: 480)
    .accessibilityElement(children: .contain)
  }

  private var message: String {
    if let failureMessage { return failureMessage }
    return progress.name.isEmpty
      ? "Your cached workspaces are safe. Codevisor will continue when the update finishes."
      : "\(progress.name)\nYour cached workspaces are safe. Codevisor will continue automatically."
  }
}

#Preview("Running") {
  ServerDataUpgradeSheet(
    progress: LocalDataUpgradeProgress(
      state: "running", id: "canonical-session-chat-v1", name: "Updating chat history",
      completed: 40, total: 100),
    failureMessage: nil,
    restart: {}
  )
}

#Preview("Failed") {
  ServerDataUpgradeSheet(
    progress: LocalDataUpgradeProgress(
      state: "failed", id: "database-startup", name: "Applying update", completed: 0, total: 0,
      error: "SQLITE_FULL: database or disk is full"),
    failureMessage: "SQLITE_FULL: database or disk is full",
    restart: {},
    checkForUpdates: {}
  )
}
