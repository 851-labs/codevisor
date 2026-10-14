import Foundation

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
  public let subjectId: String
  public let title: String
  public let installedVersion: String?
  public let latestVersion: String?
  public let updateAvailable: Bool
  public let phase: Phase
  public var statusMessage: String?
  public var progress: Double?
  public var notes: String?

  @MainActor
  static func harnessStatusMessage(_ harness: ServerHarness, lifecyclePhase: String?) -> String? {
    switch lifecyclePhase {
    case "pendingUpdate": "Waiting for chats to finish…"
    case "installing", "updating":
      harness.lifecycle?.targetVersion.map { "Updating to \($0)…" } ?? "Updating…"
    default: nil
    }
  }

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

public struct UpdateMachineGroup: Identifiable, Equatable, Sendable {
  public let id: String
  public let machineName: String
  public let isLocal: Bool
  public let codevisor: UpdateComponent?
  public let components: [UpdateComponent]

  public var availableCount: Int {
    components.count(where: \.updateAvailable) + (codevisor?.updateAvailable == true ? 1 : 0)
  }
}
