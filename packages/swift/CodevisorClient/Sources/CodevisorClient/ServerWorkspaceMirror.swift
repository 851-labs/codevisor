import Foundation

public struct ServerWorkspaceMirror: Decodable, Equatable, Sendable, Identifiable {
  public struct Machine: Decodable, Equatable, Sendable {
    public let machineId: String
    public let name: String
  }

  public enum State: String, Decodable, Sendable {
    case syncing, synced, failed
  }

  public let workspaceId: String
  public let machine: Machine
  public let path: String?
  public let state: State
  public let pendingChanges: Bool
  public let lastSyncedAt: String?
  public let error: String?

  public var id: String { machine.machineId }
}
