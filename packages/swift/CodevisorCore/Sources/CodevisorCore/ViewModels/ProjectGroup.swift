import Foundation

/// One logical project as the user sees it: every machine's record of the
/// same repository, folded together. Server ids and project UUIDs stay
/// per-machine underneath (sessions, workspaces, and worktree paths all key
/// on them); only presentation and picking happen at the group level.
///
/// Membership follows the server-derived `repoKey`. A project without one
/// (a non-git folder, no remote, or a server that predates remote
/// tracking) is a group of one, so a fleet whose machines update at
/// different times degrades to today's per-machine rows rather than to
/// wrong grouping.
public struct ProjectGroup: Identifiable, Equatable, Sendable {
  /// Stable across refreshes: the repo key for linked projects, else the
  /// composite machine-scoped id of the lone member.
  public let id: String
  public let repoKey: String?
  /// Oldest record first, so the group's name and creation date come from
  /// the machine that knew the project earliest and do not flip as
  /// snapshots arrive in different orders.
  public let members: [Project]

  init(repoKey: String?, members: [Project]) {
    precondition(!members.isEmpty, "A project group needs at least one member")
    self.repoKey = repoKey
    self.members = members.sorted(by: Self.memberOrder)
    self.id = repoKey.map { "repo|\($0)" } ?? Self.soloID(for: members[0])
  }

  /// A group of exactly this record, for surfaces that deliberately stay
  /// per machine (the archive lists what each machine archived).
  public init(solo project: Project) {
    self.init(repoKey: nil, members: [project])
  }

  /// The record that represents the group where a single project is
  /// needed (its name, its creation date, expansion-state keys).
  public var primary: Project { members[0] }
  public var name: String { primary.name }
  public var createdAt: Date { primary.createdAt }
  /// Machines holding a checkout of this project, oldest record first.
  public var serverIds: [String] { members.map(\.serverId) }
  /// Whether any checkout is a git repository (worktrees can be offered on
  /// that machine).
  public var isGitRepository: Bool { members.contains(where: \.isGitRepository) }

  public func member(on serverId: String) -> Project? {
    members.first { $0.serverId == serverId }
  }

  /// The exact record a session or workspace belongs to. A machine can
  /// hold two clones of one repository, so the project id disambiguates.
  public func member(serverId: String, projectId: UUID) -> Project? {
    members.first { $0.serverId == serverId && $0.id == projectId }
  }

  public func contains(_ project: Project) -> Bool {
    contains(serverId: project.serverId, projectId: project.id)
  }

  public func contains(serverId: String, projectId: UUID) -> Bool {
    members.contains { $0.serverId == serverId && $0.id == projectId }
  }

  /// The group id a project belongs to, computable without building the
  /// full grouping (persisted expansion state, ordering keys).
  public static func groupID(for project: Project) -> String {
    if let repoKey = project.repoKey, !project.isScratch {
      return "repo|\(repoKey)"
    }
    return soloID(for: project)
  }

  private static func soloID(for project: Project) -> String {
    "project|\(project.serverId)|\(project.id.uuidString)"
  }

  private static func memberOrder(_ left: Project, _ right: Project) -> Bool {
    if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
    if left.serverId != right.serverId { return left.serverId < right.serverId }
    return left.id.uuidString < right.id.uuidString
  }
}

extension ProjectGroup {
  /// Folds a project list into groups, keeping the list's own order: a
  /// group sits where its first member appeared, so any caller-chosen
  /// ordering (creation, workspace recency, manual) carries over. Scratch
  /// backing projects never link, even when they somehow report a key.
  public static func grouping(_ projects: [Project]) -> [ProjectGroup] {
    var membersByID: [String: [Project]] = [:]
    var order: [String] = []
    for project in projects {
      let id = groupID(for: project)
      if membersByID[id] == nil { order.append(id) }
      membersByID[id, default: []].append(project)
    }
    return order.map { id in
      let members = membersByID[id] ?? []
      let repoKey = id.hasPrefix("repo|") ? members.first?.repoKey : nil
      return ProjectGroup(repoKey: repoKey, members: members)
    }
  }
}

extension ProjectListModel {
  /// Active projects across every machine, linked by repository — the
  /// sidebar's "by project" roots and the composer picker's entries.
  /// Scratch backing projects are excluded: they are single-use folders,
  /// not projects.
  public var fleetActiveProjectGroups: [ProjectGroup] {
    ProjectGroup.grouping(fleetActiveProjects.filter { !$0.isScratch })
  }

  /// Fleet-wide groups ordered by each group's most recently created
  /// workspace on any of its machines; groups with no workspace history
  /// keep their newest-first order after the used ones.
  public func fleetActiveProjectGroupsByWorkspaceRecency(
    _ workspaces: [Workspace]
  ) -> [ProjectGroup] {
    ProjectGroup.grouping(
      fleetActiveProjectsByWorkspaceRecency(workspaces).filter { !$0.isScratch }
    )
  }

  /// The group an active project belongs to, if it is still active.
  public func fleetProjectGroup(containing project: Project) -> ProjectGroup? {
    fleetActiveProjectGroups.first { $0.contains(project) }
  }

  /// Every member's visible sessions, newest activity first.
  public func fleetSessions(in group: ProjectGroup) -> [ChatSession] {
    group.members
      .flatMap { fleetSessions(in: $0) }
      .sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
  }

  /// The member of a group whose sessions were most recently active, or
  /// the group's primary when none has any: which machine's record to
  /// pick when the user chooses the group itself.
  public func mostRecentlyUsedMember(of group: ProjectGroup) -> Project {
    var latestByKey: [String: Date] = [:]
    for session in sessions where !session.isArchived {
      let key = "\(session.serverId)|\(session.projectId.uuidString)"
      latestByKey[key] = max(latestByKey[key] ?? .distantPast, session.updatedAt ?? session.createdAt)
    }
    return group.members.max { left, right in
      let leftDate = latestByKey["\(left.serverId)|\(left.id.uuidString)"] ?? .distantPast
      let rightDate = latestByKey["\(right.serverId)|\(right.id.uuidString)"] ?? .distantPast
      if leftDate != rightDate { return leftDate < rightDate }
      // Ties (no history anywhere) fall back to the primary, which is
      // first in `members`; `max` keeps the LAST of equal elements, so
      // compare by reversed member position.
      return (group.members.firstIndex(of: left) ?? 0) > (group.members.firstIndex(of: right) ?? 0)
    } ?? group.primary
  }
}
