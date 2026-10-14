import CodevisorProtocol
import Foundation

extension Project {
  public static let runTargetPlaceholderID = UUID(
    uuidString: "00000000-0000-0000-0000-00000000C0DE"
  )!

  public static func runTargetPlaceholder(serverId: String) -> Project {
    fromFolder(
      URL(fileURLWithPath: "/"),
      id: runTargetPlaceholderID,
      serverId: serverId
    )
  }

  public var isRunTargetPlaceholder: Bool {
    id == Self.runTargetPlaceholderID
  }
}

extension ComposerDraftStore.Draft {
  public func restoredProject(
    in projects: [Project],
    defaultServerId: String
  ) -> Project? {
    let serverId = projectServerId ?? defaultServerId
    if projectId == Project.runTargetPlaceholderID {
      return .runTargetPlaceholder(serverId: serverId)
    }
    guard let project = projects.first(where: { $0.serverId == serverId && $0.id == projectId })
    else { return nil }
    return project.isScratch ? .runTargetPlaceholder(serverId: serverId) : project
  }
}
