import CodevisorClient
import CodevisorCore
import SwiftUI

/// Presents the local server's blocking data upgrade as a sheet over the
/// main window. Its own modifier (like `UpdateCenterUpkeep`) so RootView's
/// already-large chain stays within the type checker's budget.
///
/// The sheet cannot be dismissed: nothing in the app can issue a request
/// until the migration finishes, and the New Chat page used to be the only
/// route that explained the wait. It closes itself when the server reports
/// healthy (the sidecar progress clears) and, if the upgrade failed — or the
/// server died mid-upgrade leaving a stale "running" sidecar — switches to
/// the failed layout with a Restart button so the user is never stuck. A
/// failed upgrade is often fixed by a newer build, so that layout also opens
/// Settings › Updates: the sheet is window-modal, and Settings is its own
/// window, so the app update path stays fully usable behind it.
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

/// What the sheet shows, derived from the sidecar report and the local
/// server's lifecycle. Separate from the view so the wedge guard is a plain
/// function.
struct ServerDataUpgradePresentationState: Equatable {
  let progress: LocalDataUpgradeProgress
  /// Set when the upgrade failed: the report's own error, or — for a report
  /// still claiming "running" after the server start failed — the start
  /// failure, since that sidecar will never advance again.
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
  /// Opens Settings › Updates; offered on failure, since the fix for a
  /// migration that cannot complete is usually a newer build.
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
