import CodevisorClient

public struct Checkout: Equatable, Sendable {
  public let id: String
  public let serverId: String
  public let path: String
  public let worktreeName: String?
  public let git: ServerWorkspaceGit?

  public init(record: ServerCheckout, machineId: String) {
    id = record.id
    serverId = machineId
    path = record.path
    worktreeName = record.worktreeName
    git = record.git
  }
}
