import Foundation

/// One updatable thing somewhere in the fleet: the app itself, a machine's
/// server, or a harness/plugin on a machine. The row identity every update
/// surface (settings page, footer count, update-all) folds over.
public struct UpdateComponent: Identifiable, Equatable, Sendable {
  public enum Kind: String, Sendable {
    case app
    case server
    case harness
    case plugin
  }

  public enum Phase: Equatable, Sendable {
    case idle
    case updating
    case failed(String)
  }

  public let id: String
  public let kind: Kind
  public let machineId: String
  public let machineName: String
  /// The harness/plugin id on its machine; empty for app/server rows.
  public let subjectId: String
  public let title: String
  public let installedVersion: String?
  public let latestVersion: String?
  public let updateAvailable: Bool
  public let phase: Phase
  /// What an in-flight update is doing ("Waiting for 2 chats to finish…",
  /// "Downloading…"); nil when there is nothing more specific than the phase.
  public var statusMessage: String?
  /// Determinate progress (0...1) of an in-flight update, when it has one.
  public var progress: Double?
  /// What changes when the update crosses a major version. Such an update
  /// runs only after the user confirms it, never as part of Update All.
  public var notes: String?
}

extension UpdateComponent {
  /// The row's detail in every state: versions when idle, what the machine
  /// is doing while updating, a one-line reason when failed. Status stays on
  /// one line and the full failure output lives behind a details control;
  /// versions are never truncated, so rows may wrap them.
  public var detailText: String {
    switch phase {
    case .updating:
      let status = statusMessage ?? "Updating…"
      guard let progress else { return status }
      return "\(status) \(Int((progress * 100).rounded()))%"
    case let .failed(message):
      let reason = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
      return reason.isEmpty ? "Update failed" : "Update failed: \(reason)"
    case .idle:
      if let change = pendingVersionChange {
        return "\(change.installed) → \(change.latest)"
      }
      if updateAvailable, let latestVersion {
        return "\(latestVersion) available"
      }
      return installedVersion ?? "Up to date"
    }
  }

  /// The move an idle row's update would make, when both ends are known.
  /// Rows use it to break a version change that doesn't fit one line at the
  /// arrow instead of inside a version.
  public var pendingVersionChange: (installed: String, latest: String)? {
    guard phase == .idle, updateAvailable, let installedVersion, let latestVersion else {
      return nil
    }
    return (installedVersion, latestVersion)
  }

  public var isFailed: Bool {
    if case .failed = phase { return true }
    return false
  }
}

/// One machine in the Updates pane: the machine's own Codevisor (the app
/// locally, the server remotely) as the first row when it needs attention,
/// followed by the harnesses and plugins on it.
public struct UpdateMachineGroup: Identifiable, Equatable, Sendable {
  /// The machine id.
  public let id: String
  public let machineName: String
  public let isLocal: Bool
  /// The machine's Codevisor. Nil when the machine has no self-updater to
  /// report through (development builds of the app; a server whose
  /// release state is not known yet).
  public let codevisor: UpdateComponent?
  /// Harnesses first, then plugins.
  public let components: [UpdateComponent]

  public var availableCount: Int {
    components.count(where: \.updateAvailable) + (codevisor?.updateAvailable == true ? 1 : 0)
  }
}
