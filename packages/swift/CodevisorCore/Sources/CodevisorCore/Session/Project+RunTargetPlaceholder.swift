import CodevisorProtocol
import Foundation

extension Project {
  /// The fixed identity of the composer's "no project picked yet" sentinel.
  public static let runTargetPlaceholderID = UUID(
    uuidString: "00000000-0000-0000-0000-00000000C0DE"
  )!

  /// The "No project" run target: a draft that is not tied to any
  /// repository. The composer renders and sends normally; the first send
  /// allocates a single-use scratch folder on the draft's machine and the
  /// chat runs there (see `SessionController.materializeScratchProject`).
  /// Also the state a machine with no projects starts in.
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
  /// Resolves a saved draft without turning the no-project sentinel into a
  /// missing project after relaunch. A draft that somehow points at a
  /// scratch folder (single-use, owned by an already-sent chat) restores
  /// as "No project" rather than reusing that folder.
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
