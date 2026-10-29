import Foundation

public struct SandboxProviderRemoval: Equatable, Sendable {
  public let providerTitle: String
  public let profileCount: Int
  public let workspaceCount: Int
  public let offlineMachineNames: [String]

  public init(providerTitle: String, profileCount: Int, workspaceCount: Int, offlineMachineNames: [String]) {
    self.providerTitle = providerTitle
    self.profileCount = profileCount
    self.workspaceCount = workspaceCount
    self.offlineMachineNames = offlineMachineNames
  }

  public var title: String { "Delete “\(providerTitle)”?" }

  public var message: String {
    [cascade, workLost, offline].compactMap(\.self).joined(separator: " ")
  }

  private var cascade: String {
    let profiles = Self.counted(profileCount, "profile")
    guard workspaceCount > 0 else { return "This also deletes its \(profiles)." }

    let workspaces = Self.counted(workspaceCount, "workspace")
    let users = profileCount == 1 ? "it" : "them"
    return "This also deletes its \(profiles) and archives the \(workspaces) using \(users)."
  }

  private var workLost: String? {
    guard workspaceCount > 0 else { return nil }

    let sandboxes = workspaceCount == 1 ? "its sandbox" : "their sandboxes"
    return "Archiving destroys \(sandboxes), so any work that isn’t pushed is lost."
  }

  private var offline: String? {
    guard !offlineMachineNames.isEmpty else { return nil }

    let names = offlineMachineNames.formatted(.list(type: .and))
    if offlineMachineNames.count == 1 {
      return "\(names) is offline. Sandboxes it started keep running, and cost money, until it’s back online."
    }
    return "\(names) are offline. Sandboxes they started keep running, and cost money, until they’re back online."
  }

  private static func counted(_ count: Int, _ noun: String) -> String {
    count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
  }
}
