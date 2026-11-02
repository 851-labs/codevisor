import CodevisorCore
import SwiftUI

public struct ServerAvailabilityView: View {
  private let machineId: String
  private let availability: ServerAvailability
  private let machineName: String
  private let isLocal: Bool
  private let startupProgress: LocalServerStartupProgress?
  private let appUpdate: AppUpdateActivity?
  private let serverUpdate: ServerUpdateActivity?
  private let useLocalMachine: (() -> Void)?
  private let restart: (() -> Void)?

  public static let slowStartThreshold: Duration = .seconds(20)

  @State private var startIsSlow = false

  public init(
    machineId: String,
    availability: ServerAvailability,
    machineName: String,
    isLocal: Bool,
    startupProgress: LocalServerStartupProgress? = nil,
    appUpdate: AppUpdateActivity? = nil,
    serverUpdate: ServerUpdateActivity? = nil,
    useLocalMachine: (() -> Void)? = nil,
    restart: (() -> Void)? = nil
  ) {
    self.machineId = machineId
    self.availability = availability
    self.machineName = machineName
    self.isLocal = isLocal
    self.startupProgress = startupProgress
    self.appUpdate = appUpdate
    self.serverUpdate = serverUpdate
    self.useLocalMachine = useLocalMachine
    self.restart = restart
  }

  public var body: some View {
    DelayedServerStatus(revealAfterDelay: isActivelyWaiting) {
      ProgressStepScreen(title: title, steps: steps, note: note) {
        ServerAvailabilityActions(
          machineName: machineName,
          restart: offeredRestart,
          restartIsProminent: isFailed,
          useLocalMachine: offersLocalMachine ? useLocalMachine : nil
        )
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
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var steps: [ProgressStep] {
    ServerAvailabilitySteps(
      availability: availability,
      machineName: machineName,
      isLocal: isLocal,
      startupProgress: startupProgress,
      appUpdate: appUpdate,
      serverUpdate: serverUpdate
    ).steps
  }

  private var offeredRestart: (() -> Void)? {
    offersRestart ? restart : nil
  }

  private var offersRestart: Bool {
    (isFailed && isLocal) || offersSlowStartRestart
  }

  private var offersLocalMachine: Bool {
    useLocalMachine != nil
      && ServerAvailabilityFallbackPolicy.offersLocalMachine(
        isLocal: isLocal,
        availability: availability,
        appUpdateInProgress: appUpdate != nil
      )
  }

  private var isLocalStartWait: Bool {
    guard isLocal, appUpdate == nil else { return false }
    if case .waiting(.starting) = availability { return true }
    return false
  }

  private var offersSlowStartRestart: Bool {
    isLocalStartWait && startIsSlow && restart != nil
  }

  private var isFailed: Bool {
    if appUpdate != nil { return false }
    if case .failed = availability { return true }
    return false
  }

  private var isActivelyWaiting: Bool {
    if appUpdate != nil { return true }
    if case .waiting = availability { return true }
    return false
  }

  private var title: String {
    if appUpdate != nil { return "Updating Codevisor" }
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

  private var note: String? {
    if isFailed, case let .failed(message) = availability {
      return isLocal ? message : "\(message) Codevisor will reconnect automatically once it's reachable."
    }
    guard isLocalStartWait, startIsSlow else { return nil }

    return offersSlowStartRestart
      ? "This is taking longer than expected. Restarting Codevisor starts the server again; the server log has the details."
      : "This step is taking longer than expected."
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
