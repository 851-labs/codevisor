import CodevisorProtocol
import Foundation

extension Project {
  /// The fixed identity of the composer's "no project picked yet" sentinel.
  public static let runTargetPlaceholderID = UUID(
    uuidString: "00000000-0000-0000-0000-00000000C0DE"
  )!

  /// A sentinel project for a draft that exists BEFORE any project does:
  /// the new-chat composer always renders, with send disabled and the
  /// run-target chip prompting for a selection, instead of a bespoke
  /// empty screen.
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
  /// missing project after relaunch.
  public func restoredProject(
    in projects: [Project],
    defaultServerId: String
  ) -> Project? {
    let serverId = projectServerId ?? defaultServerId
    if projectId == Project.runTargetPlaceholderID {
      return .runTargetPlaceholder(serverId: serverId)
    }
    return projects.first { $0.serverId == serverId && $0.id == projectId }
  }
}
