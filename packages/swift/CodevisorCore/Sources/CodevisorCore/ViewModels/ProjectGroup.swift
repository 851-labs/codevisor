import Foundation

public struct ProjectGroup: Identifiable, Equatable, Sendable {
  public let id: String
  public let repoKey: String?
  public let members: [Project]

  init(repoKey: String?, members: [Project]) {
    precondition(!members.isEmpty, "A project group needs at least one member")
    self.repoKey = repoKey
    self.members = members.sorted(by: Self.memberOrder)
    self.id = repoKey.map { "repo|\($0)" } ?? Self.soloID(for: members[0])
  }

  public init(solo project: Project) {
    self.init(repoKey: nil, members: [project])
  }

  public var primary: Project { members[0] }
  public var name: String { primary.name }
  public var createdAt: Date { primary.createdAt }
  public var serverIds: [String] { members.map(\.serverId) }
  public var isGitRepository: Bool { members.contains(where: \.isGitRepository) }
  public var repoUrl: String? { members.lazy.compactMap(\.repoUrl).first }

  public func member(on serverId: String) -> Project? {
    members.first { $0.serverId == serverId }
  }

  public func member(serverId: String, projectId: UUID) -> Project? {
    members.first { $0.serverId == serverId && $0.id == projectId }
  }

  public func contains(_ project: Project) -> Bool {
    contains(serverId: project.serverId, projectId: project.id)
  }

  public func contains(serverId: String, projectId: UUID) -> Bool {
    members.contains { $0.serverId == serverId && $0.id == projectId }
  }

  public static func groupID(for project: Project) -> String {
    if let repoKey = project.repoKey, !project.isScratch {
      return "repo|\(repoKey)"
    }
    return soloID(for: project)
  }

  public static func routeID(for project: Project) -> String {
    soloID(for: project)
  }

  public func isNamed(by routeID: String) -> Bool {
    routeID == id || members.contains { Self.soloID(for: $0) == routeID }
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
  public var fleetActiveProjectGroups: [ProjectGroup] {
    ProjectGroup.grouping(fleetActiveProjects.filter { !$0.isScratch })
  }

  public func fleetActiveProjectGroupsByWorkspaceRecency(
    _ workspaces: [Workspace]
  ) -> [ProjectGroup] {
    ProjectGroup.grouping(
      fleetActiveProjectsByWorkspaceRecency(workspaces).filter { !$0.isScratch }
    )
  }

  public func fleetProjectGroup(containing project: Project) -> ProjectGroup? {
    fleetActiveProjectGroups.first { $0.contains(project) }
  }

  public func fleetSessions(in group: ProjectGroup) -> [ChatSession] {
    group.members
      .flatMap { fleetSessions(in: $0) }
      .sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
  }

  public func mostRecentlyUsedMember(of group: ProjectGroup) -> Project {
    var latestByKey: [String: Date] = [:]
    for session in sessions {
      let key = "\(session.serverId)|\(session.projectId.uuidString)"
      latestByKey[key] = max(latestByKey[key] ?? .distantPast, session.updatedAt ?? session.createdAt)
    }
    return group.members.max { left, right in
      let leftDate = latestByKey["\(left.serverId)|\(left.id.uuidString)"] ?? .distantPast
      let rightDate = latestByKey["\(right.serverId)|\(right.id.uuidString)"] ?? .distantPast
      if leftDate != rightDate { return leftDate < rightDate }
      return (group.members.firstIndex(of: left) ?? 0) > (group.members.firstIndex(of: right) ?? 0)
    } ?? group.primary
  }
}
