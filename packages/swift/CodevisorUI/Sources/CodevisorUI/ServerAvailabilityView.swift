import CodevisorCore
import SwiftUI

/// The shared detail-area state used while a machine's server is starting,
/// reconnecting, or migrating. Keeping this at the navigation boundary means
/// cached sidebars/lists stay useful without mounting views that would issue
/// requests before the server is ready.
public struct ServerAvailabilityView: View {
  private let machineId: String
  private let availability: ServerAvailability
  private let machineName: String
  private let isLocal: Bool
  private let dataUpgradeProgress: LocalDataUpgradeProgress?
  private let startupProgress: LocalServerStartupProgress?
  private let appUpdateInProgress: Bool
  private let retry: () -> Void
  /// Re-points the caller at this Mac. Offered only for remote machines
  /// whose wait is open-ended (see `ServerAvailabilityFallbackPolicy`);
  /// nil when the caller has no local machine to fall back to.
  private let useLocalMachine: (() -> Void)?
  /// Relaunches the app, which starts the local server again the normal
  /// way. Local machine only; offered when the start failed or is taking
  /// longer than `slowStartThreshold`.
  private let restart: (() -> Void)?

  /// After this long on "Starting Codevisor Server", offer a restart: a
  /// healthy start takes seconds, so waiting longer means something stuck.
  public static let slowStartThreshold: Duration = .seconds(20)

  @State private var startIsSlow = false

  public init(
    machineId: String,
    availability: ServerAvailability,
    machineName: String,
    isLocal: Bool,
    dataUpgradeProgress: LocalDataUpgradeProgress? = nil,
    startupProgress: LocalServerStartupProgress? = nil,
    appUpdateInProgress: Bool = false,
    useLocalMachine: (() -> Void)? = nil,
    restart: (() -> Void)? = nil,
    retry: @escaping () -> Void
  ) {
    self.machineId = machineId
    self.availability = availability
    self.machineName = machineName
    self.isLocal = isLocal
    self.dataUpgradeProgress = dataUpgradeProgress
    self.startupProgress = startupProgress
    self.appUpdateInProgress = appUpdateInProgress
    self.retry = retry
    self.useLocalMachine = useLocalMachine
    self.restart = restart
  }

  public var body: some View {
    DelayedServerStatus(revealAfterDelay: isActivelyWaiting) {
      VStack(spacing: 18) {
        if isFailed {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 38, weight: .medium))
            .foregroundStyle(.orange)
        } else if !showsStartupProgress {
          ProgressView(value: progressFraction)
            .progressViewStyle(.circular)
            .controlSize(.large)
        }

        VStack(spacing: 7) {
          Text(title)
            .font(.title2.weight(.semibold))
            .multilineTextAlignment(.center)

          Text(message)
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 440)
        }

        if showsStartupProgress {
          VStack(spacing: 8) {
            ProgressView(value: startupProgress?.fractionCompleted ?? 0)
              .progressViewStyle(.linear)
              .accessibilityLabel("Server startup")
            Text("\(startupProgress?.completed ?? 0) of 7 steps complete")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
            if let work = startupProgress?.work, work.total > 0 {
              ProgressView(value: Double(work.completed), total: Double(work.total))
              Text("\(work.name) · \(work.completed) of \(work.total)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .frame(maxWidth: 360)
        }

        if startupProgress?.work == nil, let dataUpgradeProgress,
          dataUpgradeProgress.state == "running",
          dataUpgradeProgress.total > 0
        {
          VStack(spacing: 6) {
            ProgressView(
              value: Double(dataUpgradeProgress.completed),
              total: Double(dataUpgradeProgress.total)
            )
            Text("\(dataUpgradeProgress.completed) of \(dataUpgradeProgress.total)")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.tertiary)
          }
          .frame(maxWidth: 320)
        }

        if isFailed || offersLocalMachine || offersSlowStartRestart {
          HStack(spacing: 10) {
            if isFailed, let restart, isLocal {
              Button("Restart", action: restart)
                .buttonStyle(.borderedProminent)
            } else if isFailed {
              Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
            } else if offersSlowStartRestart, let restart {
              Button("Restart", action: restart)
                .buttonStyle(.bordered)
            }
            if offersLocalMachine, let useLocalMachine {
              Button("Use This Mac Instead", action: useLocalMachine)
                .buttonStyle(.bordered)
                .accessibilityHint("Start new chats on this Mac instead of \(machineName)")
            }
          }
        }
      }
    }
    .task(id: "\(isLocalStartWait):\(startupProgress?.progressKey ?? "")") {
      startIsSlow = false
      guard isLocalStartWait else { return }
      try? await Task.sleep(for: Self.slowStartThreshold)
      guard !Task.isCancelled else { return }
      startIsSlow = true
    }
    .id(ServerStatusPresentationID(machineId: machineId, isWaiting: isActivelyWaiting))
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
    .accessibilityElement(children: .contain)
  }

  private var showsStartupProgress: Bool {
    guard isLocal, !appUpdateInProgress, !isFailed else { return false }
    if case let .waiting(reason) = availability {
      return reason == .starting || reason == .restarting
    }
    return false
  }

  private var activeMigration: LocalDataUpgradeProgress? {
    guard let dataUpgradeProgress,
      dataUpgradeProgress.state == "running" || dataUpgradeProgress.state == "failed"
    else { return nil }
    return dataUpgradeProgress
  }

  private var progressFraction: Double? {
    activeMigration?.state == "running" ? activeMigration?.fractionCompleted : nil
  }

  private var offersLocalMachine: Bool {
    useLocalMachine != nil
      && ServerAvailabilityFallbackPolicy.offersLocalMachine(
        isLocal: isLocal,
        availability: availability,
        hasLocalMachine: true,
        appUpdateInProgress: appUpdateInProgress,
        migrationInProgress: activeMigration != nil
      )
  }

  /// The local server is starting (not updating or migrating).
  private var isLocalStartWait: Bool {
    guard isLocal, !appUpdateInProgress, activeMigration == nil else { return false }
    if case .waiting(.starting) = availability { return true }
    return false
  }

  private var offersSlowStartRestart: Bool {
    isLocalStartWait && startIsSlow && restart != nil
  }

  private var isFailed: Bool {
    if appUpdateInProgress { return false }
    if activeMigration?.state == "failed" { return true }
    if case .failed = availability { return true }
    return false
  }

  /// Keep fast startup/reconnects visually quiet. Requests are gated for the
  /// entire wait, but the explanatory progress UI only appears when the wait
  /// lasts long enough to be useful.
  private var isActivelyWaiting: Bool {
    if appUpdateInProgress { return true }
    if activeMigration?.state == "running" { return true }
    if case .waiting = availability { return true }
    return false
  }

  private var title: String {
    if appUpdateInProgress { return "Updating Codevisor" }
    if let migration = activeMigration {
      return migration.state == "failed" ? "Server Data Update Failed" : "Updating Server Data"
    }
    return switch availability {
    case let .waiting(reason):
      switch reason {
      case .starting: isLocal ? "Starting Codevisor Server" : "Connecting to Server"
      case .connecting: "Connecting to \(machineName)"
      case .updating: "Updating Codevisor Server"
      case .restarting: "Restarting Codevisor Server"
      }
    case .ready:
      "Server Ready"
    case .failed:
      "Can't Reach \(machineName)"
    }
  }

  private var message: String {
    if appUpdateInProgress {
      return "Codevisor is installing an update and will reopen automatically."
    }
    if showsStartupProgress, let startupProgress {
      return startupProgress.label + (startIsSlow ? "\nThis step is taking longer than expected." : "")
    }
    if let migration = activeMigration {
      if migration.state == "failed" {
        return migration.error ?? "Codevisor couldn't finish updating the server's data."
      }
      return migration.name.isEmpty
        ? "Your cached workspaces are safe. Codevisor will continue when the update finishes."
        : "\(migration.name)\nYour cached workspaces are safe. Codevisor will continue automatically."
    }
    return switch availability {
    case let .waiting(reason):
      switch reason {
      case .starting:
        offersSlowStartRestart
          ? "This is taking longer than expected. Restarting Codevisor starts the server again; the server log has the details."
          : "Your cached workspaces are still available. This page will open when the server is ready."
      case .connecting:
        "Waiting for the server to become available. This page will open automatically."
      case .updating:
        "The server is installing an update. Codevisor will reconnect automatically."
      case .restarting:
        "The server is restarting. Codevisor will reconnect automatically."
      }
    case .ready:
      "Codevisor is ready."
    case let .failed(message):
      message
    }
  }
}

private struct ServerStatusPresentationID: Hashable {
  let machineId: String
  let isWaiting: Bool
}

private struct DelayedServerStatus<Content: View>: View {
  let revealAfterDelay: Bool
  let content: Content

  @State private var hasPassedDelay = false

  init(revealAfterDelay: Bool, @ViewBuilder content: () -> Content) {
    self.revealAfterDelay = revealAfterDelay
    self.content = content()
  }

  var body: some View {
    ZStack {
      Color.clear

      if !revealAfterDelay || hasPassedDelay {
        content
      }
    }
    .task {
      guard revealAfterDelay else { return }
      do {
        try await Task.sleep(for: .milliseconds(500))
      } catch {
        return
      }
      hasPassedDelay = true
    }
  }
}

/// Whole-window startup state for the client database. Unlike server waiting,
/// no app content is mounted because repositories cannot safely open until
/// this work completes.
public struct ClientDataStartupView: View {
  public init() {}

  public var body: some View {
    VStack(spacing: 18) {
      ProgressView()
        .controlSize(.large)
      VStack(spacing: 7) {
        Text("Preparing Codevisor")
          .font(.title2.weight(.semibold))
        Text("Checking and updating this device's local data…")
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
  }
}
